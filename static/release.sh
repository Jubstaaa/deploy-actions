#!/usr/bin/env bash
# Runs on the host, piped over SSH by the static action.
#   release.sh prepare  <sites-root> <site> <release>
#   release.sh activate <sites-root> <site> <release> <keep>
#   release.sh rollback <sites-root> <site>
#
# Each release lives in <sites-root>/_releases/<site>/<release>; <sites-root>/<site>
# is a relative symlink to the live one, swapped atomically with rename(2), so a
# visitor never sees a half-copied site and the previous release stays one link
# away. Relative links keep resolving inside a container that mounts <sites-root>.
set -euo pipefail

mode="$1"
root="$2"
site="$3"
releases="$root/_releases/$site"
link="$root/$site"

[[ "$site" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::invalid site name"; exit 1; }

current() { [[ -L "$link" ]] && readlink "$link" || true; }

switch_to() {
    ln -sfn "$1" "$link.next"
    mv -Tf "$link.next" "$link"
}

case "$mode" in
prepare)
    release="$4"
    install -d "$releases"
    # First run: the site is still a plain directory. Keep it as the initial
    # release and replace it with a link to itself.
    if [[ -d "$link" && ! -L "$link" ]]; then
        mv "$link" "$releases/initial"
        ln -s "_releases/$site/initial" "$link"
        echo initial >>"$releases/history"
    fi
    rm -rf "${releases:?}/$release"
    # Printed for rsync --link-dest: unchanged files become hard links.
    cur=$(current)
    [[ -n "$cur" ]] && echo "$root/$cur"
    ;;
activate)
    release="$4"
    keep="$5"
    [[ -f "$releases/$release/index.html" ]] || { echo "::error::$release has no index.html"; exit 1; }
    prev=$(current)
    switch_to "_releases/$site/$release"
    printf 'RELEASE=%s\nPREVIOUS=%s\nDEPLOYED_AT=%s\n' \
        "$release" "${prev##*/}" "$(date -u +%FT%TZ)" >"$releases/release.env"
    # history lists releases oldest first. Keep the newest <keep> distinct ones,
    # and never the live or the previous release whatever the count.
    echo "$release" >>"$releases/history"
    tac "$releases/history" | awk '!seen[$0]++' | head -n "$keep" >"$releases/history.keep"
    for dir in "$releases"/*/; do
        name=$(basename "$dir")
        [[ "$name" == "$release" || "$name" == "${prev##*/}" ]] && continue
        grep -qxF "$name" "$releases/history.keep" || rm -rf "${releases:?}/${name:?}"
    done
    tac "$releases/history.keep" >"$releases/history"
    rm -f "$releases/history.keep"
    ;;
rollback)
    previous=$(sed -n 's/^PREVIOUS=//p' "$releases/release.env")
    [[ -n "$previous" && -d "$releases/$previous" ]] || { echo "::error::no previous release to roll back to"; exit 1; }
    switch_to "_releases/$site/$previous"
    echo "::error::rolled back $site to $previous"
    ;;
*)
    echo "unknown mode $mode" >&2
    exit 2
    ;;
esac
