# 02 — Worker slices

**Goal:** N nested-KVM workspace VMs on the KVM host, each a full workspace
(supervisord + chat/terminal/files/browser/…), reachable from a remote client.

**Prereqs:** [`01-kvm-host`](01-kvm-host.md) done (the KVM host IP + mngr + the
`docean_cloud` create-template).

## Steps

1. Create each slice (one `mngr create` provisions the VM, installs docker in it,
   builds the workspace image, and starts supervisord — ~5-8 min each; do them
   **sequentially**, RAM is the binding constraint):
   ```bash
   ./scripts/create-slice.sh "$PUB" do-32x-080 4c16g
   ./scripts/create-slice.sh "$PUB" do-32f1-080 2c8g
   # plans: 2c8g, 2c6g, 1c2g (microtest), 4c16g, ...
   ```
   Capture each slice's VM IP from the create JSON (`ssh_host`) + its
   `container_ssh_key` path on the KVM host.

2. Expose the slices to a remote client with per-VM DNAT (a unique public port
   per VM → `VM:2222`, restricted to your IP, persisted across reboot):
   ```bash
   cat > /tmp/ports.txt <<EOF
   23001 192.168.122.174
   23002 192.168.122.160
   EOF
   ./scripts/per-vm-dnat.sh "$PUB" /tmp/ports.txt   # default allow = your IP
   # add more allow-sources as extra args:  ./scripts/per-vm-dnat.sh "$PUB" /tmp/ports.txt 198.51.100.0/24   # example: an extra CIDR to allow
   ```

3. (Optional) Rename a slice in place — `mngr rename --host` on the KVM host
   changes the provider's logical name; for the name to show in the client app,
   also rename **in-container** (`mngr exec … 'MNGR_HOST_DIR=/mngr mngr rename
   --host system-services@<old>.local <new>'`) and set the display label
   (`mngr label … -l workspace_display_name=<new>`).

## Verify

```bash
MNGR_HOST_DIR=/root/.mngr MNGR_PREFIX=minds- ssh root@"$PUB" \
  '/root/mngr/.venv/bin/mngr exec system-services@do-32x-080.docean_cloud "supervisorctl status | grep -c RUNNING"'
# expect: ~16-17
nc -z -w5 "$PUB" 23001   # from the client: the DNAT'd port is open
```

## Gotchas

- **Sequential creates** — a concurrent build spikes CPU + needs the 80G disk
  headroom each; create one at a time, then run concurrently.
- **Per-VM DNAT, not the provider's auto public-face** — the `docean_cloud`
  provider's `public_face_host` DNAT is single-VM (it flushes + re-points to the
  latest VM). For multiple slices on one host use `per-vm-dnat.sh` (manual nft,
  one port per VM, persisted). Fresh DO hosts lack `ip nat PREROUTING` — the
  script creates it with the `dstnat` hook.
- **The from-scratch build fits even on 1c2g** — don't pre-bake unless you want
  faster creates; the dwt Dockerfile build completes in a 2G VM (slow, but works).
- **In-container rename** — `mngr rename --host` on the KVM host only changes the
  provider's logical name; the in-container mngr (what the client app discovers)
  keeps the old name until you rename inside the container too.
