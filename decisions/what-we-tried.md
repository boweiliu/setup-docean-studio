# What we tried that didn't work (and why)

A ledger of the dead-ends, so they don't get re-walked.

## Desktop-app launch-mode patch (to *create* on bowei_cloud) — NOT USED

We wrote a patch to the Imbue Studio desktop app (`primitives.py` `LaunchMode`
enum + `agent_creator.py` match-cases) so the app could *create* workspaces on
`bowei_cloud` directly. **Not used** — the app's create command for bowei_cloud
stacked only `--template main` (no `bowei_cloud` overlay) → bare debian → 503,
and the clean path turned out to be: **CLI `mngr create`** provisions the slice,
and the app **connects** to it via the built-in `ssh` provider (no app patching, no
plugin on the client). Kept the Mac/webtop app pristine.

## Pre-bake / registry path — NOT NEEDED

The runbook's "pre-bake" path (build the workspace image once, push to a
registry, set `default_image` + a `bowei_cloud_prebuilt` template so the realizer
pulls instead of building) was scoped for 2c8g boxes that "can't run the
from-scratch build". **Turned out unnecessary** — the dwt Dockerfile build
completes even in a 1c2g VM (slow, heavy swap, but it finishes). So no registry,
no pre-bake; every size can from-scratch build. (A one-line note in
`02-worker-slices.md` if you want faster creates.)

## Single-VM `bowei_pubface` DNAT — SUPERSEDED

The `bowei_cloud` provider's `public_face_host` DNAT is single-VM: it flushes +
re-points the `bowei_pubface` chain to the latest-provisioned VM. With multiple
slices on one host that fights (last VM wins). **Superseded by per-VM DNAT**
(`scripts/per-vm-dnat.sh`): a unique public port per VM, `nft add` (not flush),
persisted via a systemd oneshot. Multi-source allow (your IP + extra CIDRs) is
supported.

## `REMOTE_SERVICE_CONNECTOR_URL` — RED HERRING

An earlier session injected `REMOTE_SERVICE_CONNECTOR_URL` thinking it was the
finish-notification path. A comparison to a working imbue_cloud workspace showed
imbue_cloud has **no such env at runtime** (only the web-claim flow writes it).
Finish-notifs use `LATCHKEY_GATEWAY`, not the connector URL. Reverted.

## 0.7.4-specific gotchas — now resolved at 0.8.x

- The 0.7.4→0.8.0 data-dir migration (`~/.minds` → `~/Library/Application Support/
  Imbue Studio/production` on macOS) that broke absolute `key_file` paths — the
  scripts now auto-detect the data dir.
- The bare-debian 503 "loading workspace" root cause — now just "add the
  `[create_templates.bowei_cloud]` block" (the setup script does it).
