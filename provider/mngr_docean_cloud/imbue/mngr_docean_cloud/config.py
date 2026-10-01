from pathlib import Path

from pydantic import Field

from imbue.mngr.primitives import ProviderBackendName
from imbue.mngr_vps.config import VpsProviderConfig

# Default base image: Ubuntu 24.04 server cloud image (cloud-init enabled).
DEFAULT_BASE_IMAGE = "/var/lib/libvirt/images/ubuntu-24.04-server-cloudimg-amd64.img"


class DoceanCloudProviderConfig(VpsProviderConfig):
    """Configuration for the docean_cloud (nested-KVM/libvirt) VPS provider.

    No API credentials are needed: the "cloud" is the local libvirt daemon on
    the host running mngr. VMs are attached to a libvirt network (the default
    NAT network by default) and reached over SSH at their DHCP lease IP.
    """

    backend: ProviderBackendName = Field(
        default=ProviderBackendName("docean_cloud"),
        description="Provider backend (always 'docean_cloud' for this type)",
    )
    base_image: Path = Field(
        default=Path(DEFAULT_BASE_IMAGE),
        description=(
            "Path to the cloud-init-enabled qcow2 base image used as the backing "
            "file for each VM's copy-on-write overlay."
        ),
    )
    images_dir: Path = Field(
        default=Path("/var/lib/libvirt/images/docean_cloud"),
        description=(
            "Directory holding per-VM qcow2 disk overlays, NoCloud seed ISOs and "
            "the instance registry JSON."
        ),
    )
    network: str = Field(
        default="default",
        description="libvirt network to attach VMs to (must provide DHCP + outbound NAT).",
    )
    vm_disk_gb: int = Field(
        default=40,
        description="Virtual disk size in GB for each VM (thin qcow2 overlay).",
    )
    libvirt_ssh_host: str | None = Field(
        default=None,
        description=(
            "When set, all libvirt/qemu commands run over SSH on this host (e.g. "
            "'root@10.124.0.3'), so mngr can drive a remote KVM host's libvirt. The "
            "VMs' DHCP-lease IPs must be routable from where mngr runs (e.g. via a "
            "static route to the libvirt network through this host). When None, the "
            "local libvirt daemon is used."
        ),
    )
    public_face_host: str | None = Field(
        default=None,
        description=(
            "When set, mngr reaches VMs at this public host (e.g. the KVM host's "
            "public IP) over forwarded ports instead of the VMs' private libvirt "
            "IPs -- so a remote mngr with no route to 192.168.122.0/24 can still "
            "drive the VMs. Requires allowed_ssh_cidr."
        ),
    )
    public_outer_port: int = Field(
        default=2229,
        description="Public port forwarded to each VM's outer sshd (:22).",
    )
    allowed_ssh_cidr: str | None = Field(
        default=None,
        description=(
            "Source IPv4 CIDR allowed on the forwarded public SSH ports (e.g. "
            "'216.38.157.42/32'). REQUIRED when public_face_host is set; if unset "
            "the provider refuses to expose ports (no accidental 0.0.0.0/0)."
        ),
    )
    default_region: str = Field(
        default="local",
        description="Default region (cosmetic -- there is only one libvirt host).",
    )
    default_plan: str = Field(
        default="2c4g",
        description=(
            "Default VM size, parsed as '<vcpus>c<ram_gb>g' (e.g. '2c4g' = 2 vCPUs, 4 GB)."
        ),
    )
    # The in-VM btrfs loop file (used by the container realizer for the per-host
    # docker volume) is sized as (free_gb - outer_disk_reserved_gb). Inside a VM
    # with a modest root disk we hold back less than the cloud default of 20 GB.
    outer_disk_reserved_gb: int = Field(
        default=5,
        description="Gigabytes held back from the in-VM btrfs loop file.",
    )
