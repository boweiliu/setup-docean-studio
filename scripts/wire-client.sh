#!/usr/bin/env bash
# Wire a client's Imbue Studio app to a set of docean_cloud slices: copy each
# slice's container SSH key + sshd host key, add an ssh-provider host entry per
# slice to the app's settings.toml, then (optionally) latchkey + sharing + welcome.
#
# This is a thin automation of runbooks 04a/04b + 05. The app's web API
# (MINDS_API_KEY) is used for the account association + sharing; latchkey uses
# the app's latchkey dir + binary. Run on the CLIENT machine (the webtop or your
# desktop) where the Imbue Studio app runs.
#
#   wire-client.sh <slice-map-file> [--latchkey] [--share] [--welcome]
#   slice-map-file: lines of "<slice-name> <kvm-host-pub-ip> <dnat-port> <kvm-host-ssh-key-path>"
#     (the <kvm-host-ssh-key-path> is the path ON the KVM host to the slice's
#      container_ssh_key; this script scp's it down to the client.)
#
# Env: MINDS_HOME (app data dir), MINDS_API_KEY (Bearer for /api/v1), LATCHKEY_DIR,
#      LATCHKEY_BIN, MINDS_ELECTRON_EXEC_PATH. Discover with `wire-client.sh --env-hints`.
set -euo pipefail
MAPFILE="${1:?usage: wire-client.sh <slice-map-file> [--latchkey|--share|--welcome]}"
shift || true
DO_LATCHKEY=0; DO_SHARE=0; DO_WELCOME=0
for a in "$@"; do
  case "$a" in --latchkey) DO_LATCHKEY=1;; --share) DO_SHARE=1;; --welcome) DO_WELCOME=1;; esac
done

# --- discover the app's mngr home + profile (0.8.x data dir) ---
MH="${MINDS_HOME:-$HOME/Library/Application Support/Imbue Studio/production}"
[ -d "$MH/mngr" ] || MH="$HOME/.minds"   # 0.7.x fallback
PROF="$(ls "$MH/mngr/profiles" | head -1)"
SET="$MH/mngr/profiles/$PROF/settings.toml"
KEYBASE="$MH/mngr/profiles/$PROF/providers/docean_cloud/docean_cloud/keys/host_keys"
KH="$MH/mngr/profiles/$PROF/providers/docean_cloud/known_hosts_bw_do"
MN="$MH/.venv/bin/mngr"
export MNGR_HOST_DIR="$MH/mngr" MNGR_PREFIX=minds-

echo "==> copying container keys + known_hosts + ssh-provider entries"
mkdir -p "$KEYBASE"; : > "$KH"
grep -vE '^\s*(#|$)' "$MAPFILE" | while IFS=' ' read -r name ip port kpath; do
  [ -z "$name" ] && continue
  hid="$(basename "$(dirname "$kpath")")"
  mkdir -p "$KEYBASE/$hid"
  scp -o StrictHostKeyChecking=no -q "root@$ip:$kpath" "$KEYBASE/$hid/container_ssh_key"
  chmod 600 "$KEYBASE/$hid/container_ssh_key"
  ssh-keyscan -p "$port" -t ed25519 "$ip" 2>/dev/null >> "$KH"
  python3 - "$SET" "$KEYBASE" "$KH" "$name" "$ip" "$port" "$hid" <<'PY'
import sys,pathlib
setf,keybase,kh,name,ip,port,hid=sys.argv[1:8]
p=pathlib.Path(setf); s=p.read_text()
entry=f'''
[providers.docean-cloud.hosts.{name}]
address = "{ip}"
port = {port}
user = "root"
key_file = "{keybase}/{hid}/container_ssh_key"
known_hosts_file = "{kh}"
'''
if f"hosts.{name}]" not in s: p.write_text(s.rstrip()+"\n"+entry)
PY
  echo "  $name -> $ip:$port (key $hid)"
done
echo "==> restart the Imbue Studio app to pick up the new providers"

# --- latchkey (Part D): link permissions + inject env + restart supervisord ---
if [ "$DO_LATCHKEY" = 1 ]; then
  echo "==> latchkey: link permissions + inject env (per slice)"
  LATCHDIR="${LATCHKEY_DIR:-$MH/latchkey}"
  LATCHBIN="${LATCHKEY_BIN:-/Applications/Mind-070.app/Contents/Resources/latchkey/bin/latchkey}"
  export MINDS_ELECTRON_EXEC_PATH="${MINDS_ELECTRON_EXEC_PATH:-/Applications/Mind-070.app/Contents/MacOS/Imbue Studio}"
  TMP=/tmp/mngr-latchkey-tmp; mkdir -p "$TMP"; echo -e '[plugins.latchkey]\nenabled=true' > "$TMP/settings.toml"
  MNGR_HOST_DIR="$TMP" MNGR_PROFILE=_ "$MN" latchkey create-agent-env --gateway-location DESKTOP \
    --latchkey-directory "$LATCHDIR" --latchkey-binary "$LATCHBIN" > /tmp/lk-env.json
  OPAQUE=$(python3 -c "import json;print(json.load(open('/tmp/lk-env.json'))['opaque_permissions_path'])")
  ENVJSON=$(python3 -c "import json;d=json.load(open('/tmp/lk-env.json'))['env'];print('\n'.join(f'{k}={v}' for k,v in d.items()))")
  grep -vE '^\s*(#|$)' "$MAPFILE" | while IFS=' ' read -r name ip port kpath; do
    [ -z "$name" ] && continue
    hid=$(basename "$(dirname "$kpath")")
    # latchkey host id = the ssh-provider uuid5("docean-cloud:<name>"); find it in the forward log
    SSHID=$(grep -oE "agent-[0-9a-f]+ on host host-[0-9a-f]+" "$HOME/Library/Logs/Imbue Studio/production/minds-events.jsonl" 2>/dev/null | head -1 | grep -oE "host-[0-9a-f]+")
    [ -z "$SSHID" ] && { echo "  $name: could not resolve latchkey host id (open the workspace in the app first)"; continue; }
    MNGR_HOST_DIR="$TMP" MNGR_PROFILE=_ "$MN" latchkey link-permissions --host-id "$SSHID" --opaque-path "$OPAQUE" \
      --latchkey-directory "$LATCHDIR" --latchkey-binary "$LATCHBIN" >/dev/null
    "$MN" exec system-services@${name}.docean-cloud "
      grep -v '^LATCHKEY_' /mngr/env > /tmp/e 2>/dev/null || true; printf '%s\n' '$ENVJSON' >> /tmp/e; mv /tmp/e /mngr/env
      cd /home/user/workspace; set -a; . /mngr/env; set +a
      nohup setsid supervisord -n -c system/supervisord.conf >/var/log/supervisord.log 2>&1 </dev/null & sleep 7
      echo running=\$(supervisorctl status 2>/dev/null|grep -c RUNNING)" 2>&1 | grep -E "running=|Error" | head -1
    echo "  $name: latchkey linked + env injected"
  done
fi

# --- sharing (Part E): associate the account + share via the web API ---
if [ "$DO_SHARE" = 1 ]; then
  : "${MINDS_API_KEY:?need MINDS_API_KEY (Bearer for /api/v1; see --env-hints)}"
  : "${SHARE_ACCOUNT:?need SHARE_ACCOUNT email, e.g. you@imbue.com}"
  PORT="${MINDS_PORT:-$(pgrep -f 'bin/minds -v' | head -1 | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -oE -- '--port [0-9]+' | awk '{print $2}')}"
  echo "==> sharing: associate $SHARE_ACCOUNT + share (per slice) on port $PORT"
  "$MN" list --format jsonl 2>/dev/null > /tmp/wc-list.jsonl
  grep -vE '^\s*(#|$)' "$MAPFILE" | while IFS=' ' read -r name ip port kpath; do
    [ -z "$name" ] && continue
    aid=$(python3 -c "
import json
for l in open('/tmp/wc-list.jsonl'):
    d=json.loads(l)
    if d.get('name')=='system-services' and d.get('labels',{}).get('workspace_display_name')=='$name': print(d['id']); break
" 2>/dev/null)
    [ -z "$aid" ] && continue
    curl -s -o /dev/null -X PATCH "http://127.0.0.1:$PORT/api/v1/workspaces/$aid" \
      -H "Authorization: Bearer $MINDS_API_KEY" -H "Content-Type: application/json" \
      -d "{\"account_id\":\"$SHARE_ACCOUNT\"}" -w "associate $name: %{http_code}\n"
    hid=$(grep -oE "host-[0-9a-f]+" "$HOME/Library/Logs/Imbue Studio/production/minds-events.jsonl" 2>/dev/null | head -1)
    curl -s -o /dev/null -X PUT "http://127.0.0.1:$PORT/api/v1/machines/$hid/sharing" \
      -H "Authorization: Bearer $MINDS_API_KEY" -H "Content-Type: application/json" \
      -d "{\"workspace\":{\"emails\":[\"$SHARE_ACCOUNT\"]},\"services\":{}}" -w "share $name: %{http_code}\n"
  done
fi

# --- welcome chat (Part F precursor): seed a welcome chat per slice ---
if [ "$DO_WELCOME" = 1 ]; then
  echo "==> welcome: seed a welcome chat (per slice)"
  grep -vE '^\s*(#|$)' "$MAPFILE" | while IFS=' ' read -r name ip port kpath; do
    [ -z "$name" ] && continue
    "$MN" exec system-services@${name}.docean-cloud "
      cd /home/user/workspace
      BODY=\$(python3 -c \"import json,base64; t={'title':'Welcome to $name','turns':[{'role':'assistant','text':'Welcome! This is the $name workspace on docean_cloud.'}]}; print(base64.b64encode(json.dumps(t).encode()).decode())\")
      python3 system/scripts/seed_welcome_chat.py --transcript-base64 \"\$BODY\" 2>&1 | tail -1
    " 2>&1 | grep -vE "WARNING|isolate" | tail -1
    echo "  $name: welcome chat seeded"
  done
fi
