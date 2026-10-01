# setup-docean-studio

Instructions + helper scripts for running **Imbue Studio on your own VPS cloud** —
a linux "webtop" running the open-source Imbue Studio desktop app (reachable from
your browser), driving workspace "slices" that run as nested-KVM VMs on your own
DigitalOcean droplets. No cloud account is needed for compute: the workspaces live
on your own nested-KVM hosts, reached over SSH.

What you end up with: a browser-openable desktop running Imbue Studio, with a set of
workspace slices listed in it that you can click into — each a full workspace
(chat, terminal, files, browser) running on your own VPS.

## Prerequisites

- **A DigitalOcean account + API key** (the one hard dependency).

Everything else is auto-discovered or bundled:
- Your public IP — discovered at run time.
- The DO region + VPC — auto-selected.
- The workspace template tag — defaults to the latest available `minds-v*` tag.
- The `mngr_docean_cloud` libvirt provider — bundled in [`provider/`](provider/).

## The flow

Each step links to a detailed runbook. Steps 1–3 are sequential; **4a and 4b run in
parallel** (wire whichever client you want — the webtop, your local desktop, or
both); 5 is optional per-slice polish.

1. [`01-kvm-host`](runbooks/01-kvm-host.md) — spawn a DO nested-KVM droplet + set up
   libvirt, mngr, the `docean_cloud` provider, and the workspace template.
2. [`02-worker-slices`](runbooks/02-worker-slices.md) — `mngr create` each slice
   (the VM + its docker container + services come up together).
3. [`03-webtop`](runbooks/03-webtop.md) — spawn the desktop droplet + install the
   Imbue Studio app + VNC/webtop (HTTPS, random port, IPv6).
4. **Wire a client to the slices** (parallel):
   - [`04a-wire-webtop`](runbooks/04a-wire-webtop.md) — wire the webtop's app to
     the slices (cross-VPC, same DO VPC).
   - [`04b-wire-desktop`](runbooks/04b-wire-desktop.md) — wire your local
     machine's Imbue Studio app to the slices (per-VM DNAT, restricted to your IP).
5. [`05-production-ux`](runbooks/05-production-ux.md) *(optional, per slice)* —
   latchkey (permission prompts + finish-notifs), sharing (associate your imbue
   cloud account + share), welcome chat.

## What you end up with

A filled [`inventory/`](inventory/) — your droplets, the slice names, the per-VM
DNAT ports, and the webtop's VNC endpoint — so you (or an agent) can reach every
piece without re-deriving it.

## Pointers

- [`scripts/`](scripts/) — helper scripts: `kvm-host-setup.sh`, `create-slice.sh`,
  `per-vm-dnat.sh`, `cross-vpc.sh`, `webtop-setup.sh`, `wire-client.sh` (shared DO
  helpers in `scripts/lib/do.sh`).
- [`provider/`](provider/) — the vendored `mngr_docean_cloud` libvirt provider.
- [`decisions/`](decisions/) — the "why" ledger + parked questions (what we tried
  that didn't work, and why).

## Architecture

Three-level nesting:

```
DigitalOcean droplet (libvirt host, runs mngr + the docean_cloud provider)
└─ nested-KVM VM  (Ubuntu cloud image, on the host's libvirt NAT 192.168.122.0/24)
   └─ docker container  (the workspace image: supervisord + chat/terminal/files/browser/…)
```

The webtop is a separate droplet running the Imbue Studio Electron app under
Xvfb + x11vnc/websockify; it reaches the slices over SSH (cross-VPC if in the same
DO VPC, or per-VM DNAT if remote). Your local desktop can do the same.
