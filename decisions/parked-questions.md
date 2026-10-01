# Parked questions

Open items pulled out of the run so they don't block the rest. Pick up later.

## Q1 — R2 / backups on the imbue cloud account

Self-hosted (docean_cloud) backups need an **R2 bucket the associated account
creates** (`mngr imbue_cloud bucket create`). The backup configure
(`POST /api/v1/workspaces/<id>/backup-service/configure {IMBUE_CLOUD}`) returns
202 but the async op **fails at `imbue-cloud-bucket-create` (exit 1)** — and the
create error isn't logged (only the cleanup "Bucket not found").

Reference: an imbue_cloud-**managed** workspace has `backup-check = OK` (imbue
cloud manages its backups as part of the lease; no per-user R2 bucket needed).

**Question:** is R2 backup storage enabled / quota'd on the account? If it's an
account-tier thing, that's the blocker for self-hosted backups regardless of any
docean_cloud provider work. (Alt: dig the actual bucket-create error out another
way — the app's imbue_cloud CLI has the connector URL; a bare CLI invocation
doesn't.)

## Q2 — destroy + redo the test-bench slice, or hold it?

The test-bench slice has the welcome recipe demonstrated + backups blocked at Q1 +
the outer-snapshot-trigger provider work (below).

**Question:** destroy + redo it now with the welcome recipe (backups pending Q1 +
the outer-snapshot-trigger provider work), or hold it as the test bench until
backups are figured out?

## Related (context, not a question)

- The **outer snapshot trigger** (the docean_cloud VM/libvirt creating snapshots
  in `/mngr-snapshots/current`) is docean_cloud provider work that overlaps with
  mirroring imbue_cloud. `host-backup` detects `method=OUTER_TRIGGER` but no
  snapshots fire. Paused.
