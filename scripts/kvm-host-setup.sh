#!/usr/bin/env bash
# Idempotent KVM-host setup for a fresh bowei_cloud nested-KVM host.
# Run from the Mac:  ./kvm-host-setup.sh <kvm-host-public-ip> <default_plan>
# Pins mngr + dwt to the latest minds-v* tag (override with MNGR_TAG / DWT_TAG).
set -euo pipefail
HOST="${1:?usage: kvm-host-setup.sh <kvm-host-ip> <default_plan>}"
PLAN="${2:-2c8g}"
PLUGIN_SRC="$(cd "$(dirname "$0")/.." && pwd)/provider/mngr_bowei_cloud"
MNGR_TAG="${MNGR_TAG:-latest}"
DWT_TAG="${DWT_TAG:-latest}"
latest_tag() { git ls-remote --tags --refs "$1" 2>/dev/null | sed 's#.*refs/tags/##' | grep -E '^minds-v[0-9]' | sort -V | tail -1; }
[ "$MNGR_TAG" = latest ] && MNGR_TAG="$(latest_tag https://github.com/imbue-ai/mngr.git)"
[ "$DWT_TAG" = latest ] && DWT_TAG="$(latest_tag https://github.com/imbue-ai/default-workspace-template.git)"
echo "==> pinning mngr@$MNGR_TAG dwt@$DWT_TAG"

echo "==> [$HOST] rsync bowei_cloud plugin"
rsync -az --delete "$PLUGIN_SRC/" root@$HOST:/tmp/mngr_bowei_cloud/

ssh -o StrictHostKeyChecking=no root@$HOST bash -s "$PLAN" "$MNGR_TAG" "$DWT_TAG" <<'REMOTE'
set -euo pipefail
PLAN="$1"; MNGR_TAG="$2"; DWT_TAG="$3"
export DEBIAN_FRONTEND=noninteractive

echo "==> install infra"
apt-get update -qq
apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  genisoimage cloud-image-utils jq rsync tmux git curl cpu-checker >/dev/null
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true
mkdir -p /var/lib/libvirt/images
[ -f /var/lib/libvirt/images/ubuntu-24.04-server-cloudimg-amd64.img ] || \
  curl -fsSL -o /var/lib/libvirt/images/ubuntu-24.04-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
chmod 644 /var/lib/libvirt/images/ubuntu-24.04-server-cloudimg-amd64.img

echo "==> verify nested KVM"
ls -l /dev/kvm && (kvm-ok 2>/dev/null || true)

echo "==> clone mngr@$MNGR_TAG + drop in plugin"
if [ ! -d /root/mngr/.git ]; then
  git clone https://github.com/imbue-ai/mngr.git /root/mngr
fi
cd /root/mngr && git fetch --tags --quiet && git checkout "$MNGR_TAG" --quiet
mkdir -p /root/mngr/libs/mngr_bowei_cloud
cp -r /tmp/mngr_bowei_cloud/. /root/mngr/libs/mngr_bowei_cloud/

echo "==> uv + sync"
if ! command -v uv >/dev/null; then curl -fsSL https://astral.sh/uv/install.sh | bash; fi
source /root/.local/bin/env 2>/dev/null || true
cd /root/mngr && uv sync --all-packages

echo "==> provider config"
export MNGR_HOST_DIR=/root/.mngr
export MNGR_PREFIX=minds-
MN=/root/mngr/.venv/bin/mngr
$MN config set --scope user commands.create.type command
$MN config set --scope user providers.bowei_cloud.docker_install_timeout 900
$MN config set --scope user providers.bowei_cloud.instance_boot_timeout 600
$MN config set --scope user providers.bowei_cloud.ssh_connect_timeout 120
$MN config set --scope user providers.bowei_cloud.vm_disk_gb 80
$MN config set --scope user providers.bowei_cloud.outer_disk_reserved_gb 30
$MN config set --scope user providers.bowei_cloud.default_plan "$PLAN"

echo "==> clone dwt@$DWT_TAG (on main at the tag)"
if [ ! -d /tmp/dwt-clone/.git ]; then
  git clone https://github.com/imbue-ai/default-workspace-template.git /tmp/dwt-clone
fi
cd /tmp/dwt-clone && git fetch --tags --quiet && git checkout main --quiet && git reset --hard "$DWT_TAG" --quiet

echo "==> append [create_templates.bowei_cloud] (root-cause fix)"
grep -q 'create_templates.bowei_cloud' /tmp/dwt-clone/.mngr/settings.toml || cat >> /tmp/dwt-clone/.mngr/settings.toml <<'TPL'

[create_templates.bowei_cloud]
provider = "bowei_cloud"
target_path = "/home/user/workspace/"
build_arg__extend = ["--file=system/Dockerfile", "."]
idle_mode = "disabled"
start_arg__extend = ["--security-opt=no-new-privileges", "--workdir=/", "--restart=unless-stopped"]
post_host_create_command__extend = ["/usr/local/bin/default-workspace-template-seed"]
pass_host_env__extend = ["MNGR_PREFIX"]
TPL

echo "==> done. host=$HOST plan=$PLAN"
REMOTE
echo "==> [$HOST] kvm-host-setup complete"
