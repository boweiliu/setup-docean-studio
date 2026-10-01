# 04b — Wire your local desktop to the slices

**Goal:** your local machine's Imbue Studio app lists + connects to the docean_cloud
slices, over the public internet via per-VM DNAT (restricted to your IP).

**Prereqs:** [`02-worker-slices`](02-worker-slices.md) with per-VM DNAT applied
(the public port per slice). Your local Imbue Studio app installed + signed in to
your imbue cloud account (used only for sharing/relays, not compute).

## Steps

1. Build a slice-map file (one line per slice:
   `<name> <kvm-pub-ip> <dnat-port> <kvm-host-key-path>`), then on your local
   machine:
   ```bash
   ./scripts/wire-client.sh slice-map.txt --latchkey --share --welcome
   ```
   This copies each slice's `container_ssh_key` + sshd host key to the app's mngr
   home, adds an `[providers.docean-cloud.hosts.<name>]` entry per slice to the
   app's `settings.toml`, restarts the app, and (with the flags) does latchkey +
   sharing + welcome.
2. Restart the Imbue Studio app so the forward discovers the new providers.

## Verify

```bash
MINDS_HOME="$HOME/Library/Application Support/Imbue Studio/production"   # 0.8.x
MNGR_HOST_DIR="$MINDS_HOME/mngr" MNGR_PREFIX=minds- "$MINDS_HOME/.venv/bin/mngr" list
# expect: each slice listed as docean-cloud RUNNING
nc -z -w5 "$KVM_PUB" 23001   # your DNAT'd port, from your IP
```
Then in the app: click a slice → lands past "loading workspace".

## Gotchas

- **`mngr rename --host` is in-container too** — if you renamed a slice on the
  KVM host, the client app still shows the old name until you rename inside the
  container (`MNGR_HOST_DIR=/mngr mngr rename --host …`). The display label
  (`workspace_display_name`) propagates via the shared host_dir volume, but the
  host column doesn't.
- **The forward intermittently prunes ssh-provider hosts** ("absent from a clean
  discovery snapshot" / "Offline hosts not supported") — the `to_offline_host`
  FIXME; `mngr list` recovers and shows the slices.
- **Latchkey reverse tunnel is on-demand** — `curl 127.0.0.1:1989` in a slice
  returns 401 only after you open the workspace in the app (the forward brings up
  the reverse tunnel on connect).
- **`MINDS_API_KEY`** (for the `--share` web-API calls) is per-`minds run`,
  in-memory; grab it from the running app's env (`LATCHKEY_EXTENSION_MINDS_API_KEY`
  on the Electron process) — it's the Bearer token for `/api/v1`.
- **0.8.x data dir** — `~/Library/Application Support/Imbue Studio/production`
  (macOS); the script auto-detects it (falls back to `~/.minds` on 0.7.x).
