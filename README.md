# deploy-actions

Composite GitHub Actions shared by my apps and static sites on a droplet, so every app deploys the same way and a fix lands in one place.

## `ssh`

Writes an SSH config entry with a **pinned host key** (`StrictHostKeyChecking yes`): a spoofed host is refused instead of being trusted on first use, and no third-party action handles the private key.

```yaml
- uses: Jubstaaa/deploy-actions/ssh@<sha>
  with:
      host: ${{ secrets.DROPLET_HOST }}
      user: ${{ secrets.DROPLET_USER }}
      key: ${{ secrets.DROPLET_SSH_KEY }}
      known-hosts: ${{ secrets.DROPLET_KNOWN_HOSTS }}
# later steps: ssh droplet …, scp file droplet:…
```

Get the `known-hosts` value from a machine that already trusts the host (`ssh-keygen -F <host>`), not from `ssh-keyscan` in CI.

## `compose`

Health-gated deploy with automatic rollback:

1. uploads the repository's compose file to `app-dir`, so the server never drifts from git;
2. pulls `image:tag` and runs `docker compose up --wait` (the service's healthcheck) plus an HTTP check on `health-url`;
3. if the new tag never becomes healthy, starts the previously running tag again (on the pre-release database snapshot, when `sqlite-snapshot` is set) and fails the job;
4. on success writes `release.env` (`IMAGE_TAG`, `PREVIOUS_TAG`), removes this app's old images, and moves `:latest` to the released tag.

Image cleanup keeps `keep-images` tags of `image` (default `2`): the live tag and the previous one from `release.env` are always kept, then the newest others up to that count. Older tags and the repository's untagged images are removed with a plain `docker image rm`, so an image a container still uses is left alone; the local `:latest` tag is kept because the compose file falls back to it. Only `image`'s own repository is touched (never a global `docker image prune`), so it is safe on a host shared by several apps. Set `keep-images: 0` to turn it off. A failed cleanup is a warning; the release stays live.

The compose service must use `image: <image>:${IMAGE_TAG:-latest}` and define a `healthcheck`. Private images: pass `registry-user` and `registry-token`; the login happens in a throwaway Docker config on the host, so other apps' stored credentials are never touched.

```yaml
- uses: Jubstaaa/deploy-actions/compose@<sha>
  with:
      app-dir: /opt/myapp
      container: myapp
      image: ghcr.io/me/myapp
      tag: ${{ github.sha }}
      health-url: http://127.0.0.1:3000/
      # keep-images: 2       # image tags kept on the host, live + previous included
```

Point `health-url` at an endpoint that reads the database (e.g. `http://127.0.0.1:3000/api/health`) rather than `/`, so a release whose migration broke its data fails the gate and is rolled back.

Rollback by hand: re-run the deploy with an older commit SHA as `tag`. With the default `keep-images`, only the live and the previous tag stay on the host; an older tag is pulled from the registry again. For an app with SQLite, add `restore-snapshot: true` when that older release cannot run on the current schema (see below).

### SQLite snapshots

For apps that keep SQLite databases in `app-dir`, list them in `sqlite-snapshot` (one host path per line) and every release becomes safe to roll back across a migration:

```yaml
- uses: Jubstaaa/deploy-actions/compose@<sha>
  with:
      app-dir: /opt/myapp
      container: myapp
      image: ghcr.io/me/myapp
      tag: ${{ inputs.image_tag || github.sha }}
      health-url: http://127.0.0.1:3000/api/health
      sqlite-snapshot: |
          /opt/myapp/data/myapp.db
      # keep-snapshots: 5    # per database
      restore-snapshot: ${{ inputs.restore_db || false }}   # manual rollback only
```

- **Before the new tag starts**, each database is copied with SQLite's online backup API (`sqlite3 <db> ".backup …"`) while the running release keeps serving, to `<app-dir>/snapshots/<name>-<running tag>-<UTC>.sqlite` (the directory is mode 711, the file keeps the database's owner and mode). The copy must pass `pragma integrity_check`; a missing database, a failed copy or a failed check fails the deploy before anything changes. After a healthy release the newest `keep-snapshots` per database (default 5) are kept; a snapshot that cannot be removed is only a warning.
- **Automatic rollback** (the new tag never turns healthy): every snapshot is checked and copied next to its database first, then the service is stopped, each database is replaced by its copy with an atomic rename, and the previous tag starts on them. The restore is all or nothing: if any database cannot be restored, the ones already swapped are put back and the previous tag starts on the databases as the failed release left them, with an `::error::`. The database the failed release left behind stays next to it as `<db>.failed-<UTC>` (its `-wal`/`-shm`/`-journal` files are moved aside with it, so they cannot be replayed onto the snapshot). Writes the old release made between the snapshot and the switch are lost; the window is the image start-up time.
- **Manual rollback** (`restore-snapshot: true`, `tag` = the release to go back to): the newest snapshot taken while `tag` was running (the state just before the release after it) is restored the same way, after a fresh snapshot of the current database. **Every write made since that snapshot is discarded**; the replaced database is kept as `<db>.failed-<UTC>` for recovering them by hand. It fails before touching anything if `tag` has no snapshot (it is older than `keep-snapshots` releases, or ran before snapshots were enabled) or if `tag` is already running (a re-run of a finished rollback would discard the writes made since). Without `restore-snapshot` a manual rollback starts the older tag on the current database, as before.
- The host needs the `sqlite3` CLI (`apt-get install sqlite3`). It runs on the host rather than in a container because the app images do not ship it, and a helper image would add a registry pull to every deploy. The service named in `service` must be the only writer of the databases, because only it is stopped for a restore.
- The app's container can write to its data directory, so the deploy never works there as root: a database or `-wal`/`-shm`/`-journal` file that is a symlink is refused, and `sqlite3`, the copy and the renames run as the database file's owner (`setpriv`). Run the container as a non-root user: for a root-owned database the online snapshot still runs as root while the container is up.
- Snapshots are a rollback aid, not a backup: they live on the same disk. Keep the off-host backup.

## `static`

Atomic releases for static sites served from a directory (e.g. by Caddy's `file_server`):

1. checks that the build output has a non-empty `index.html`;
2. uploads it to `<sites-root>/_releases/<site>/<release>` with `rsync --checksum --link-dest`, so files unchanged since the live release become hard links;
3. points `<sites-root>/<site>` (a **relative** symlink, so it resolves inside a container that mounts `sites-root`) at the new release with an atomic rename — visitors never see a half-copied site;
4. with `health-url`, checks the live site and switches back to the previous release if it does not answer;
5. keeps the newest `keep` releases (default 5) and records `release.env`.

The first run turns the existing site directory into the `initial` release.

```yaml
- uses: Jubstaaa/deploy-actions/static@<sha>
  with:
      source-dir: out
      site: brief
      health-url: https://brief.example.com/
```

Rollback by hand: re-run the deploy for an older commit, or point the symlink at a kept release.

## Development

`shellcheck` and `actionlint` lint every script and workflow; `bats test` runs the host-side scripts against a fake `docker` CLI, real `sqlite3` and a temporary sites root (Linux: the scripts use GNU coreutils). CI runs both on every pull request.

## License

[MIT](LICENSE)
