#!/usr/bin/env bats
# static/release.sh against a temporary sites root.

setup() {
    root="$BATS_TEST_TMPDIR/sites"
    mkdir -p "$root"
    script="$BATS_TEST_DIRNAME/../static/release.sh"
}

publish() {
    bash "$script" prepare "$root" site "$1" >/dev/null
    mkdir -p "$root/_releases/site/$1"
    echo "$1" >"$root/_releases/site/$1/index.html"
    bash "$script" activate "$root" site "$1" "${2:-5}"
}

@test "the first run keeps the existing directory as the initial release" {
    mkdir -p "$root/site"
    echo old >"$root/site/index.html"
    publish r1
    [ "$(readlink "$root/site")" = "_releases/site/r1" ]
    [ "$(cat "$root/_releases/site/initial/index.html")" = old ]
    grep -qx 'PREVIOUS=initial' "$root/_releases/site/release.env"
}

@test "rollback switches back to the previous release" {
    publish r1
    publish r2
    bash "$script" rollback "$root" site || true
    [ "$(cat "$root/site/index.html")" = r1 ]
}

@test "only the newest releases are kept, never the live or the previous one" {
    for r in r1 r2 r3 r4; do publish "$r" 2; done
    [ -d "$root/_releases/site/r4" ]
    [ -d "$root/_releases/site/r3" ]
    [ ! -d "$root/_releases/site/r1" ]
}

@test "preparing the live release again does not take the site down" {
    publish r1
    run bash "$script" prepare "$root" site r1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$root/site/index.html")" = r1 ]
}

@test "a non-numeric keep is refused before the live link moves" {
    publish r1
    bash "$script" prepare "$root" site r2 >/dev/null
    mkdir -p "$root/_releases/site/r2"
    echo r2 >"$root/_releases/site/r2/index.html"
    run bash "$script" activate "$root" site r2 five
    [ "$status" -ne 0 ]
    [ "$(cat "$root/site/index.html")" = r1 ]
}
