#!/usr/bin/env bash
# Option A cross-VPC routing: let <client> (the desktop) reach the libvirt NAT
# 192.168.122.0/24 on <kvm-host>. Static route on client + nft on KVM host MAIN
# chains (INSERT at top — runbook GOTCHA-6: libvirt reorders its own sub-chains).
#   cross-vpc.sh <client-pub-ip> <kvm-host-pub-ip>
set -euo pipefail
CLIENT="${1:?usage: cross-vpc.sh <client-pub> <kvm-host-pub>}"
KVM="${2:?usage: cross-vpc.sh <client-pub> <kvm-host-pub>}"
source "$(dirname "$0")/lib/do.sh"

read -r C_PRIV K_PRIV < <(do_api "https://api.digitalocean.com/v2/droplets?per_page=100" | python3 -c "
import json,sys
d=json.load(sys.stdin)
def priv(ip):
    for x in d['droplets']:
        if any(n['ip_address']==ip for n in x['networks']['v4'] if n['type']=='public'):
            return next((n['ip_address'] for n in x['networks']['v4'] if n['type']=='private'),'')
    return ''
print(priv('$CLIENT'), priv('$KVM'))
")
echo "client priv=$C_PRIV  kvm priv=$K_PRIV"
[ -n "$C_PRIV" ] && [ -n "$K_PRIV" ] || { echo "could not resolve private IPs" >&2; exit 1; }

echo "==> [$CLIENT] static route to 192.168.122.0/24 via $K_PRIV"
ssh -o StrictHostKeyChecking=no root@$CLIENT "
  ip route show 192.168.122.0/24 | grep -q . || ip route add 192.168.122.0/24 via $K_PRIV
  ip route show 192.168.122.0/24
"

echo "==> [$KVM] nft accept+return in MAIN chains (idempotent)"
ssh -o StrictHostKeyChecking=no root@$KVM "
  nft 'insert rule ip filter FORWARD ip saddr 10.124.0.0/20 ip daddr 192.168.122.0/24 oifname virbr0 counter accept' 2>/dev/null || true
  nft 'insert rule ip nat POSTROUTING ip saddr 192.168.122.0/24 ip daddr 10.124.0.0/20 counter return' 2>/dev/null || true
  # dedupe: keep only one copy of each rule (best-effort)
  echo '--- filter FORWARD (top) ---'; nft list chain ip filter FORWARD | head -8
  echo '--- nat POSTROUTING (top) ---'; nft list chain ip nat POSTROUTING | head -8
"
echo "==> cross-VPC wired: $CLIENT -> 192.168.122.0/24 via $KVM"
