#!/usr/bin/env bats
# The compose action's SQLite snapshots: taken before every release, restored on an
# automatic rollback and, when asked, on a manual one. Real sqlite3, fake docker.

setup() {
    export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
    export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
    : >"$FAKE_LOG"
    app_dir="$BATS_TEST_TMPDIR/app"
    mkdir -p "$app_dir/data"
    db="$app_dir/data/main.db"
    snaps="$app_dir/snapshots"
    image=ghcr.io/me/app
    export FAKE_RUNNING="$image:old"
    make_db "$db" v1
}

# deploy <tag> [dbs] [keep] [restore]
deploy() {
    run bash "$BATS_TEST_DIRNAME/../compose/remote-deploy.sh" \
        "$app_dir" app app "$image" "$1" http://127.0.0.1:3000/ '' \
        "${2-$db}" "${3:-5}" "${4:-false}"
}

make_db() {
    rm -f "$1"
    sqlite3 "$1" "create table t(v text); insert into t values ('$2');"
}

value() {
    sqlite3 -readonly "$1" 'select v from t'
}

# The release under test rewrites the database when it starts, like a migration.
migrating_release() {
    export FAKE_ON_UP="[ \"\$IMAGE_TAG\" = $1 ] && sqlite3 '$db' \"update t set v = 'migrated'\"; echo \"up \$IMAGE_TAG sees \$(sqlite3 -readonly '$db' 'select v from t')\" >>'$FAKE_LOG'"
}

only_snapshot() {
    local found=("$snaps"/$1)
    [ "${#found[@]}" -eq 1 ] && [ -f "${found[0]}" ] || return 1
    echo "${found[0]}"
}

@test "a release snapshots the database under the previous tag before it starts" {
    migrating_release new
    deploy new
    [ "$status" -eq 0 ]
    snap=$(only_snapshot 'main-old-*.sqlite')
    [ "$(value "$snap")" = v1 ]
    [ "$(sqlite3 -readonly "$snap" 'pragma integrity_check')" = ok ]
    [ "$(value "$db")" = migrated ]
}

@test "the snapshot name carries a UTC timestamp" {
    deploy new
    snap=$(only_snapshot 'main-old-*.sqlite')
    [[ "$(basename "$snap")" =~ ^main-old-[0-9]{8}T[0-9]{6}Z\.sqlite$ ]]
}

@test "the snapshot keeps the database's permissions" {
    chmod 640 "$db"
    deploy new
    snap=$(only_snapshot 'main-old-*.sqlite')
    [ "$(stat -c '%a %u:%g' "$snap")" = "$(stat -c '%a %u:%g' "$db")" ]
}

@test "every listed database is snapshotted" {
    other="$app_dir/data/other.db"
    make_db "$other" o1
    deploy new "$db
$other"
    [ "$status" -eq 0 ]
    only_snapshot 'main-old-*.sqlite'
    [ "$(value "$(only_snapshot 'other-old-*.sqlite')")" = o1 ]
}

@test "a database that cannot be copied aborts the release before it starts" {
    echo 'not a database' >"$db"
    deploy new
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"*"snapshot"* ]]
    ! grep -q 'compose up' "$FAKE_LOG"
    ! ls "$snaps"/*.sqlite 2>/dev/null
}

@test "a snapshot that fails its integrity check aborts the release" {
    sqlite3 "$db" "with recursive n(i) as (select 1 union all select i+1 from n where i<2000)
        insert into t select hex(randomblob(50)) from n;"
    printf '%0400d' 0 | dd of="$db" bs=1 seek=$((4096 * 3 + 200)) conv=notrunc 2>/dev/null
    deploy new
    [ "$status" -ne 0 ]
    [[ "$output" == *"integrity"* ]]
    ! grep -q 'compose up' "$FAKE_LOG"
    ! ls "$snaps"/*.sqlite 2>/dev/null
}

@test "a missing database aborts the release" {
    deploy new "$app_dir/data/typo.db"
    [ "$status" -ne 0 ]
    ! grep -q 'compose up' "$FAKE_LOG"
}

@test "a database outside the app directory is refused before anything runs" {
    outside="$BATS_TEST_TMPDIR/elsewhere.db"
    make_db "$outside" x
    deploy new "$outside"
    [ "$status" -ne 0 ]
    [ ! -s "$FAKE_LOG" ]
}

@test "keep-snapshots must be a positive whole number" {
    deploy new "$db" 0
    [ "$status" -ne 0 ]
    deploy new "$db" five
    [ "$status" -ne 0 ]
    ! grep -q 'compose' "$FAKE_LOG"
}

@test "only the newest keep-snapshots snapshots of each database are kept" {
    mkdir -p "$snaps"
    for day in 01 02 03 04 05 06; do
        cp "$db" "$snaps/main-t$day-202611${day}T000000Z.sqlite"
    done
    cp "$db" "$snaps/other-x-20261001T000000Z.sqlite"
    deploy new "$db" 5
    [ "$status" -eq 0 ]
    [ "$(ls "$snaps"/main-*.sqlite | wc -l)" -eq 5 ]
    [ ! -e "$snaps/main-t01-20261101T000000Z.sqlite" ]
    [ ! -e "$snaps/main-t02-20261102T000000Z.sqlite" ]
    [ -e "$snaps/main-t06-20261106T000000Z.sqlite" ]
    only_snapshot 'main-old-*.sqlite'
    [ -e "$snaps/other-x-20261001T000000Z.sqlite" ]
}

@test "an unhealthy release gets the snapshot back before the previous tag starts" {
    migrating_release new
    export FAKE_UNHEALTHY=new
    deploy new
    [ "$status" -eq 1 ]
    grep -qx 'up old sees v1' "$FAKE_LOG"
    [ "$(value "$db")" = v1 ]
    failed=("$db".failed-*)
    [ "${#failed[@]}" -eq 1 ]
    [ "$(value "${failed[0]}")" = migrated ]
}

@test "the rollback stops the failed release before restoring" {
    export FAKE_UNHEALTHY=new
    deploy new
    stop=$(grep -n 'compose stop app' "$FAKE_LOG" | cut -d: -f1)
    ups=($(grep -n 'compose up' "$FAKE_LOG" | cut -d: -f1))
    [ -n "$stop" ] && [ "${ups[0]}" -lt "$stop" ] && [ "$stop" -lt "${ups[1]}" ]
}

@test "the rollback sets the failed release's journal files aside too" {
    export FAKE_UNHEALTHY=new
    export FAKE_ON_UP="[ \"\$IMAGE_TAG\" = new ] && echo stale >'$db-wal' && echo stale >'$db-shm'; true"
    deploy new
    [ ! -e "$db-wal" ] && [ ! -e "$db-shm" ]
    ls "$db".failed-*-wal "$db".failed-*-shm
    [ "$(value "$db")" = v1 ]
}

@test "a healthy release restores nothing" {
    migrating_release new
    deploy new
    [ "$(value "$db")" = migrated ]
    ! ls "$db".failed-* 2>/dev/null
    ! grep -q 'compose stop' "$FAKE_LOG"
}

@test "restore-snapshot starts the tag on its newest snapshot" {
    export FAKE_RUNNING="$image:bad"
    make_db "$db" broken
    mkdir -p "$snaps"
    make_db "$snaps/main-good-20261101T000000Z.sqlite" older
    make_db "$snaps/main-good-20261102T000000Z.sqlite" v1
    make_db "$snaps/main-good-extra-20261103T000000Z.sqlite" wrong-tag
    migrating_release none
    deploy good "$db" 5 true
    [ "$status" -eq 0 ]
    grep -qx 'up good sees v1' "$FAKE_LOG"
    [ "$(value "$(only_snapshot 'main-bad-*.sqlite')")" = broken ]
    failed=("$db".failed-*)
    [ "$(value "${failed[0]}")" = broken ]
}

@test "restore-snapshot without a snapshot of that tag fails before touching anything" {
    export FAKE_RUNNING="$image:bad"
    deploy good "$db" 5 true
    [ "$status" -ne 0 ]
    [[ "$output" == *"no snapshot"* ]]
    ! grep -q 'compose up\|compose stop' "$FAKE_LOG"
    [ "$(value "$db")" = v1 ]
}

@test "without sqlite-snapshot nothing is snapshotted or restored" {
    export FAKE_UNHEALTHY=new
    deploy new ''
    [ "$status" -eq 1 ]
    [ ! -e "$snaps" ]
    ! grep -q 'compose stop' "$FAKE_LOG"
}

@test "restore-snapshot still finds its snapshot when keep-snapshots is 1" {
    export FAKE_RUNNING="$image:bad"
    mkdir -p "$snaps"
    make_db "$snaps/main-good-20261101T000000Z.sqlite" good-data
    migrating_release none
    deploy good "$db" 1 true
    [ "$status" -eq 0 ]
    grep -qx 'up good sees good-data' "$FAKE_LOG"
    [ "$(ls "$snaps"/main-*.sqlite | wc -l)" -eq 1 ]
}

@test "restore-snapshot without sqlite-snapshot is refused" {
    deploy good '' 5 true
    [ "$status" -ne 0 ]
    [ ! -s "$FAKE_LOG" ]
}

@test "an app directory given with a trailing slash still accepts its databases" {
    app_dir="$app_dir/"
    deploy new
    [ "$status" -eq 0 ]
    only_snapshot 'main-old-*.sqlite'
}

@test "a manual restore that cannot complete restarts the running tag and fails" {
    export FAKE_RUNNING="$image:bad"
    mkdir -p "$snaps"
    echo 'not a database' >"$snaps/main-good-20261101T000000Z.sqlite"
    migrating_release none
    deploy good "$db" 5 true
    [ "$status" -ne 0 ]
    grep -qx 'up bad sees v1' "$FAKE_LOG"
    ! grep -q 'up good' "$FAKE_LOG"
}

@test "a database in WAL mode leaves exactly one file per snapshot" {
    sqlite3 "$db" 'pragma journal_mode=wal' >/dev/null
    deploy new
    [ "$status" -eq 0 ]
    [ "$(ls -A "$snaps")" = "$(basename "$(only_snapshot 'main-old-*.sqlite')")" ]
}
