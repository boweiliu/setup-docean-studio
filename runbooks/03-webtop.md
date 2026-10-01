# 03 — Webtop

**Goal:** a DigitalOcean droplet running the open-source Imbue Studio desktop app
under Xvfb, with VNC + a noVNC webtop reachable from your browser.

**Prereqs:** `.env` with `DIGITALOCEAN_API_KEY`. No nested KVM needed (this box is
a client).

## Steps

1. Spawn a box (e.g. `s-4vcpu-8gb-amd`):
   ```bash
   source scripts/lib/do.sh
   read -r ID PUB PRIV < <(do_spawn docean-webtop s-4vcpu-8gb-amd)
   ```
2. Provision it (creates a `studio` user, installs Xvfb/x11vnc/websockify/openbox,
   installs the Imbue Studio app from source at the latest `minds-v*` tag, writes a
   random VNC password, sets up systemd units, and restricts the VNC + webtop
   ports to your IP via ufw):
   ```bash
   MY_IP=$(do_my_ip)
   ./scripts/webtop-setup.sh "$PUB" "$MY_IP"
   # prints: VNC <ip>:5900 (password: <random>) + http://<ip>:6080/vnc.html
   ```

## Verify

```bash
curl -s -o /dev/null -w "webtop HTTP %{http_code}\n" "http://$PUB:6080/vnc.html"  # 200, from your IP
nc -z -w5 "$PUB" 5900   # VNC port open from your IP
```
Then open `http://$PUB:6080/vnc.html` in a browser → enter the VNC password → you
should see the Imbue Studio app (the start flow / sign-in).

## Gotchas

- **Electron SUID sandbox** — running the app as a non-root user crashes with
  "chrome-sandbox is not configured correctly". Fix: `chown root:root
  …/electron/dist/chrome-sandbox; chmod 4755 …` (the script does this).
- **`websockify -D` / `x11vnc -bg` daemonize** — systemd `Type=simple` then thinks
  the unit stopped. The script runs x11vnc `-bg` (stays in the cgroup) + `exec
  websockify` in the foreground so systemd tracks it.
- **TODO #1 (hardening, not yet in this script)** — serve over a random IPv6
  (unscannable) + random port + HTTPS self-signed instead of plain-HTTP `:6080`.
  The current script is IP-restricted plain HTTP; the hardened version is a
  follow-up.
- **First launch builds the UI** — `pnpm start` runs `build:ui` on first boot
  (~1-2 min) before the backend comes up; the systemd unit shows active during
  this.
