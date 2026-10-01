#!/usr/bin/env bash
# Create one bowei_cloud slice on a KVM host (standard way) + verify supervisord.
#   create-slice.sh <kvm-host-ip> <name> <plan>
# plan examples: 2c8g, 2c6g, 1c2g
set -euo pipefail
HOST="${1:?usage: create-slice.sh <kvm-host-ip> <name> <plan>}"
NAME="${2:?usage: create-slice.sh <kvm-host-ip> <name> <plan>}"
PLAN="${3:?usage: create-slice.sh <kvm-host-ip> <name> <plan>}"

ssh -o StrictHostKeyChecking=no root@$HOST bash -s "$NAME" "$PLAN" <<'REMOTE'
set -euo pipefail
NAME="$1"; PLAN="$2"
cd /tmp/dwt-clone
export MNGR_HOST_DIR=/root/.mngr
export MNGR_PREFIX=minds-
MN=/root/mngr/.venv/bin/mngr
# set the plan for this create (default_plan is the fallback; --plan overrides per-host)
$MN config set --scope user providers.bowei_cloud.default_plan "$PLAN"
echo "==> creating $NAME ($PLAN) on bowei_cloud (build ~5-8 min)..."
$MN create system-services@${NAME}.bowei_cloud --new-host \
  --template main --template bowei_cloud \
  --branch :mngr/${NAME} \
  --label workspace_display_name=${NAME} --label is_primary=true --label user_created=true \
  --no-ensure-clean --format jsonl --no-connect 2>&1 | tee /tmp/create-${NAME}.jsonl
echo "==> create finished"
REMOTE
echo "==> [$HOST] slice $NAME ($PLAN) created"
