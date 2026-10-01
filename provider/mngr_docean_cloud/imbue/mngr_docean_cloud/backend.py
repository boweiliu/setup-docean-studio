from collections.abc import Iterator
from collections.abc import Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from typing import Final

from pydantic import ConfigDict
from pydantic import Field

from imbue.mngr.config.data_types import MngrContext
from imbue.mngr.config.data_types import ProviderInstanceConfig
from imbue.mngr.hosts.outer_host import OuterHost
from imbue.mngr.interfaces.data_types import PyinfraConnector
from imbue.mngr.interfaces.host import OuterHostInterface
from imbue.mngr.interfaces.provider_backend import ProviderBackendInterface
from imbue.mngr.interfaces.provider_instance import ProviderInstanceInterface
from imbue.mngr.primitives import HostId
from imbue.mngr.primitives import HostName
from imbue.mngr.primitives import ProviderBackendName
from imbue.mngr.primitives import ProviderInstanceName
from imbue.mngr.providers.ssh_utils import add_host_to_known_hosts
from imbue.mngr.providers.ssh_utils import create_pyinfra_host
from imbue.mngr.providers.ssh_utils import wait_for_sshd
from imbue.mngr_vps.build_args import ParsedVpsBuildOptions
from imbue.mngr_vps.build_args import parse_vps_build_args
from imbue.mngr_vps.instance import VpsProvider
from imbue.mngr_vps.primitives import VpsInstanceId
from imbue.mngr_docean_cloud import hookimpl
from imbue.mngr_docean_cloud.client import DoceanCloudVpsClient
from imbue.mngr_docean_cloud.config import DoceanCloudProviderConfig

DOCEAN_CLOUD_BACKEND_NAME: Final[ProviderBackendName] = ProviderBackendName("docean_cloud")


class DoceanCloudProvider(VpsProvider):
    """docean_cloud provider: nested-KVM/libvirt VMs on a single host.

    All cross-VPS discovery machinery (parallel SSH reads, caching, per-name
    lookups) is inherited from ``VpsProvider``; this subclass only contributes
    the libvirt-backed listing (filter VMs by the ``mngr-provider`` tag).
    """

    model_config = ConfigDict(arbitrary_types_allowed=True)

    docean_client: DoceanCloudVpsClient = Field(frozen=True, description="libvirt-backed VPS client")
    docean_config: DoceanCloudProviderConfig = Field(frozen=True, description="docean_cloud configuration")

    def _fetch_provider_instances(self) -> list[dict[str, Any]]:
        """List every docean_cloud VM from the local libvirt registry."""
        return self.docean_client.list_instances()

    def _parse_build_args(self, build_args: Sequence[str] | None) -> ParsedVpsBuildOptions:
        """Parse docean-cloud-prefixed build args (--docean-cloud-region, --docean-cloud-plan, --git-depth)."""
        return parse_vps_build_args(
            build_args,
            provider_prefix="docean-cloud",
            default_region=self.docean_config.default_region,
            default_plan=self.docean_config.default_plan,
            plan_arg_name="plan",
        )

    def _list_provider_vps_hostnames(self) -> list[str]:
        """Return the hostnames mngr should probe for this provider's VMs.

        In public-face mode the VMs' private libvirt IPs (192.168.122.0/24) are
        unreachable from where mngr runs (e.g. a remote Mac with no route to the
        NAT net), so probing them would always fail and the workspace would never
        appear in ``mngr list``. The public-face DNAT forwards the KVM host's
        public IP to exactly one VM (the single-VM design: the ``docean_pubface``
        nft chain is flushed + re-pointed per create), so in public-face mode we
        probe only that public host -- discovery + the host object's container
        endpoint both key off this hostname, so they reach the VM through the
        DNAT (outer :public_outer_port, container :container_ssh_port).
        """
        if self._is_public_face:
            return [self.docean_config.public_face_host]  # type: ignore[list-item]
        provider_tag = f"mngr-provider={self.name}"
        instances = self._list_instances_cached()
        vps_ips: list[str] = []
        for instance in instances:
            if provider_tag not in instance.get("tags", []):
                continue
            vps_ip = instance.get("main_ip", "")
            if vps_ip and vps_ip != "0.0.0.0":
                vps_ips.append(vps_ip)
        return vps_ips

    # -- public-face (port-forwarded) mode ---------------------------------
    # When ``public_face_host`` is set, mngr reaches VMs at the KVM host's
    # public IP over two forwarded ports (outer sshd + container sshd) instead
    # of the VMs' private libvirt IPs. Only those two ports are exposed,
    # restricted to ``allowed_ssh_cidr``. The base VpsProvider hardcodes the
    # outer SSH port to 22 in three spots; we override each to use the forwarded
    # outer port, and pre-pin the host key for that port (the base pins :22,
    # which is unused here).

    @property
    def _is_public_face(self) -> bool:
        return self.docean_config.public_face_host is not None

    def _outer_ssh_port(self) -> int:
        return self.docean_config.public_outer_port if self._is_public_face else 22

    @contextmanager
    def _make_outer_for_vps_ip(self, vps_ip: str) -> Iterator[OuterHostInterface]:
        """Open the outer host at the (possibly forwarded) outer SSH port."""
        vps_key_path, _pub = self._get_vps_ssh_keypair()
        pyinfra_host = create_pyinfra_host(
            hostname=vps_ip,
            port=self._outer_ssh_port(),
            private_key_path=vps_key_path,
            known_hosts_path=self._vps_known_hosts_path(),
            ssh_user="root",
        )
        outer = OuterHost(id=HostId.generate(), connector=PyinfraConnector(pyinfra_host), mngr_ctx=self.mngr_ctx)
        try:
            yield outer
        finally:
            outer.disconnect()

    def _wait_for_sshd_on_vps(self, vps_ip: str, timeout_seconds: float) -> None:
        """Wait for sshd at the (possibly forwarded) outer SSH port."""
        wait_for_sshd(hostname=vps_ip, port=self._outer_ssh_port(), timeout_seconds=timeout_seconds)

    def _provision_vps(
        self,
        host_id: HostId,
        name: HostName,
        parsed: ParsedVpsBuildOptions,
        vps_host_key_path: Path,
        vps_host_public_key: str,
        vps_ssh_key_id: str,
        vps_public_key: str,
    ) -> tuple[VpsInstanceId, str]:
        """Pre-pin the VM host key for the forwarded outer port, then defer to the base."""
        if self._is_public_face:
            add_host_to_known_hosts(
                known_hosts_path=self._vps_known_hosts_path(),
                hostname=self.docean_config.public_face_host,
                port=self.docean_config.public_outer_port,
                public_key=vps_host_public_key,
                host_id=host_id,
            )
        return super()._provision_vps(
            host_id, name, parsed, vps_host_key_path, vps_host_public_key, vps_ssh_key_id, vps_public_key
        )


class DoceanCloudProviderBackend(ProviderBackendInterface):
    """Backend for creating docean_cloud (nested-KVM) VPS provider instances."""

    @staticmethod
    def get_name() -> ProviderBackendName:
        return DOCEAN_CLOUD_BACKEND_NAME

    @staticmethod
    def get_description() -> str:
        return "Runs agents on nested-KVM/libvirt VMs on a single host (no cloud account required)"

    @staticmethod
    def get_config_class() -> type[ProviderInstanceConfig]:
        return DoceanCloudProviderConfig

    @staticmethod
    def get_build_args_help() -> str:
        return (
            "docean_cloud-specific args (consumed by provider, not passed to docker):\n"
            "  --docean-cloud-region=REGION  libvirt host (cosmetic; default: local)\n"
            "  --docean-cloud-plan=PLAN     VM size as <vcpus>c<ram_gb>g (default: 2c4g)\n"
            "  --git-depth=N                Shallow-clone build context to depth N\n"
            "\n"
            "All other build args are passed to 'docker build' inside the VM.\n"
        )

    @staticmethod
    def get_start_args_help() -> str:
        return "Start args are passed directly to 'docker run' inside the VM. Run 'docker run --help' for details."

    @staticmethod
    def build_provider_instance(
        name: ProviderInstanceName,
        config: ProviderInstanceConfig,
        mngr_ctx: MngrContext,
    ) -> ProviderInstanceInterface:
        if not isinstance(config, DoceanCloudProviderConfig):
            from imbue.mngr.errors import MngrError

            raise MngrError(f"Expected DoceanCloudProviderConfig, got {type(config).__name__}")

        docean_client = DoceanCloudVpsClient(
            base_image=config.base_image,
            images_dir=config.images_dir,
            network=config.network,
            vm_disk_gb=config.vm_disk_gb,
            libvirt_ssh_host=config.libvirt_ssh_host,
            public_face_host=config.public_face_host,
            public_outer_port=config.public_outer_port,
            allowed_ssh_cidr=config.allowed_ssh_cidr,
            container_ssh_port=config.container_ssh_port,
        )

        return DoceanCloudProvider(
            name=name,
            host_dir=config.host_dir,
            mngr_ctx=mngr_ctx,
            config=config,
            vps_client=docean_client,
            docean_client=docean_client,
            docean_config=config,
        )


@hookimpl
def register_provider_backend() -> tuple[type[ProviderBackendInterface], type[ProviderInstanceConfig]]:
    """Register the docean_cloud provider backend."""
    return (DoceanCloudProviderBackend, DoceanCloudProviderConfig)
