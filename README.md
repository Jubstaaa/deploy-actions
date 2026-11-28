# deploy-actions

Composite GitHub Actions and a reusable quality-gate workflow shared by my apps and static sites on a droplet, so every app is checked and deployed the same way and a fix lands in one place.

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
2. pulls `image:tag` (or `image@image-digest`, see below) and runs `docker compose up --wait` (the service's healthcheck) plus an HTTP check on `health-url`;
3. if the new tag never becomes healthy, starts the previously running tag again (on the pre-release database snapshot, when `sqlite-snapshot` is set) and fails the job;
4. on success writes `release.env` (`IMAGE_TAG`, `PREVIOUS_TAG`, plus `IMAGE_DIGEST`/`PREVIOUS_DIGEST` when known), removes this app's old images, and moves `:latest` to the released tag (or digest).

Image cleanup keeps `keep-images` tags of `image` (default `2`): the live tag and the previous one from `release.env` are always kept, then the newest others up to that count. Older tags and the repository's untagged images are removed with a plain `docker image rm`, so an image a container still uses is left alone; the local `:latest` tag is kept because the compose file falls back to it. Only `image`'s own repository is touched (never a global `docker image prune`), so it is safe on a host shared by several apps. Set `keep-images: 0` to turn it off. A failed cleanup is a warning; the release stays live.

The compose service must use `image: <image>:${IMAGE_TAG:-latest}` and define a `healthcheck`. Private images: pass `registry-user` and `registry-token`; the login happens in a throwaway Docker config on the host, so other apps' stored credentials are never touched.

```yaml
- uses: Jubstaaa/deploy-actions/compose@<sha>
  with:
      app-dir: /opt/myapp
      container: myapp
      image: ghcr.io/me/myapp
      tag: ${{ github.sha }}
      image-digest: ${{ needs.image.outputs.digest }}   # recommended, see below
      health-url: http://127.0.0.1:3000/
      # keep-images: 2       # image tags kept on the host, live + previous included
```

### Deploy by digest

A tag can be re-pushed between the build that tested it and the deploy, so `tag` alone can ship an image nobody tested. Pass the tested image's digest as `image-digest` (`sha256:` + 64 hex characters, e.g. the `digest` output of `docker/build-push-action`, exposed as a job output):

- the host pulls `image@image-digest`, tags it locally as `image:tag` and starts it with `docker compose up --pull never`, so the compose file stays `image: <image>:${IMAGE_TAG:-latest}`;
- after compose reports healthy, the container's image ID must equal the digest's image ID, or the release is refused and rolled back (this also catches a compose file that ignores `IMAGE_TAG` or sets `pull_policy: always`);
- `release.env` records `IMAGE_DIGEST` (and `PREVIOUS_DIGEST`), and an automatic rollback restarts the previous release from its recorded digest rather than whatever its tag points at now;
- `:latest` is moved to the digest.

```yaml
jobs:
    image:
        outputs:
            digest: ${{ steps.build.outputs.digest }}
        steps:
            - id: build
              uses: docker/build-push-action@<sha>
              with:
                  push: true
                  tags: ghcr.io/me/myapp:${{ github.sha }}
    deploy:
        needs: image
        steps:
            - uses: Jubstaaa/deploy-actions/compose@<sha>
              with:
                  # ...
                  tag: ${{ github.sha }}
                  image-digest: ${{ needs.image.outputs.digest }}
```

Without `image-digest`, the action behaves exactly as before.

Point `health-url` at an endpoint that reads the database (e.g. `http://127.0.0.1:3000/api/health`) rather than `/`, so a release whose migration broke its data fails the gate and is rolled back.

Rollback by hand: re-run the deploy with an older commit SHA as `tag` (and its digest as `image-digest`, from that release's `release.env` or build log, to pin it). With the default `keep-images`, only the live and the previous tag stay on the host; an older tag is pulled from the registry again. For an app with SQLite, add `restore-snapshot: true` when that older release cannot run on the current schema (see below).

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

## `quality-gate` (reusable workflow)

The pull-request gate every project runs as its required `check`:

```yaml
jobs: { check: { uses: Jubstaaa/deploy-actions/.github/workflows/quality-gate.yml@<sha> } }
```

The status check it reports is **`check / gate`** (`<caller job> / <called job>`): that is the context to require in the `protect-main` ruleset.

Each step runs the project's own `package.json` script, so the tool's version and configuration stay in the project: `format:check`, `lint`, `typecheck`, `test`, `knip`, `jscpd`, `depcruise`, `build`, anything named in `scripts`, then `audit` last so a new advisory never hides author-fixable feedback. Besides those it runs [`jubstaa-doctor`](https://github.com/Jubstaaa/configs) over the repository (`LICENSE`, `README.md`, `package.json` fields, canonical script names, and no prose comments in YAML), `actionlint` (with shellcheck) over the repository's workflows, a Trivy filesystem scan of the whole repository (vulnerabilities, secrets, misconfiguration; HIGH and CRITICAL that have a fix fail; database cached outside the checkout), and, with `gitleaks: true`, a secret scan of the git history — on a pull request every commit in it, so a secret added and removed again within the branch is still caught.

| Input | Default | |
| --- | --- | --- |
| `runtime` | `bun` | `bun` (`bun install --frozen-lockfile`, `bun run`) or `node` (`npm ci`, `npm run`) |
| `node-version-file` | `''` | Node version for setup-node, relative to the repository root; `<working-directory>/package.json` for `node`. With `bun`, Node is installed only when set |
| `working-directory` | `.` | where `package.json` and the lockfile live |
| `format`, `lint`, `typecheck`, `test`, `audit`, `knip`, `jscpd`, `depcruise`, `build`, `trivy`, `actionlint` | `true` | turn one step off, e.g. `build: false` for a package with nothing to build |
| `trivy-skip-dirs` | installed and built output | comma-separated globs Trivy skips |
| `doctor` | `true` | run `jubstaa-doctor` over the repository: `LICENSE`, `README.md`, `package.json` fields, canonical script names, and no prose comments in YAML |
| `doctor-version` | `^2` | version range of `@jubstaa/config` the doctor comes from |
| `gitleaks` | `false` | scan the git history for committed secrets; also deepens the checkout, since it reads commits rather than the working tree |
| `scripts` | `''` | extra `package.json` script names, one per line, run after the standard ones — for checks only this project has |
| `env` | `''` | extra environment for the script steps, as `KEY=value` lines; placeholders and flags only, never secrets (workflow inputs are recorded in the run log) |

The job has `contents: read` only, checks out without persisting credentials, and uses its own concurrency group (cancelled on a newer push to the same pull request). Turning a step off is for a step that has nothing to check, never for a failing one: fix it or commit a baseline.

## `cloudflare`

The Workers counterpart of `compose`: hand a built project to wrangler.

```yaml
- run: bun install --frozen-lockfile
- run: bun run build
  env:
      NEXT_PUBLIC_API_URL: ${{ secrets.NEXT_PUBLIC_API_URL }}
- run: bun run verify:export
- uses: Jubstaaa/deploy-actions/cloudflare@<sha>
  with:
      api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

| Input | Default | |
| --- | --- | --- |
| `api-token` | — | Workers Scripts: Edit on the account |
| `account-id` | — | the account the Worker belongs to |
| `command` | `deploy` | `deploy` publishes immediately; `versions upload` uploads without serving, for a release promoted later |
| `config` | `''` | a wrangler config file other than the one wrangler finds |
| `runtime` | `bun` | whether wrangler runs through `bunx` or `npx` |
| `working-directory` | `.` | where the wrangler config and `node_modules` are |

It outputs `version`, the id wrangler reported, and writes it to the job summary
with wrangler's output.

**Why an action and not a reusable workflow.** The build has to stay in the
calling repository. A build that reads `NEXT_PUBLIC_API_URL` from a secret can
name it in its own `env:` block, the way the droplet repositories already do; a
shared workflow cannot, because it does not know what the variables are called,
and the only way round that is to pass them as one opaque blob — which puts
every value into `GITHUB_ENV` for every later step and masks none of them
individually. wrangler comes from the project's own dependencies either way.

What is genuinely shared is the upload: the command, the version id, the
summary. That is what this action is.

## `cloudflare-rollback` (reusable workflow)

`wrangler deploy` replaces what is live, so a bad deploy has nothing to fall
back to by itself. Cloudflare keeps the previous versions; this serves one of
them again.

```yaml
on:
    workflow_dispatch:
        inputs:
            version:
                description: 'Version id. Empty rolls back one.'
                type: string
jobs:
    rollback:
        uses: Jubstaaa/deploy-actions/.github/workflows/cloudflare-rollback.yml@<sha>
        with:
            version: ${{ inputs.version }}
        secrets:
            CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
            CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

| Input | Default | |
| --- | --- | --- |
| `version` | `''` | the version id to serve; empty rolls back to the one before the current |
| `message` | `Rolled back from GitHub Actions` | the reason, recorded on the rollback in Cloudflare |
| `runtime`, `working-directory`, `config`, `environment` | as `cloudflare-deploy` | |

It lists the versions before touching anything and writes both that list and
wrangler's output to the job summary, so the state it found is readable
afterwards. It shares `cloudflare-deploy`'s concurrency group, so a rollback and
a deploy cannot run over each other.

The `cloudflare` action reports the version it created in the job summary and as
an output, which is the id to pass when rolling back to something specific
rather than one step back.

This one stays a reusable workflow rather than an action: it is dispatched on
its own, with nothing to build first, so the caller would otherwise be writing
the checkout and install itself for no reason.

### Staging and production from the same artifact

`command: versions upload` on the `cloudflare` action uploads a version without
serving it. A release then promotes that exact version rather than building again, which is what keeps the
two environments honest: production is a staging build that was approved, not a
rebuild that happens to come from the same commit.

## Why some of this looks the way it does

The workflows and actions carry no comments, by the same rule as the code: a
comment cannot be run, so it rots silently. What was worth keeping is here.

- **`compose`, remote commands.** A registry token travels on stdin, never as an
  argument, so it cannot be read out of `ps` on the host. `ssh` joins its
  arguments into one string for the remote shell, so each one is quoted with
  `%q` first and none can inject shell syntax; the database list is joined onto
  one line so `%q` never needs `$'…'` quoting, which a non-bash login shell
  would not parse.
- **`compose`, image cleanup.** It runs after the release is live and healthy,
  so a failure there only warns. `:latest` moves by digest when one is given, so
  a tag re-pushed in the meantime cannot become `:latest`.
- **`static`.** A new release is compared with the live one by content, not
  mtime — every build rewrites mtimes — so unchanged files become hard links
  instead of copies.
- **Releases.** The release pull request is opened with a personal access token
  rather than `GITHUB_TOKEN`: one opened with the built-in token starts no
  workflows, so its required checks would never report and the release would sit
  blocked behind the branch ruleset.
- **`quality-gate`, concurrency.** The gate uses its own group rather than the
  caller's: a called workflow that shares its caller's group waits on, or
  cancels, its own caller.
- **`quality-gate`, Trivy.** `ignore-unfixed` is on because a finding with no
  fixed version would block every pull request with nothing to act on; the
  `audit` step still reports those advisories. The database is cached outside
  the checkout, so it never lands in the scanned tree, and per-pull-request
  caching is off because no other pull request could restore it.

## Development

`shellcheck` and `actionlint` lint every script and workflow; `bats test` runs the host-side scripts against a fake `docker` CLI, real `sqlite3` and a temporary sites root (Linux: the scripts use GNU coreutils). CI runs both on every pull request, and runs `quality-gate` against the minimal bun and npm projects in `test/fixtures/quality-gate/`.

## License

[MIT](LICENSE)
