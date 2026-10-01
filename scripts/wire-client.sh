#!/usr/bin/env bash
# Wire a client's Imbue Studio app to a set of docean_cloud slices: copy each
# slice's container SSH key + sshd host key, add an ssh-provider host entry per
# slice to the app's settings.toml, then (optionally) latchkey + sharing + welcome.
#
# Works on macOS (your desktop) AND Linux (the webtop) — paths auto-detected.
# Run on the CLIENT machine where the Imbue Studio app runs.
#
#   wire-client.sh <slice-map-file> [--latchkey] [--share] [--welcome]
#   wire-client.sh --env-hints        # print the env vars it uses + exit
#
#   slice-map-file: lines of "<slice-name> <kvm-host-pub-ip> <dnat-port> <kvm-host-ssh-key-path>"
#     (the <kvm-host-ssh-key-path> is the path ON the KVM host to the slice's
#      container_ssh_key; this script scp's it down to the client.)
set -euo pipefail

# --- platform-aware defaults (macOS vs Linux) ---
case "$(uname)" in
  Darwin)
    MH_DEFAULT="$HOME/Library/Application Support/Imbue Studio/production"
    LOG_DEFAULT="$HOME/Library/Logs/Imbue Studio/production/minds-events.jsonl"
    LATCHBIN_DEFAULT="/Applications/Mind-070.app/Contents/Resources/latchkey/bin/latchkey"
    ELECTRON_DEFAULT="/Applications/Mind-070.app/Contents/MacOS/Imbue Studio" ;;
  Linux)
    MH_DEFAULT="$HOME/.minds"
    LOG_DEFAULT="$HOME/.minds/logs/minds-events.jsonl"
    LATCHBIN_DEFAULT="$HOME/mngr/apps/minds/node_modules/.bin/latchkey"
    ELECTRON_DEFAULT="$HOME/mngr/apps/minds/node_modules/.bin/electron" ;;
  *) echo "unsupported platform: $(uname)" >&2; exit 2 ;;
esac

MH="${MINDS_HOME:-$MH_DEFAULT}"
[ -d "$MH/mngr" ] || MH="$HOME/.minds"   # fallback (0.7.x / other Linux layouts)
LOG="${MINDS_LOG:-$LOG_DEFAULT}"
PROF="$(ls "$MH/mngr/profiles" | head -1)"
SET="$MH/mngr/profiles/$PROF/settings.toml"
KEYBASE="$MH/mngr/profiles/$PROF/providers/docean_cloud/docean_cloud/keys/host_keys"
KH="$MH/mngr/profiles/$PROF/providers/docean_cloud/known_hosts_docean"
MN="$MH/.venv/bin/mngr"
LATCHDIR="${LATCHKEY_DIR:-$MH/latchkey}"
LATCHBIN="${LATCHKEY_BIN:-$LATCHBIN_DEFAULT}"
export MNGR_HOST_DIR="$MH/mngr" MNGR_PREFIX=minds-
export MINDS_ELECTRON_EXEC_PATH="${MINDS_ELECTRON_EXEC_PATH:-$ELECTRON_DEFAULT}"

# --- --env-hints: print the env vars + exit ---
if [ "${1:-}" = "--env-hints" ]; then
  cat <<EOF
wire-client.sh env vars (override as needed; defaults shown):
  MINDS_HOME=$MH
  MINDS_LOG=$LOG
  LATCHKEY_DIR=$LATCHDIR
  LATCHKEY_BIN=$LATCHBIN
  MINDS_ELECTRON_EXEC_PATH=$MINDS_ELECTRON_EXEC_PATH
  MINDS_API_KEY=<Bearer for /api/v1; grab from the running app's env:
                 LATCHKEY_EXTENSION_MINDS_API_KEY on the Electron process>
  MINDS_PORT=<the 'minds run --port'; auto-detected if unset>
  SHARE_ACCOUNT=<your imbue cloud email, required for --share>
EOF
  exit 0
fi

MAPFILE="${1:?usage: wire-client.sh <slice-map-file> [--latchkey|--share|--welcome] (or --env-hints)}"
shift || true
DO_LATCHKEY=0; DO_SHARE=0; DO_WELCOME=0
for a in "$@"; do
  case "$a" in --latchkey) DO_LATCHKEY=1;; --share) DO_SHARE=1;; --welcome) DO_WELCOME=1;; esac
done

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

# Build a name -> (agent_id, host_id) map from the app's own discovery (robust;
# no forward-log grepping). host_id here IS the latchkey ssh-provider host id.
# Cached once; agent_host_id reads the cache.
"$MN" list --format jsonl 2>/dev/null > /tmp/wc-list.jsonl || true
agent_host_id() {  # $1 = slice name -> prints "aid hid"
  python3 -c "
import json,sys
want=sys.argv[1]
for l in open('/tmp/wc-list.jsonl'):
    try:
        d=json.loads(l)
        if d.get('name')=='system-services' and d.get('labels',{}).get('workspace_display_name')==want:
            print(d['id'], d['host']['id'] if isinstance(d.get('host'),dict) else d.get('host_id','')); raise SystemExit(0)
    except: pass
" "$1"
}

# --- latchkey (Part D): link permissions + inject env + restart supervisord ---
if [ "$DO_LATCHKEY" = 1 ]; then
  echo "==> latchkey: link permissions + inject env (per slice)"
  TMP=/tmp/mngr-latchkey-tmp; mkdir -p "$TMP"; echo -e '[plugins.latchkey]\nenabled=true' > "$TMP/settings.toml"
  MNGR_HOST_DIR="$TMP" MNGR_PROFILE=_ "$MN" latchkey create-agent-env --gateway-location DESKTOP \
    --latchkey-directory "$LATCHDIR" --latchkey-binary "$LATCHBIN" > /tmp/lk-env.json
  OPAQUE=$(python3 -c "import json;print(json.load(open('/tmp/lk-env.json'))['opaque_permissions_path'])")
  ENVJSON=$(python3 -c "import json;d=json.load(open('/tmp/lk-env.json'))['env'];print('\n'.join(f'{k}={v}' for k,v in d.items()))")
  grep -vE '^\s*(#|$)' "$MAPFILE" | while IFS=' ' read -r name ip port kpath; do
    [ -z "$name" ] && continue
    read -r aid hid < <(agent_host_id "$name")
    [ -z "$hid" ] && { echo "  $name: open it in the app first so discovery returns a host id"; continue; }
    MNGR_HOST_DIR="$TMP" MNGR_PROFILE=_ "$MN" latchkey link-permissions --host-id "$hid" --opaque-path "$OPAQUE" \
      --latchkey-directory "$LATCHDIR" --latchkey-binary "$LATCHBIN" >/dev/null
    "$MN" exec system-services@${name}.docean-cloud "
      grep -v '^LATCHKEY_' /mngr/env > /tmp/e 2>/dev/null || true; printf '%s\n' '$ENVJSON' >> /tmp/e; mv /tmp/e /mngr/env
      cd /home/user/workspace; set -a; . /mngr/env; set +a
      nohup setsid supervisord -n -c system/supervisord.conf >/var/log/supervisord.log 2>&1 </dev/null & sleep 7
      echo running=\$(supervisorctl status 2>/dev/null|grep -c RUNNING)" 2>&1 | grep -E "running=|Error" | head -1
    echo "  $name: latchkey linked + env injected (host $hid)"
  done
fi

# --- sharing (Part E): associate the account + share via the web API ---
if [ "$DO_SHARE" = 1 ]; then
  : "${MINDS_API_KEY:?need MINDS_API_KEY (Bearer for /api/v1; see --env-hints)}"
  : "${SHARE_ACCOUNT:?need SHARE_ACCOUNT email, e.g. you@imbue.com}"
  PORT="${MINDS_PORT:-$(pgrep -f 'bin/minds -v' | head -1 | xargs -I{} ps -o command= -p {} 2>/dev/null | grep -oE -- '--port [0-9]+' | awk '{print $2}')}"
  echo "==> sharing: associate $SHARE_ACCOUNT + share (per slice) on port $PORT"
  grep -vE '^\s*(#|$)' "$MAPFILE" | while IFS=' ' read -r name ip port kpath; do
    [ -z "$name" ] && continue
    read -r aid hid < <(agent_host_id "$name")
    [ -z "$aid" ] && { echo "  $name: not discovered yet (open the app)"; continue; }
    curl -s -o /dev/null -X PATCH "http://127.0.0.1:$PORT/api/v1/workspaces/$aid" \
      -H "Authorization: Bearer $MINDS_API_KEY" -H "Content-Type: application/json" \
      -d "{\"account_id\":\"$SHARE_ACCOUNT\"}" -w "  associate $name: %{http_code}\n"
    curl -s -o /dev/null -X PUT "http://127.0.0.1:$PORT/api/v1/machines/$hid/sharing" \
      -H "Authorization: Bearer $MINDS_API_KEY" -H "Content-Type: application/json" \
      -d "{\"workspace\":{\"emails\":[\"$SHARE_ACCOUNT\"]},\"services\":{}}" -w "  share $name: %{http_code}\n"
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
