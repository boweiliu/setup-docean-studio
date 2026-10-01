# 05 — Production UX (optional, per slice)

**Goal:** the full production workspace experience — latchkey (permission prompts
+ finish-notifs), sharing (associate your imbue cloud account + share), and a
welcome chat. These are skipped by a CLI `mngr create` (the app's create flow does
them); this runbook does them by hand / API.

**Prereqs:** a slice wired into a client ([`04a`](04a-wire-webtop.md) or
[`04b`](04b-wire-desktop.md)) + your imbue cloud account signed in to that client
app. `scripts/wire-client.sh --latchkey --share --welcome` does all of this in one
go; this runbook is the detail.

## Latchkey (permission prompts + finish-notifs)

The CLI create injects no `LATCHKEY_*` env + creates no host permissions file, so
chat permission prompts + finish-notifs fail. Wire it (run on the client):

1. Emit the gateway env + opaque permissions path:
   ```bash
   mngr latchkey create-agent-env --gateway-location DESKTOP \
     --latchkey-directory "$LATCHDIR" --latchkey-binary "$LATCHBIN" > /tmp/lk-env.json
   ```
2. Link the permissions file to the slice's **ssh-provider** host id (the
   `uuid5("bowei-cloud:<name>")`, found in the forward log "Deferring latchkey
   auto-register for agent … on host host-<id>"):
   ```bash
   mngr latchkey link-permissions --host-id "$SSH_HOST_ID" --opaque-path "$OPAQUE" \
     --latchkey-directory "$LATCHDIR" --latchkey-binary "$LATCHBIN"
   ```
3. Inject the env into the slice's `/mngr/env` + restart supervisord (detached):
   ```bash
   mngr exec system-services@<slice>.bowei-cloud '
     grep -v "^LATCHKEY_" /mngr/env > /tmp/e; printf "%s\n" "$ENVJSON" >> /tmp/e; mv /tmp/e /mngr/env
     cd /home/user/workspace; set -a; . /mngr/env; set +a
     nohup setsid supervisord -n -c system/supervisord.conf >/var/log/supervisord.log 2>&1 </dev/null &'
   ```

**Verify:** `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1989/` in the
slice → `401` (the reverse tunnel is up — comes up on-demand when you open the
workspace in the app).

## Sharing (associate your account + share)

1. Associate the slice with your imbue cloud account (no per-workspace UI clicking):
   ```bash
   curl -X PATCH "http://127.0.0.1:$PORT/api/v1/workspaces/$AID" \
     -H "Authorization: Bearer $MINDS_API_KEY" -H "Content-Type: application/json" \
     -d '{"account_id":"you@imbue.com"}'
   ```
2. Share (creates the relay tunnel + brings up caddy + frpc in the slice):
   ```bash
   curl -X PUT "http://127.0.0.1:$PORT/api/v1/machines/$HOST_ID/sharing" \
     -H "Authorization: Bearer $MINDS_API_KEY" -H "Content-Type: application/json" \
     -d '{"workspace":{"emails":["you@imbue.com"]},"services":{}}'
   ```

**Verify:** `GET /api/v1/workspaces/$AID` → `account_email = you@imbue.com`;
`GET /api/v1/machines/$HOST_ID/sharing` → `enabled: true` + a `workspace_domain`.

## Welcome chat

The CLI create seeds no welcome chat (the app's create flow runs
`system/scripts/seed_welcome_chat.py`). Seed one:
```bash
mngr exec system-services@<slice>.bowei-cloud '
  cd /home/user/workspace
  BODY=$(python3 -c "import json,base64; t={\"title\":\"Welcome\",\"turns\":[{\"role\":\"assistant\",\"text\":\"Welcome!\"}]}; print(base64.b64encode(json.dumps(t).encode()).decode())")
  python3 system/scripts/seed_welcome_chat.py --transcript-base64 "$BODY"'
```

## Gotchas

- **`--latchkey-directory` is mandatory** on both latchkey commands (else they
  default to `~/.mngr/latchkey` → the forward never finds the permissions file).
- **`--host-id` is the ssh-provider uuid5**, not the bowei_cloud `host-<hex>`.
- **`mngr latchkey` chokes on the `[providers.bowei_cloud]` block** (unknown
  backend) — run it with a temp `MNGR_HOME` + a minimal `settings.toml`
  (`[plugins.latchkey]\nenabled=true`); it also needs `MINDS_ELECTRON_EXEC_PATH`.
- **Finish-notifs fire only in a new chat** — an existing chat's claude is a
  long-lived tmux process that keeps its stale first-boot env; start a new chat
  after the latchkey wiring.
- **Backups are NOT covered here** — self-hosted backups need an R2 bucket the
  associated account creates (`mngr imbue_cloud bucket create`) + an outer
  snapshot trigger the `bowei_cloud` provider doesn't yet implement. See
  `decisions/` for the parked state.
