#!/usr/bin/env bash
# Per-VM DNAT on a KVM host: a unique public port per slice VM -> VM:2222 (the
# container sshd), restricted to ALLOW_SOURCES (your IP by default). Multi-VM
# (does NOT flush — adds one rule per VMxsource), persisted across reboot via a
# systemd oneshot. This is what lets a REMOTE client (your desktop) reach every
# slice on a host at once.
#
#   per-vm-dnat.sh <kvm-host-ip> <port-map-file> [allow-sources...]
#   port-map-file: lines of "<pub_port> <vm_ip>"  e.g. "23001 192.168.122.174"
#   allow-sources: space-sep CIDRs allowed on the forwarded ports (default: your IP)
set -euo pipefail
HOST="${1:?usage: per-vm-dnat.sh <kvm-host-ip> <port-map-file> [allow-sources...]}"
MAPFILE="${2:?usage: per-vm-dnat.sh <kvm-host-ip> <port-map-file> [allow-sources...]}"
shift 2
source "$(dirname "$0")/lib/do.sh"
ALLOW_SOURCES="${*:-$(do_my_ip)}"
MAP="$(grep -vE '^\s*(#|$)' "$MAPFILE" | tr '\n' ' ' | sed 's/ $//')"

# The on-host apply script (creates the bowei_pubface chains + jumps if missing,
# then adds one DNAT rule per VMxsource; idempotent via flush-then-add).
APPLY=/usr/local/sbin/bowei-pubface-apply.sh
ssh -o StrictHostKeyChecking=no root@$HOST "cat > $APPLY" <<'SVC'
#!/usr/bin/env bash
set -euo pipefail
# Multi-VM per-VM DNAT. MAP env: lines of "<pub_port> <vm_ip>". ALLOW_SOURCES space-sep.
ALLOW_SOURCES="${ALLOW_SOURCES:-}"
for i in $(seq 1 30); do nft list table ip nat >/dev/null 2>&1 && nft list table ip filter >/dev/null 2>&1 && break; sleep 1; done
nft list chain ip nat PREROUTING >/dev/null 2>&1 || nft add chain ip nat PREROUTING '{ type nat hook prerouting priority dstnat; }'
nft list chain ip nat bowei_pubface >/dev/null 2>&1 || nft add chain ip nat bowei_pubface
nft list chain ip filter bowei_pubface_fwd >/dev/null 2>&1 || nft add chain ip filter bowei_pubface_fwd
nft list chain ip nat PREROUTING 2>/dev/null | grep -q "jump bowei_pubface" || nft insert rule ip nat PREROUTING jump bowei_pubface
nft list chain ip filter FORWARD 2>/dev/null | grep -q "jump bowei_pubface_fwd" || nft insert rule ip filter FORWARD jump bowei_pubface_fwd
nft flush chain ip nat bowei_pubface
nft flush chain ip filter bowei_pubface_fwd
echo "$MAP" | while read -r port vmip; do
  [ -z "$port" ] && continue
  for src in $ALLOW_SOURCES; do
    nft add rule ip nat bowei_pubface iifname eth0 tcp dport "$port" ip saddr "$src" counter dnat to "$vmip":2222
    nft add rule ip filter bowei_pubface_fwd ip saddr "$src" ip daddr "$vmip" oifname virbr0 counter accept
  done
done
SVC
ssh -o StrictHostKeyChecking=no root@$HOST "
chmod +x $APPLY
cat > /etc/systemd/system/bowei-pubface.service <<'UNIT'
[Unit]
Description=bowei per-VM pubface DNAT (multi-VM)
After=libvirtd.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$APPLY
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable bowei-pubface.service >/dev/null
MAP='$MAP' ALLOW_SOURCES='$ALLOW_SOURCES' $APPLY && echo 'DNAT applied'
echo '--- dnat rules ---'; nft list chain ip nat bowei_pubface | grep -c dnat
"
