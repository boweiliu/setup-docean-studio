#!/usr/bin/env bash
# DO droplet helpers. Source this file, then use the functions.
# Requires DIGITALOCEAN_API_KEY (from a local .env or the environment).
# Everything else (SSH key id, VPC, region) auto-discovers; override via env vars.
set -euo pipefail

# Local .env (holds DIGITALOCEAN_API_KEY=...). Override with ENV_FILE=...
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../.env}"
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a
: "${DIGITALOCEAN_API_KEY:?need DIGITALOCEAN_API_KEY in $ENV_FILE or the environment}"

DO_REGION="${DO_REGION:-sfo3}"

do_api() { curl -s -H "Authorization: Bearer $DIGITALOCEAN_API_KEY" "$@"; }

# Auto-discover the DO SSH key id matching a local public key (id_ed25519 or id_rsa).
do_resolve_ssh_key_id() {
  local pub
  for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    [ -f "$k" ] && pub="$(cut -d' ' -f1,2 "$k")" && break
  done
  [ -z "${pub:-}" ] && { echo "no local ssh pubkey found" >&2; return 1; }
  do_api "https://api.digitalocean.com/v2/account/keys" | python3 -c "
import json,sys
pub=sys.argv[1]
d=json.load(sys.stdin)
for k in d.get('ssh_keys',[]):
    if k.get('public_key','').split()[:2]==pub.split()[:2]:
        print(k['id']); raise SystemExit(0)
print('no DO key matches local pubkey', file=sys.stderr); raise SystemExit(1)
" "$pub"
}

# Auto-select the default VPC for the region (default-<region>).
do_resolve_vpc() {
  do_api "https://api.digitalocean.com/v2/vpcs?per_page=50" | python3 -c "
import json,sys
region=sys.argv[1]
d=json.load(sys.stdin)
for v in d.get('vpcs',[]):
    if v.get('region')==region and v.get('name')==f'default-{region}':
        print(v['id']); raise SystemExit(0)
print(f'no default VPC for {region}', file=sys.stderr); raise SystemExit(1)
" "$DO_REGION"
}

# The VPC's private CIDR (e.g. 10.124.0.0/20) — for cross-VPC nft rules.
do_vpc_cidr() {
  : "${DO_VPC_UUID:?set DO_VPC_UUID or run do_resolve_vpc first}"
  do_api "https://api.digitalocean.com/v2/vpcs/$DO_VPC_UUID" | python3 -c "
import json,sys
print(json.load(sys.stdin)['vpc']['ip_range'])
"
}

# Detect your public egress IP (for restricted DNAT / VNC allow).
do_my_ip() { curl -s --max-time 6 ifconfig.me || curl -s --max-time 6 https://api.ipify.org; }

# Resolve the latest minds-v* tag from a github repo (for mngr / dwt pinning).
do_latest_tag() {
  git ls-remote --tags --refs "$1" 2>/dev/null | sed 's#.*refs/tags/##' \
    | grep -E '^minds-v[0-9]' | sort -V | tail -1
}

# do_spawn <name> <size>  -> prints "id pub_ip priv_ip", waits for SSH.
do_spawn() {
  local name="$1" size="$2"
  : "${DO_SSH_KEY_ID:=$(do_resolve_ssh_key_id)}"   # lazy: only resolve when spawning
  : "${DO_VPC_UUID:=$(do_resolve_vpc)}"
  local body
  body=$(cat <<EOF
{"name":"$name","region":"$DO_REGION","size":"$size","image":"ubuntu-24-04-x64",
 "ssh_keys":[$DO_SSH_KEY_ID],"ipv6":true,"monitoring":true,
 "vpc_uuid":"$DO_VPC_UUID","tags":["setup-docean-studio"]}
EOF
)
  local id
  id=$(do_api -X POST -H "Content-Type: application/json" -d "$body" \
    "https://api.digitalocean.com/v2/droplets" | python3 -c "import json,sys;print(json.load(sys.stdin)['droplet']['id'])")
  echo "spawned $name id=$id, waiting for IPs..." >&2
  local pub priv tries=0
  while [ $tries -lt 60 ]; do
    read -r pub priv < <(do_api "https://api.digitalocean.com/v2/droplets/$id" | python3 -c "
import json,sys
d=json.load(sys.stdin)['droplet']['networks']['v4']
pub=next((n['ip_address'] for n in d if n['type']=='public'),'')
priv=next((n['ip_address'] for n in d if n['type']=='private'),'')
print(pub,priv)
")
    [ -n "$pub" ] && [ -n "$priv" ] && break
    sleep 5; tries=$((tries+1))
  done
  echo "  pub=$pub priv=$priv" >&2
  echo "waiting for SSH..." >&2
  tries=0
  while ! ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o BatchMode=yes root@$pub 'echo ready' >/dev/null 2>&1; do
    sleep 6; tries=$((tries+1)); [ $tries -lt 40 ] || { echo "SSH timeout for $pub" >&2; return 1; }
  done
  echo "$id $pub $priv"
}

do_delete() { do_api -o /dev/null -w "%{http_code}\n" -X DELETE "https://api.digitalocean.com/v2/droplets/$1"; }

do_list() {
  do_api "https://api.digitalocean.com/v2/droplets?page=1&per_page=100" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for x in d['droplets']:
    pub=next((n['ip_address'] for n in x['networks']['v4'] if n['type']=='public'),'')
    print(f\"{x['id']}  {x['name']:24s} {x['size']['slug']:20s} {pub}\")
"
}
