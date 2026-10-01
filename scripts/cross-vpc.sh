#!/usr/bin/env bash
# Option A cross-VPC routing: let <client> (the webtop) reach the libvirt NAT
# 192.168.122.0/24 on <kvm-host>. Static route on client + nft on KVM host MAIN
# chains (INSERT at top — libvirt reorders its own LIBVIRT_* sub-chains on VM
# create/start, so custom rules must live in the MAIN chains above the jumps).
# Idempotent: re-running adds nothing if the route + rules already exist.
#   cross-vpc.sh <client-pub-ip> <kvm-host-pub-ip>
set -euo pipefail
CLIENT="${1:?usage: cross-vpc.sh <client-pub> <kvm-host-pub>}"
KVM="${2:?usage: cross-vpc.sh <client-pub> <kvm-host-pub>}"
source "$(dirname "$0")/lib/do.sh"

# Resolve the two droplets' private IPs + the VPC's private CIDR (not hardcoded —
# DO assigns the VPC range, e.g. 10.124.0.0/20, but it varies).
: "${DO_VPC_UUID:=$(do_resolve_vpc)}"
VPC_CIDR="${VPC_CIDR:-$(do_vpc_cidr)}"
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
echo "client priv=$C_PRIV  kvm priv=$K_PRIV  vpc cidr=$VPC_CIDR"
[ -n "$C_PRIV" ] && [ -n "$K_PRIV" ] && [ -n "$VPC_CIDR" ] || { echo "could not resolve private IPs / VPC CIDR" >&2; exit 1; }

echo "==> [$CLIENT] static route to 192.168.122.0/24 via $K_PRIV (idempotent)"
ssh -o StrictHostKeyChecking=no root@$CLIENT "
  ip route show 192.168.122.0/24 | grep -q . || ip route add 192.168.122.0/24 via $K_PRIV
  ip route show 192.168.122.0/24
"

echo "==> [$KVM] nft accept+return in MAIN chains (idempotent — only if absent)"
ssh -o StrictHostKeyChecking=no root@$KVM "
  FWD='ip saddr $VPC_CIDR ip daddr 192.168.122.0/24 oifname virbr0 counter accept'
  PRT='ip saddr 192.168.122.0/24 ip daddr $VPC_CIDR counter return'
  nft list chain ip filter FORWARD 2>/dev/null | grep -q -- \"ip saddr $VPC_CIDR ip daddr 192.168.122.0/24\" || nft insert rule ip filter FORWARD \$FWD
  nft list chain ip nat POSTROUTING 2>/dev/null | grep -q -- \"ip saddr 192.168.122.0/24 ip daddr $VPC_CIDR\" || nft insert rule ip nat POSTROUTING \$PRT
  echo '--- filter FORWARD (top) ---'; nft list chain ip filter FORWARD | head -8
  echo '--- nat POSTROUTING (top) ---'; nft list chain ip nat POSTROUTING | head -8
"
echo "==> cross-VPC wired: $CLIENT -> 192.168.122.0/24 via $KVM (cidr $VPC_CIDR)"
