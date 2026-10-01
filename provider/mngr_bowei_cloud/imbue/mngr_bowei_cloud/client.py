"""libvirt-backed ``VpsClient`` for the bowei_cloud provider.

Each "VPS" is a KVM virtual machine on the local libvirt daemon, attached to a
libvirt network (the default NAT network by default). The VM is reached over
SSH at its DHCP-lease IP. All of the higher-level VPS machinery (cloud-init
bootstrap, Docker install, container realizer, discovery) is inherited from
``mngr_vps``; this client only implements the small ``VpsClientInterface``
surface against ``virsh``/``qemu-img``.
"""

import json
import re
import shlex
import subprocess
import tempfile
import time
import uuid
from collections.abc import Mapping
from collections.abc import Sequence
from pathlib import Path

from loguru import logger
from pydantic import Field

from imbue.mngr_vps.errors import VpsApiError
from imbue.mngr_vps.errors import VpsProvisioningError
from imbue.mngr_vps.primitives import VpsInstanceId
from imbue.mngr_vps.primitives import VpsInstanceStatus
from imbue.mngr_vps.vps_client import VpsClientInterface

# Default VM size when a plan string can't be parsed.
_DEFAULT_VCPUS = 2
_DEFAULT_MEMORY_MB = 4096

# libvirt domain names are restricted to alphanumerics, '.', '_', '-'.
_DOMAIN_NAME_RE = re.compile(r"[^a-zA-Z0-9._-]")


def _run(cmd: Sequence[str], timeout: float = 120.0) -> str:
    """Run a command, returning stdout. Raise VpsApiError on non-zero exit."""
    logger.trace("bowei_cloud run: {}", " ".join(cmd))
    try:
        result = subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise VpsApiError(0, f"Command timed out: {' '.join(cmd)}") from e
    if result.returncode != 0:
        raise VpsApiError(
            result.returncode,
            f"Command failed ({' '.join(cmd)}): {result.stderr.strip() or result.stdout.strip()}",
        )
    return result.stdout.strip()


def _run_optional(cmd: Sequence[str], timeout: float = 120.0) -> str:
    """Run a command, returning stdout and '' on non-zero exit (best-effort)."""
    try:
        result = subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ""
    return (result.stdout or "").strip()


def _parse_plan(plan: str) -> tuple[int, int]:
    """Parse a '<vcpus>c<ram_gb>g' plan string into (vcpus, memory_mb)."""
    m = re.fullmatch(r"\s*(\d+)c(\d+)g\s*", plan)
    if m:
        return int(m.group(1)), int(m.group(2)) * 1024
    logger.warning("bowei_cloud: could not parse plan {!r}, defaulting to {}c{}g", plan, _DEFAULT_VCPUS, _DEFAULT_MEMORY_MB // 1024)
    return _DEFAULT_VCPUS, _DEFAULT_MEMORY_MB


def _sanitize_domain_name(name: str) -> str:
    return _DOMAIN_NAME_RE.sub("-", name)


class BoweiCloudVpsClient(VpsClientInterface):
    """VPS client that provisions nested-KVM VMs via a libvirt daemon.

    By default uses the local libvirt daemon. When ``libvirt_ssh_host`` is set,
    every virsh/qemu-img/virt-install command runs over SSH on that host, so mngr
    can drive a remote KVM host's libvirt (the VMs' IPs must be routable back to
    where mngr runs).
    """

    base_image: Path = Field(frozen=True, description="Backing cloud image (qcow2).")
    images_dir: Path = Field(frozen=True, description="Directory for per-VM disks, seed ISOs and the registry.")
    network: str = Field(frozen=True, description="libvirt network to attach VMs to.")
    vm_disk_gb: int = Field(frozen=True, description="Virtual disk size in GB per VM.")
    libvirt_ssh_host: str | None = Field(
        default=None,
        frozen=True,
        description="When set, run all libvirt commands over SSH on this host (e.g. root@10.124.0.3).",
    )
    public_face_host: str | None = Field(
        default=None, frozen=True, description="Public host mngr reaches VMs over (forwarded ports).",
    )
    public_outer_port: int = Field(default=2229, frozen=True, description="Public port forwarded to each VM's outer sshd (:22).")
    allowed_ssh_cidr: str | None = Field(
        default=None, frozen=True, description="Source CIDR allowed on the forwarded public SSH ports.",
    )
    container_ssh_port: int = Field(default=2222, frozen=True, description="Container sshd port (published in the VM; forwarded in public-face mode).")

    @property
    def _is_public_face(self) -> bool:
        return self.public_face_host is not None

    @property
    def _is_remote(self) -> bool:
        return self.libvirt_ssh_host is not None

    def _wrap_ssh(self, cmd: Sequence[str]) -> list[str]:
        """Wrap a command to run on the remote libvirt host over SSH (no-op when local).

        When remote, the whole command is ``shlex.join``-ed into a single argument
        so SSH passes it verbatim to the remote shell (no re-quoting loss), and
        Path objects are stringified first.
        """
        stringified = [str(a) for a in cmd]
        if self.libvirt_ssh_host is None:
            return stringified
        return [
            "ssh",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15",
            self.libvirt_ssh_host,
            shlex.join(stringified),
        ]

    def _run(self, cmd: Sequence[str], timeout: float = 120.0) -> str:
        """Run a (possibly remote) command, returning stdout. Raise VpsApiError on non-zero exit."""
        return _run(self._wrap_ssh(cmd), timeout=timeout)

    def _run_optional(self, cmd: Sequence[str], timeout: float = 120.0) -> str:
        """Run a (possibly remote) command, returning stdout and '' on non-zero exit."""
        return _run_optional(self._wrap_ssh(cmd), timeout=timeout)

    # Override the slow-provisioning threshold: a nested-KVM VM + in-VM apt/Docker
    # install routinely takes longer than the 60s cloud default.
    slow_provisioning_warning_threshold_seconds: float = Field(
        default=180.0,
        description="Warn if provisioning takes longer than this many seconds.",
    )

    # ------------------------------------------------------------------
    # registry
    # ------------------------------------------------------------------

    @property
    def _registry_path(self) -> Path:
        return self.images_dir / "registry.json"

    def _load_registry(self) -> dict[str, dict]:
        # The registry lives on the libvirt host (local or remote) alongside the
        # VM disks, so it is the single source of truth across mngr instances.
        if self.libvirt_ssh_host is None:
            path = self._registry_path
            if not path.exists():
                return {}
            try:
                return json.loads(path.read_text())
            except (json.JSONDecodeError, OSError) as e:
                logger.warning("bowei_cloud: failed to read registry {}: {}", path, e)
                return {}
        text = self._run_optional(["cat", str(self._registry_path)])
        if not text:
            return {}
        try:
            return json.loads(text)
        except json.JSONDecodeError as e:
            logger.warning("bowei_cloud: failed to parse remote registry: {}", e)
            return {}

    def _save_registry(self, registry: dict[str, dict]) -> None:
        payload = json.dumps(registry, indent=2, sort_keys=True)
        if self.libvirt_ssh_host is None:
            self.images_dir.mkdir(parents=True, exist_ok=True)
            self._registry_path.write_text(payload)
            return
        # Write atomically on the remote host via a temp file + mv, feeding the
        # payload over stdin so it never touches a remote shell argument.
        tmp = f"{self._registry_path}.tmp"
        qdir = shlex.quote(str(self.images_dir))
        qtmp = shlex.quote(tmp)
        qfinal = shlex.quote(str(self._registry_path))
        cmd = self._wrap_ssh(["sh", "-c", f"mkdir -p {qdir} && cat > {qtmp} && mv {qtmp} {qfinal}"])
        try:
            subprocess.run(cmd, input=payload, text=True, capture_output=True, timeout=30.0, check=True)
        except subprocess.CalledProcessError as e:
            raise VpsApiError(e.returncode, f"Failed to write remote registry: {e.stderr}") from e
        except subprocess.TimeoutExpired as e:
            raise VpsApiError(0, "Timed out writing remote registry") from e

    @property
    def _ssh_keys_path(self) -> Path:
        return self.images_dir / "ssh_keys.json"

    # ------------------------------------------------------------------
    # instance lifecycle
    # ------------------------------------------------------------------

    def create_instance(
        self,
        label: str,
        region: str,
        plan: str,
        user_data: str,
        ssh_key_ids: Sequence[str],
        tags: Mapping[str, str],
    ) -> VpsInstanceId:
        del region, ssh_key_ids  # unused: single libvirt host; key is injected via user_data
        self._ensure_images_dir()

        domain = _sanitize_domain_name(label)
        disk_path = self.images_dir / f"{domain}.qcow2"
        seed_path = self.images_dir / f"{domain}-seed.iso"

        vcpus, memory_mb = _parse_plan(plan)

        # Copy-on-write overlay on the base cloud image (thin, fast).
        if self._remote_file_exists(disk_path):
            raise VpsProvisioningError(f"VM disk already exists: {disk_path}")
        self._run(
            [
                "qemu-img", "create", "-f", "qcow2",
                "-b", str(self.base_image),
                "-F", "qcow2",
                str(disk_path),
                f"{self.vm_disk_gb}G",
            ]
        )

        # NoCloud seed ISO carrying the cloud-init user-data (built locally,
        # then copied to the (possibly remote) images_dir).
        self._build_seed_iso(seed_path, user_data, domain)

        # Define + start the VM. `--import` boots the existing (bootable) overlay.
        self._run(
            [
                "virt-install",
                "--name", domain,
                "--memory", str(memory_mb),
                "--vcpus", str(vcpus),
                "--disk", f"path={disk_path},format=qcow2,bus=virtio",
                "--disk", f"path={seed_path},device=cdrom,readonly=on",
                "--network", f"network={self.network}",
                "--import",
                "--noautoconsole",
                "--os-variant", "ubuntu24.04",
                "--quiet",
            ],
            timeout=120.0,
        )

        # Persist the instance so discovery/destroy can find it later.
        registry = self._load_registry()
        registry[domain] = {
            "label": label,
            "tags": [f"{k}={v}" for k, v in tags.items()],
            "disk_path": str(disk_path),
            "seed_iso": str(seed_path),
            "vcpus": vcpus,
            "memory_mb": memory_mb,
        }
        self._save_registry(registry)

        logger.info("Created bowei_cloud VM {} ({} vCPU, {} MB)", domain, vcpus, memory_mb)
        return VpsInstanceId(domain)

    def _ensure_images_dir(self) -> None:
        """Make sure the (possibly remote) images_dir exists."""
        self._run(["mkdir", "-p", str(self.images_dir)], timeout=30.0)

    def _remote_file_exists(self, path: Path) -> bool:
        """Whether ``path`` exists on the (possibly remote) libvirt host."""
        q = shlex.quote(str(path))
        return self._run_optional(["sh", "-c", f"test -e {q} && echo yes || echo no"]) == "yes"

    def _build_seed_iso(self, seed_path: Path, user_data: str, domain: str) -> None:
        """Build a NoCloud seed ISO at ``seed_path``.

        When the libvirt host is remote, the ISO is built ON that host (which has
        cloud-localds) so no ISO tooling is needed where mngr runs (e.g. a Mac);
        the user-data/meta-data are written over SSH stdin. Locally, build with
        cloud-localds/genisoimage.
        """
        meta_data = f"instance-id: {domain}\nlocal-hostname: {domain}\n"
        if self.libvirt_ssh_host is not None:
            import secrets

            tmpdir = f"/tmp/bowei-seed-{secrets.token_hex(8)}"
            self._run(["mkdir", "-p", tmpdir], timeout=15.0)
            try:
                self._write_remote_stdin(f"{tmpdir}/user-data", user_data)
                self._write_remote_stdin(f"{tmpdir}/meta-data", meta_data)
                # Prefer cloud-localds; fall back to genisoimage on the host.
                try:
                    self._run(
                        ["cloud-localds", str(seed_path), f"{tmpdir}/user-data", f"{tmpdir}/meta-data"],
                        timeout=60.0,
                    )
                except VpsApiError:
                    self._run(
                        [
                            "genisoimage", "-output", str(seed_path),
                            "-volid", "cidata", "-joliet", "-rock",
                            f"{tmpdir}/user-data", f"{tmpdir}/meta-data",
                        ],
                        timeout=60.0,
                    )
            finally:
                self._run_optional(["rm", "-rf", tmpdir])
            return
        with tempfile.TemporaryDirectory() as d:
            d_path = Path(d)
            (d_path / "user-data").write_text(user_data)
            (d_path / "meta-data").write_text(meta_data)
            local_iso = d_path / "seed.iso"
            try:
                _run(
                    ["cloud-localds", str(local_iso), str(d_path / "user-data"), str(d_path / "meta-data")],
                    timeout=60.0,
                )
            except VpsApiError:
                _run(
                    [
                        "genisoimage", "-output", str(local_iso),
                        "-volid", "cidata", "-joliet", "-rock",
                        str(d_path / "user-data"), str(d_path / "meta-data"),
                    ],
                    timeout=60.0,
                )
            self._place_file(local_iso, seed_path)

    def _write_remote_stdin(self, remote_path: str, content: str) -> None:
        """Write ``content`` to ``remote_path`` on the libvirt host via SSH stdin."""
        q = shlex.quote(remote_path)
        cmd = self._wrap_ssh(["sh", "-c", f"cat > {q}"])
        try:
            subprocess.run(cmd, input=content, text=True, capture_output=True, timeout=30.0, check=True)
        except subprocess.CalledProcessError as e:
            raise VpsApiError(e.returncode, f"Failed to write {remote_path}: {e.stderr}") from e
        except subprocess.TimeoutExpired as e:
            raise VpsApiError(0, f"Timed out writing {remote_path}") from e

    def _place_file(self, local_path: Path, remote_path: Path) -> None:
        """Move/copy a local file to ``remote_path`` (local mv or remote scp)."""
        if self.libvirt_ssh_host is None:
            # Same host: move into place (images_dir already exists).
            local_path.replace(remote_path)
            return
        # Remote: scp to the libvirt host, then it's already at the remote path.
        scp = ["scp", "-o", "StrictHostKeyChecking=accept-new", str(local_path), f"{self.libvirt_ssh_host}:{remote_path}"]
        _run(scp, timeout=120.0)

    def destroy_instance(self, instance_id: VpsInstanceId) -> None:
        domain = str(instance_id)
        registry = self._load_registry()
        entry = registry.pop(domain, None)

        # Power off + undefine the domain (best-effort if already gone).
        self._run_optional(["virsh", "destroy", domain])
        self._run_optional(["virsh", "undefine", domain])

        # Remove the per-VM disk + seed ISO (on the libvirt host).
        if entry is not None:
            for key in ("disk_path", "seed_iso"):
                p = entry[key]
                self._run_optional(["rm", "-f", p])
        # Tear down the public-face DNAT so no SSH ports stay exposed.
        self.teardown_public_face_dnat()
        self._save_registry(registry)
        logger.info("Destroyed bowei_cloud VM {}", domain)

    def get_instance_status(self, instance_id: VpsInstanceId) -> VpsInstanceStatus:
        domain = str(instance_id)
        state = self._run_optional(["virsh", "domstate", domain])
        if not state:
            return VpsInstanceStatus.UNKNOWN
        if state == "running":
            return VpsInstanceStatus.ACTIVE
        if state in ("shut off", "pmsuspended", "paused"):
            return VpsInstanceStatus.HALTED
        if state in ("crashed", "dying"):
            return VpsInstanceStatus.UNKNOWN
        return VpsInstanceStatus.UNKNOWN

    def get_instance_ip(self, instance_id: VpsInstanceId) -> str:
        if self._is_public_face:
            # mngr reaches the VM over the KVM host's public IP + forwarded
            # ports; the private DHCP IP is resolved + wired up in
            # wait_for_instance_active (and stored for teardown).
            return self.public_face_host  # type: ignore[return-value]
        domain = str(instance_id)
        mac = self._get_domain_mac(domain)
        if mac is None:
            raise VpsProvisioningError(f"VM {domain} has no network interface")
        ip = self._get_ip_for_mac(mac)
        if not ip:
            raise VpsProvisioningError(f"VM {domain} (mac {mac}) has no DHCP lease yet")
        return ip

    def wait_for_instance_active(
        self,
        instance_id: VpsInstanceId,
        timeout_seconds: float = 300.0,
    ) -> str:
        """Poll until the VM is up; for public-face mode, also wire up the DNAT.

        In public-face mode the VM's private libvirt IP is unreachable from mngr,
        so we install (or re-point) a pair of restricted DNAT rules on the KVM host
        -- public:public_outer_port -> VM:22 and public:container_ssh_port ->
        VM:container_ssh_port -- then return the public host. Only the two SSH
        ports are forwarded, restricted to allowed_ssh_cidr.
        """
        if not self._is_public_face:
            return super().wait_for_instance_active(instance_id, timeout_seconds=timeout_seconds)
        if not self.allowed_ssh_cidr:
            raise VpsProvisioningError(
                "public_face_host is set but allowed_ssh_cidr is not; refusing to "
                "expose SSH ports to 0.0.0.0/0. Set allowed_ssh_cidr to your IP."
            )
        domain = str(instance_id)
        start = time.monotonic()
        private_ip = ""
        while time.monotonic() - start < timeout_seconds:
            if self.get_instance_status(instance_id) == VpsInstanceStatus.ACTIVE:
                mac = self._get_domain_mac(domain)
                if mac is not None:
                    private_ip = self._get_ip_for_mac(mac)
                if private_ip:
                    break
            time.sleep(5.0)
        if not private_ip:
            raise VpsProvisioningError(f"VM {domain} did not get a DHCP lease within {timeout_seconds}s")
        self._setup_public_face_dnat(domain, private_ip)
        return self.public_face_host  # type: ignore[return-value]

    def _setup_public_face_dnat(self, domain: str, private_ip: str) -> None:
        """Install/re-point restricted DNAT for one VM's two SSH ports on the KVM host.

        Uses dedicated nft chains (flushed + re-added per VM) so only the latest VM
        is reachable and no stale rules linger. Only the outer sshd (:22) and the
        container sshd (:container_ssh_port) are forwarded, restricted to
        allowed_ssh_cidr. Nothing else is exposed.
        """
        cidr = self.allowed_ssh_cidr
        outer = self.public_outer_port
        cport = self._container_ssh_port_for_dnat
        qcidr = shlex.quote(cidr)
        # One-time idempotent setup: create the dedicated chains + jumps. The
        # `add chain`/`add rule` calls error if they already exist; we tolerate that
        # by running the whole script with check=False and ignoring stderr.
        setup = (
            "add chain ip nat bowei_pubface\n"
            "add rule ip nat PREROUTING jump bowei_pubface\n"
            "add chain ip filter bowei_pubface_fwd\n"
            "add rule ip filter FORWARD jump bowei_pubface_fwd\n"
        )
        self._run_optional_nft(setup)
        # Per-VM rules: flush the dedicated chains, then add only the two SSH
        # forwards, restricted to allowed_ssh_cidr.
        rules = (
            f"flush chain ip nat bowei_pubface\n"
            f"add rule ip nat bowei_pubface iifname eth0 tcp dport {outer} ip saddr {qcidr} counter dnat to {private_ip}:22\n"
            f"add rule ip nat bowei_pubface iifname eth0 tcp dport {cport} ip saddr {qcidr} counter dnat to {private_ip}:{cport}\n"
            f"flush chain ip filter bowei_pubface_fwd\n"
            f"add rule ip filter bowei_pubface_fwd ip saddr {qcidr} ip daddr {private_ip} oifname virbr0 counter accept\n"
        )
        if not self._run_optional_nft(rules):
            raise VpsProvisioningError(f"Failed to install public-face DNAT for {domain}")
        logger.info(
            "bowei_cloud: wired public face {}:{}->{}:22 and {}:{}->{}:{} (cidr {})",
            self.public_face_host, outer, private_ip, self.public_face_host, cport, private_ip, cport, cidr,
        )

    def _run_optional_nft(self, ruleset: str) -> bool:
        """Feed a ruleset to `nft -f -` on the (possibly remote) KVM host; False on failure."""
        cmd = self._wrap_ssh(["nft", "-f", "-"])
        try:
            subprocess.run(cmd, input=ruleset, text=True, capture_output=True, timeout=30.0, check=True)
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            logger.debug("bowei_cloud: nft -f - failed (may be benign for idempotent setup): {}", e)
            return False

    @property
    def _container_ssh_port_for_dnat(self) -> int:
        """The container sshd port to forward."""
        return self.container_ssh_port

    def teardown_public_face_dnat(self) -> None:
        """Remove the public-face DNAT (called on destroy) so no ports stay exposed."""
        if not self._is_public_face:
            return
        self._run(["nft", "flush", "chain", "ip", "nat", "bowei_pubface"], timeout=15.0)
        self._run(["nft", "flush", "chain", "ip", "filter", "bowei_pubface_fwd"], timeout=15.0)

    def _get_domain_mac(self, domain: str) -> str | None:
        xml = self._run_optional(["virsh", "dumpxml", domain])
        if not xml:
            return None
        m = re.search(r"<interface[^>]*>.*?<mac address=['\"]([0-9a-fA-F:]+)['\"]", xml, re.DOTALL)
        return m.group(1) if m else None

    def _get_ip_for_mac(self, mac: str) -> str:
        """Look up the DHCP lease IP for a MAC on the configured network."""
        leases = self._run_optional(["virsh", "net-dhcp-leases", self.network])
        for line in leases.splitlines():
            # virsh net-dhcp-leases columns: Expiry, MAC, Protocol, IP, Hostname, ClientID/DUID
            # The MAC column may carry a trailing lease-time suffix in some libvirt versions.
            if mac.lower() in line.lower():
                # The IP is the 4th whitespace-separated token, possibly with a /prefix.
                tokens = line.split()
                for tok in tokens:
                    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+(/\d+)?", tok):
                        return tok.split("/")[0]
        return ""

    def list_instances(self) -> list[dict]:
        """List all bowei_cloud-managed VMs with their tags + live IP.

        Shape mirrors the Vultr client so the shared VPS discovery flow can
        filter by the ``mngr-provider=<name>`` tag and read ``main_ip``.
        """
        registry = self._load_registry()
        instances: list[dict] = []
        for domain, entry in registry.items():
            ip = "0.0.0.0"
            try:
                mac = self._get_domain_mac(domain)
                if mac is not None:
                    ip = self._get_ip_for_mac(mac) or "0.0.0.0"
            except Exception as e:  # noqa: BLE001
                logger.debug("bowei_cloud: could not resolve IP for {}: {}", domain, e)
            instances.append(
                {
                    "name": domain,
                    "label": entry.get("label", domain),
                    "tags": entry.get("tags", []),
                    "main_ip": ip,
                    "vps_instance_id": domain,
                }
            )
        return instances

    # ------------------------------------------------------------------
    # ssh keys (the key is injected via cloud-init user_data, so these are a
    # local no-op registry that exists only to satisfy the interface contract)
    # ------------------------------------------------------------------

    def _load_ssh_keys(self) -> dict[str, dict]:
        if self.libvirt_ssh_host is None:
            path = self._ssh_keys_path
            if not path.exists():
                return {}
            try:
                return json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                return {}
        text = self._run_optional(["cat", str(self._ssh_keys_path)])
        if not text:
            return {}
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {}

    def _save_ssh_keys(self, keys: dict[str, dict]) -> None:
        payload = json.dumps(keys, indent=2, sort_keys=True)
        if self.libvirt_ssh_host is None:
            self.images_dir.mkdir(parents=True, exist_ok=True)
            self._ssh_keys_path.write_text(payload)
            return
        tmp = f"{self._ssh_keys_path}.tmp"
        qdir = shlex.quote(str(self.images_dir))
        qtmp = shlex.quote(tmp)
        qfinal = shlex.quote(str(self._ssh_keys_path))
        cmd = self._wrap_ssh(["sh", "-c", f"mkdir -p {qdir} && cat > {qtmp} && mv {qtmp} {qfinal}"])
        try:
            subprocess.run(cmd, input=payload, text=True, capture_output=True, timeout=30.0, check=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass  # best-effort: the key is only a local no-op registry

    def upload_ssh_key(self, name: str, public_key: str) -> str:
        key_id = f"bowei-{uuid.uuid4().hex[:8]}"
        keys = self._load_ssh_keys()
        keys[key_id] = {"name": name, "public_key": public_key}
        self._save_ssh_keys(keys)
        logger.debug("bowei_cloud: recorded ssh key {} ({})", name, key_id)
        return key_id

    def delete_ssh_key(self, key_id: str) -> None:
        keys = self._load_ssh_keys()
        keys.pop(key_id, None)
        self._save_ssh_keys(keys)
