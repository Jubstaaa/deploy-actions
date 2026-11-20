# Changelog

All notable changes to these actions. Versions follow [Semantic Versioning](https://semver.org/); consumers pin a release by commit SHA.

## 1.4.0 — 2026-11-20

### Added

- `compose`: `sqlite-snapshot` input. Before each release, every listed SQLite database is copied with SQLite's online backup API to `<app-dir>/snapshots/<name>-<running tag>-<UTC>.sqlite`, keeping the database's owner and mode, and must pass `pragma integrity_check`; a failed snapshot fails the deploy before anything changes.
- `compose`: on automatic rollback, the service is stopped and each database is atomically replaced by this deploy's snapshot before the previous tag starts; the failed release's database (and its `-wal`/`-shm`/`-journal` files) is kept as `<db>.failed-<UTC>`.
- `compose`: `restore-snapshot` input for manual rollbacks: starts `tag` on the newest snapshot taken while `tag` was running.
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
