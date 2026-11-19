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
3. if the new tag never becomes healthy, starts the previously running tag again and fails the job;
4. on success writes `release.env`, prunes this app's week-old images, and moves `:latest` to the released tag.

The compose service must use `image: <image>:${IMAGE_TAG:-latest}` and define a `healthcheck`. Private images: pass `registry-user` and `registry-token`; the login happens in a throwaway Docker config on the host, so other apps' stored credentials are never touched.

```yaml
- uses: Jubstaaa/deploy-actions/compose@<sha>
  with:
      app-dir: /opt/myapp
      container: myapp
      image: ghcr.io/me/myapp
      tag: ${{ github.sha }}
      health-url: http://127.0.0.1:3000/
```

Rollback by hand: re-run the deploy with an older commit SHA as `tag`.

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

## License

[MIT](LICENSE)
