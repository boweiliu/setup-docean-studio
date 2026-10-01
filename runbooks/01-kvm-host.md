# 01 — KVM host

**Goal:** a DigitalOcean droplet that can host nested-KVM workspace VMs (libvirt +
mngr + the `docean_cloud` provider + the workspace template).

**Prereqs:** `.env` with your `DIGITALOCEAN_API_KEY` (see `.env.example`). Everything
else auto-discovers (SSH key id, VPC, region).

## Steps

1. Spawn a dedicated-CPU droplet with nested KVM (e.g. `s-8vcpu-32gb-amd`):
   ```bash
   source scripts/lib/do.sh
   read -r ID PUB PRIV < <(do_spawn docean-kvm32 s-8vcpu-32gb-amd)
   echo "$PUB" > /tmp/kvm-host.ip
   ```
2. Provision it (idempotent — installs libvirt, the cloud image, mngr + the
   `docean_cloud` provider from `provider/`, the dwt clone at the latest `minds-v*`
   tag, the `[create_templates.docean_cloud]` block, and the disk config):
   ```bash
   ./scripts/kvm-host-setup.sh "$PUB" 2c8g   # 2nd arg = default_plan for slices
   ```

## Verify

```bash
ssh root@"$PUB" 'ls /dev/kvm && virsh net-start default 2>/dev/null; virsh net-list --name'
# expect: /dev/kvm present, "default" net
MNGR_HOST_DIR=/root/.mngr MNGR_PREFIX=minds- ssh root@"$PUB" \
  '/root/mngr/.venv/bin/mngr config get create_templates.docean_cloud'
# expect: the docean_cloud create-template block is present
```

## Gotchas

- **First-boot cloud-init holds the apt lock** on a fresh droplet — wait for
  `cloud-init status --wait` before running `kvm-host-setup.sh` (it's idempotent;
  re-run after cloud-init finishes).
- **The `[create_templates.docean_cloud]` block is mandatory** — without it
  `mngr create --template main` builds a bare debian (no supervisord → the app
  hangs on "loading workspace"). The setup script appends it; don't skip it.
- **`vm_disk_gb=80`, `outer_disk_reserved_gb=30`** — the dwt Dockerfile build needs
  ~15-20G of docker headroom on the VM root fs; the defaults (40/5) fail with "No
  space left on device" at `RUN mv /home/user/workspace /docker_build_code`.
- **Nested KVM** — only DO dedicated-CPU sizes (`g-*`, `s-*-amd`) have it; shared
  CPU does not. Always `ls /dev/kvm` after spawn.
