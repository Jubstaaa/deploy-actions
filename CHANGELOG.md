# Changelog

All notable changes to these actions. Versions follow [Semantic Versioning](https://semver.org/); consumers pin a release by commit SHA.

## Unreleased

### Added

- `compose`: optional `image-digest` input (`sha256:…`). The release pulls `<image>@<digest>`, tags it locally as `<image>:<tag>`, starts it with `docker compose up --pull never`, and requires the running container's image ID to match the digest's; a mismatch is refused and rolled back like a failed health check. A tag re-pushed between publish and deploy can no longer ship an untested image.
- `compose`: `release.env` records `IMAGE_DIGEST` and `PREVIOUS_DIGEST` when known, and an automatic rollback restarts the previous release from its recorded digest (also for tag-only deploys that follow a digest release).
- `compose`: with `image-digest`, `:latest` is moved to the digest instead of the tag.

Without `image-digest`, behaviour and `release.env` are unchanged.

## 1.5.0 — 2026-11-22

### Added

- `quality-gate`: reusable workflow (`on: workflow_call`) that runs a project's format check, lint, typecheck, test, knip, jscpd, dependency-cruiser, build and audit scripts, plus actionlint and a Trivy filesystem scan, with `runtime` (`bun`/`node`), `node-version-file`, `working-directory` and a toggle per step. CI runs it against bun and npm fixture projects.

## 1.4.0 — 2026-11-20

### Added

- `compose`: `sqlite-snapshot` input. Before each release, every listed SQLite database is copied with SQLite's online backup API to `<app-dir>/snapshots/<name>-<running tag>-<UTC>.sqlite`, keeping the database's owner and mode, and must pass `pragma integrity_check`; a failed snapshot fails the deploy before anything changes.
- `compose`: on automatic rollback, the service is stopped and each database is atomically replaced by this deploy's snapshot before the previous tag starts, all or nothing across databases; the failed release's database (and its `-wal`/`-shm`/`-journal` files) is kept as `<db>.failed-<UTC>`.
- `compose`: `restore-snapshot` input for manual rollbacks: starts `tag` on the newest snapshot taken while `tag` was running (refused when `tag` is already running).
- Work inside the app's data directory runs as the database's owner and refuses symlinked database and journal files, so a compromised container cannot redirect a root write.
- `compose`: `keep-snapshots` input (default 5) for per-database retention.

### Changed

- `compose`: `health-url` documentation recommends a database-touching endpoint such as `/api/health`.

All new inputs are optional and default to the previous behaviour.

## 1.3.0 — 2026-11-19

- `compose`: prune this app's old images after a healthy release (`keep-images`, default 2; never touches other apps' images).
- `static`: first deploy of a new site, re-running the live release, and `keep` validation fixed.

## 1.2.0 — 2026-11-19

- New `static` action: atomic static-site releases with health check and automatic rollback.

## 1.1.0 — 2026-11-19

- `compose`: retry `docker compose pull` up to six times, 20 s apart, while GHCR propagates a new tag.

## 1.0.0 — 2026-11-19

- First release: `ssh` (pinned host key) and `compose` (health-gated deploy with automatic rollback).
