# 04a — Wire the webtop to the slices

**Goal:** the webtop's Imbue Studio app lists + connects to the docean_cloud
slices, over the DO private network (no DNAT needed — the webtop is in the same
VPC as the KVM host).

**Prereqs:** [`02-worker-slices`](02-worker-slices.md) (the slices exist) +
[`03-webtop`](03-webtop.md) (the webtop is up). Both droplets in the same DO VPC
(the default — `do_spawn` puts them in the default-<region> VPC).

## Steps

1. Add a cross-VPC route on the webtop so it can reach the KVM host's libvirt NAT
   (`192.168.122.0/24`) via the KVM host's private IP, + nft accept/return on the
   KVM host's MAIN chains:
   ```bash
   ./scripts/cross-vpc.sh "$WEBTOP_PUB" "$KVM_PUB"
   ```
2. Wire the webtop's app to the slices (copies each slice's `container_ssh_key` +
   sshd host key to the webtop, adds an ssh-provider host entry per slice, restarts
   the app). Build a slice-map file (one line per slice:
   `<name> <kvm-pub-ip> <vm-ip> <kvm-host-key-path>`) and run, on the webtop:
   ```bash
   ./scripts/wire-client.sh slice-map.txt --latchkey --share --welcome
   ```
   (`--latchkey/--share/--welcome` are optional — see [`05-production-ux`](05-production-ux.md).)

## Verify

```bash
# on the webtop:
MNGR_HOST_DIR=~/.minds/mngr MNGR_PREFIX=minds- ~/.mngr/.venv/bin/mngr list
# expect: system-services  WAITING  <slice>  docean-cloud  RUNNING  for each slice
nc -z -w5 192.168.122.160 2222   # the webtop can reach a slice's container sshd
```
Then in the webtop's app (over VNC): click a slice → it lands past "loading
workspace".

## Gotchas

- **Cross-VPC route is runtime-only** — a DHCP/networkd renewal can flush it; re-run
  `cross-vpc.sh`. (Persist via netplan for production.)
- **nft in the MAIN chains, not libvirt's `LIBVIRT_*`** — libvirt reorders its own
  sub-chains on VM create/start, which can push custom rules below its
  `reject`/`masquerade`. `cross-vpc.sh` INSERTs into the MAIN `FORWARD` +
  `POSTROUTING` chains (above the `jump LIBVIRT_*`).
- **The webtop reaches slices at their private `192.168.122.x`** — no DNAT needed
  for the webtop (it's in the VPC). DNAT (runbook 04b) is only for a *remote*
  client.
