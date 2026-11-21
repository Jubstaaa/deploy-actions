#!/usr/bin/env bats
# The compose action's host-side scripts, run against a fake docker CLI.

setup() {
    export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
    export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
    : >"$FAKE_LOG"
    app_dir="$BATS_TEST_TMPDIR/app"
    mkdir -p "$app_dir"
    image=ghcr.io/me/app
    export FAKE_STATE="$BATS_TEST_TMPDIR/docker-state" FAKE_IMAGE="$image"
    mkdir -p "$FAKE_STATE"
    new_digest=sha256:$(printf 'a%.0s' {1..64})
    old_digest=sha256:$(printf 'b%.0s' {1..64})
}

deploy() {
    run bash "$BATS_TEST_DIRNAME/../compose/remote-deploy.sh" \
        "$app_dir" app app "$image" "$1" http://127.0.0.1:3000/
}

# deploy_digest <tag> <digest>: the digest-pinned release.
deploy_digest() {
    run bash "$BATS_TEST_DIRNAME/../compose/remote-deploy.sh" \
        "$app_dir" app app "$image" "$1" http://127.0.0.1:3000/ '' '' 5 false "$2"
}

running_id() {
    cat "$FAKE_STATE/running"
}

prune() {
    run bash "$BATS_TEST_DIRNAME/../compose/prune-images.sh" "$app_dir" "$image" "$1"
}

release() {
    printf 'IMAGE_TAG=%s\nPREVIOUS_TAG=%s\nDEPLOYED_AT=x\n' "$1" "$2" >"$app_dir/release.env"
}

# Rows as `docker image ls --format` prints them: created, tag, id.
images() {
    FAKE_IMAGES=$(printf '%s\\n' "$@")
    export FAKE_IMAGES
}

@test "a healthy deploy records the new and the previous tag" {
    export FAKE_RUNNING="$image:old"
    deploy new
    [ "$status" -eq 0 ]
    grep -qx 'IMAGE_TAG=new' "$app_dir/release.env"
    grep -qx 'PREVIOUS_TAG=old' "$app_dir/release.env"
}

@test "an unhealthy deploy rolls back to the running tag and fails" {
    export FAKE_RUNNING="$image:old" FAKE_UNHEALTHY=new
    deploy new
    [ "$status" -eq 1 ]
    [[ "$output" == *"rolling back to old"* ]]
    [ ! -e "$app_dir/release.env" ]
}

@test "a digest deploy pulls and runs exactly that digest and records it" {
    export FAKE_RUNNING="$image:old"
    deploy_digest new "$new_digest"
    [ "$status" -eq 0 ]
    grep -qx "docker pull $image@$new_digest" "$FAKE_LOG"
    grep -qx "docker tag $image@$new_digest $image:new" "$FAKE_LOG"
    grep -q '^docker compose up .*--pull never' "$FAKE_LOG"
    ! grep -q '^docker compose pull' "$FAKE_LOG"
    [ "$(running_id)" = "img-${new_digest#sha256:}" ]
    grep -qx 'IMAGE_TAG=new' "$app_dir/release.env"
    grep -qx "IMAGE_DIGEST=$new_digest" "$app_dir/release.env"
}

@test "a container that does not run the pinned digest is refused and rolled back" {
    export FAKE_RUNNING="$image:old" FAKE_UP_ID=img-repushed
    deploy_digest new "$new_digest"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not $image@$new_digest"* ]]
    [[ "$output" == *"rolling back to old"* ]]
    [ ! -e "$app_dir/release.env" ]
}

@test "a malformed digest is refused before anything is pulled" {
    export FAKE_RUNNING="$image:old"
    deploy_digest new sha256:nothex
    [ "$status" -ne 0 ]
    ! grep -q 'pull\|compose up' "$FAKE_LOG"
}

@test "rollback restarts the previous release from its recorded digest" {
    export FAKE_RUNNING="$image:old" FAKE_UNHEALTHY=new
    printf 'IMAGE_TAG=old\nIMAGE_DIGEST=%s\nPREVIOUS_TAG=older\nDEPLOYED_AT=x\n' "$old_digest" >"$app_dir/release.env"
    echo img-tampered >"$FAKE_STATE/tag-${image//[\/:]/_}_old"
    deploy_digest new "$new_digest"
    [ "$status" -eq 1 ]
    [[ "$output" == *"rolled back; production is serving old"* ]]
    grep -qx "docker tag $image@$old_digest $image:old" "$FAKE_LOG"
    [ "$(running_id)" = "img-${old_digest#sha256:}" ]
}

@test "a tag-only deploy also rolls back to the recorded digest" {
    export FAKE_RUNNING="$image:old" FAKE_UNHEALTHY=new
    printf 'IMAGE_TAG=old\nIMAGE_DIGEST=%s\nDEPLOYED_AT=x\n' "$old_digest" >"$app_dir/release.env"
    deploy new
    [ "$status" -eq 1 ]
    grep -qx "docker tag $image@$old_digest $image:old" "$FAKE_LOG"
    [ "$(running_id)" = "img-${old_digest#sha256:}" ]
}

@test "a recorded digest of another tag is not used for the rollback" {
    export FAKE_RUNNING="$image:old" FAKE_UNHEALTHY=new
    printf 'IMAGE_TAG=other\nIMAGE_DIGEST=%s\nDEPLOYED_AT=x\n' "$old_digest" >"$app_dir/release.env"
    deploy_digest new "$new_digest"
    [ "$status" -eq 1 ]
    ! grep -q "$old_digest" "$FAKE_LOG"
}

@test "a digest release records the previous release's digest" {
    export FAKE_RUNNING="$image:old"
    printf 'IMAGE_TAG=old\nIMAGE_DIGEST=%s\nDEPLOYED_AT=x\n' "$old_digest" >"$app_dir/release.env"
    deploy_digest new "$new_digest"
    [ "$status" -eq 0 ]
    grep -qx 'PREVIOUS_TAG=old' "$app_dir/release.env"
    grep -qx "PREVIOUS_DIGEST=$old_digest" "$app_dir/release.env"
}

@test "a tag-only deploy keeps the tag path: compose pull, no pinning, no digest record" {
    export FAKE_RUNNING="$image:old"
    deploy new
    [ "$status" -eq 0 ]
    grep -qx 'docker compose pull app' "$FAKE_LOG"
    ! grep -q '^docker pull\|^docker tag\|--pull never' "$FAKE_LOG"
    [ "$(cut -d= -f1 "$app_dir/release.env" | tr '\n' ' ')" = 'IMAGE_TAG PREVIOUS_TAG DEPLOYED_AT ' ]
}

@test "the deploy itself removes no images" {
    export FAKE_RUNNING="$image:old"
    deploy new
    ! grep -q 'image prune\|image rm' "$FAKE_LOG"
}

@test "prune keeps the live and the previous tag and removes older ones" {
    release c b
    images '2026-11-19 03:00:00 +0000 UTC\tc\tid-c' \
        '2026-11-19 02:00:00 +0000 UTC\tb\tid-b' \
        '2026-11-19 01:00:00 +0000 UTC\ta\tid-a' \
        '2026-11-18 01:00:00 +0000 UTC\tz\tid-z'
    prune 2
    [ "$status" -eq 0 ]
    grep -qx "docker image rm $image:a" "$FAKE_LOG"
    grep -qx "docker image rm $image:z" "$FAKE_LOG"
    ! grep -q "image rm $image:[bc]$" "$FAKE_LOG"
}

@test "prune keeps the rollback target even when it is the oldest image" {
    release c a
    images '2026-11-19 03:00:00 +0000 UTC\tc\tid-c' \
        '2026-11-19 02:00:00 +0000 UTC\tb\tid-b' \
        '2026-11-19 01:00:00 +0000 UTC\ta\tid-a'
    prune 2
    grep -qx "docker image rm $image:b" "$FAKE_LOG"
    ! grep -q "image rm $image:a$" "$FAKE_LOG"
}

@test "a larger keep also keeps the newest other tags" {
    release d c
    images '2026-11-19 04:00:00 +0000 UTC\td\tid-d' \
        '2026-11-19 03:00:00 +0000 UTC\tc\tid-c' \
        '2026-11-19 02:00:00 +0000 UTC\tb\tid-b' \
        '2026-11-19 01:00:00 +0000 UTC\ta\tid-a'
    prune 3
    grep -qx "docker image rm $image:a" "$FAKE_LOG"
    ! grep -q "image rm $image:b$" "$FAKE_LOG"
}

@test "prune leaves the latest tag alone and removes untagged images by id" {
    release c b
    images '2026-11-19 03:00:00 +0000 UTC\tc\tid-c' \
        '2026-11-19 02:00:00 +0000 UTC\tb\tid-b' \
        '2026-11-01 00:00:00 +0000 UTC\tlatest\tid-l' \
        '2026-10-01 00:00:00 +0000 UTC\t<none>\tid-n'
    prune 2
    ! grep -q "image rm $image:latest" "$FAKE_LOG"
    grep -qx "docker image rm id-n" "$FAKE_LOG"
}

@test "prune only lists and removes this app's repository" {
    release c b
    images '2026-11-19 03:00:00 +0000 UTC\tc\tid-c'
    prune 2
    grep -q "^docker image ls $image " "$FAKE_LOG"
    ! grep -q 'image prune\|system prune' "$FAKE_LOG"
    ! grep -v "^docker image ls $image " "$FAKE_LOG" | grep -qv "^docker image rm "
}

@test "an image docker refuses to remove is a warning, not a failure" {
    release c b
    images '2026-11-19 03:00:00 +0000 UTC\tc\tid-c' \
        '2026-11-19 01:00:00 +0000 UTC\ta\tid-a'
    export FAKE_RM_FAIL="$image:a"
    prune 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
}

@test "keep 0 turns pruning off" {
    release c b
    images '2026-11-19 01:00:00 +0000 UTC\ta\tid-a'
    prune 0
    [ "$status" -eq 0 ]
    ! grep -q 'image rm' "$FAKE_LOG"
}

@test "a non-numeric keep is refused" {
    release c b
    prune two
    [ "$status" -ne 0 ]
    ! grep -q 'image rm' "$FAKE_LOG"
}

@test "without a release record nothing is pruned" {
    images '2026-11-19 01:00:00 +0000 UTC\ta\tid-a'
    prune 2
    [ "$status" -eq 0 ]
    ! grep -q 'image rm' "$FAKE_LOG"
}
