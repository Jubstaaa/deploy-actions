#!/usr/bin/env bash
# Runs on the host, piped over SSH by the compose action:
#   remote-deploy.sh <app-dir> <service> <container> <image> <tag> <health-url>
#                    [registry-user] [sqlite-dbs] [keep-snapshots] [restore-snapshot]
#                    [image-digest]
# REGISTRY_TOKEN comes from the environment (read from stdin by the caller).
# Deploys <tag> behind compose's health gate, rolls back to the previously running
# tag if it never becomes healthy, and records the release in <app-dir>/release.env
# (prune-images.sh reads it afterwards to know which tags to keep).
#
# With sqlite-dbs (whitespace-separated paths inside <app-dir>), each database is
# copied with SQLite's online backup API to <app-dir>/snapshots/<name>-<running
# tag>-<UTC>.sqlite before the new tag starts, and a rollback puts that copy back
# before the previous tag starts again. restore-snapshot=true (a manual rollback)
# also starts <tag> on the newest snapshot taken while <tag> was running.
#
# With image-digest (sha256:...), <image>@<digest> is pulled and tagged locally as
# <image>:<tag>, compose starts it without pulling, and the running container must
# have that image's ID, or the release is rolled back. A tag re-pushed after the
# image was tested therefore cannot ship. The digest is recorded in release.env,
# and a rollback restarts the previous release from its recorded digest.
set -euo pipefail

app_dir="${1%/}"
service="$2"
container="$3"
image="$4"
new="$5"
health_url="$6"
registry_user="${7:-}"
sqlite_dbs="${8:-}"
keep_snapshots="${9:-5}"
restore_snapshot="${10:-false}"
new_digest="${11:-}"

snapshot_dir="$app_dir/snapshots"
stamp_glob='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z'
read -r -d '' -a dbs <<<"$sqlite_dbs" || true

fail() {
    echo "::error::$*"
    exit 1
}

# The app's container can write to the directory that holds its database, so a
# compromised container can plant symlinks there. Every file operation in that
# directory therefore runs as the database's owner (never as root, unless the
# database is root's), and the database and its companions must not be symlinks.
as_owner_of() {
    local file="$1" uid gid
    shift
    read -r uid gid < <(stat -c '%u %g' -- "$file") || return 1
    if [[ "$uid" == "$(id -u)" && "$gid" == "$(id -g)" ]]; then
        "$@"
    else
        setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$@"
    fi
}

no_symlinks() {
    local db="$1" path
    for path in "$db" "$db-wal" "$db-shm" "$db-journal"; do
        if [[ -L "$path" ]]; then
            echo "::error::$path is a symlink; refusing to touch $db"
            return 1
        fi
    done
}

db_name() {
    local base
    base=$(basename "$1")
    echo "${base%.*}"
}

check_snapshot_inputs() {
    [[ "$keep_snapshots" =~ ^[1-9][0-9]*$ ]] || fail "keep-snapshots must be a whole number of at least 1, got '$keep_snapshots'"
    [[ "$restore_snapshot" == true || "$restore_snapshot" == false ]] || fail "restore-snapshot must be true or false"
    if ((${#dbs[@]} == 0)); then
        [[ "$restore_snapshot" == false ]] || fail "restore-snapshot needs sqlite-snapshot"
        return 0
    fi
    command -v sqlite3 >/dev/null || fail "sqlite-snapshot needs the sqlite3 CLI on the host (apt-get install sqlite3)"
    local db name other
    declare -A names=()
    for db in "${dbs[@]}"; do
        # The path ends up inside a quoted sqlite3 dot-command, so only plain characters pass.
        [[ "$db" =~ ^/[A-Za-z0-9._/-]+$ && "$db" != *..* && "$db" == "$app_dir"/* ]] ||
            fail "sqlite-snapshot path '$db' must be an absolute path inside $app_dir"
        no_symlinks "$db" || exit 1
        [[ -f "$db" ]] || fail "sqlite-snapshot database $db does not exist"
        name=$(db_name "$db")
        for other in "${!names[@]}"; do
            # Snapshots of all databases share one directory and are matched by name prefix.
            [[ "$name" == "$other" || "$name" == "$other"-* || "$other" == "$name"-* ]] &&
                fail "sqlite-snapshot databases '$db' and '${names[$other]}' would share snapshot names"
        done
        names["$name"]="$db"
    done
}

# Prints the snapshots of <db> taken while a tag matching <tag-glob> was running,
# newest first by the UTC stamp at the end of the name.
snapshots_of() {
    [[ -d "$snapshot_dir" ]] || return 0
    find "$snapshot_dir" -maxdepth 1 -type f -name "$(db_name "$1")-$2-$stamp_glob.sqlite" |
        while read -r snap; do echo "${snap: -23:16} $snap"; done | sort -r | cut -d' ' -f2-
}

integrity_ok() {
    local result
    # immutable: a read-only open of a WAL database would leave empty -wal/-shm files behind.
    result=$(sqlite3 "file:$1?immutable=1" 'pragma integrity_check' 2>&1) || true
    [[ "$result" == ok ]] && return 0
    echo "::error::integrity check of $1: ${result:0:500}"
    return 1
}

snapshot() {
    local db="$1" tag="$2" stamp="$3" snap work
    snap="$snapshot_dir/$(db_name "$db")-$tag-$stamp.sqlite"
    no_symlinks "$db" || fail "could not snapshot $db; the release did not start"
    # sqlite3 runs as the database's owner and writes into a private directory of ours.
    work=$(mktemp -d "$snapshot_dir/.partial.XXXXXX") || fail "could not create a snapshot work directory"
    if ! { chown "$(stat -c '%u:%g' -- "$db")" "$work" &&
        as_owner_of "$db" sqlite3 "$db" ".timeout 30000" ".backup '$work/snapshot'"; }; then
        rm -rf "$work"
        fail "could not snapshot $db; the release did not start"
    fi
    if ! integrity_ok "$work/snapshot"; then
        rm -rf "$work"
        fail "the snapshot of $db failed its integrity check; the release did not start"
    fi
    if ! { chmod "$(stat -c '%a' -- "$db")" "$work/snapshot" && mv "$work/snapshot" "$snap" && rmdir "$work"; }; then
        rm -rf "$work"
        fail "could not store the snapshot of $db"
    fi
    echo "snapshot $snap"
    taken["$db"]="$snap"
}

# Retention never fails a release: a snapshot that cannot be removed is a warning.
prune_snapshots() {
    local list snap
    list=$(snapshots_of "$1" '*') || { echo "::warning::could not list the snapshots of $1"; return 0; }
    while read -r snap; do
        [[ -n "$snap" ]] || continue
        if rm -f -- "$snap"; then
            echo "removed old snapshot $snap"
        else
            echo "::warning::could not remove old snapshot $snap"
        fi
    done < <(tail -n +$((keep_snapshots + 1)) <<<"$list")
}

# Restoring is all or nothing across the databases, and every step checks its own
# status: callers run these inside `if`, where `set -e` is off.

# Copies <snapshot> next to <db> as a temporary file, ready to be renamed into place,
# and names it in $prepared (not on stdout, which carries the ::error:: annotations).
prepare_restore() {
    local db="$1" snap="$2" mode temp
    no_symlinks "$db" || return 1
    integrity_ok "$snap" || return 1
    mode=$(stat -c '%a' -- "$db") || return 1
    temp=$(as_owner_of "$db" mktemp "$db.restoring.XXXXXX") || { echo "::error::could not create a temporary file next to $db"; return 1; }
    if ! { as_owner_of "$db" cp -- "$snap" "$temp" && as_owner_of "$db" chmod "$mode" "$temp"; }; then
        echo "::error::could not copy $snap next to $db"
        rm -f -- "$temp"
        return 1
    fi
    prepared="$temp"
}

# Renames the prepared copy over <db>, keeping the replaced database and its journal
# files as <db>.failed-<stamp>; the journal files must not be replayed onto the copy.
swap_in() {
    local db="$1" temp="$2" stamp="$3" suffix
    as_owner_of "$db" ln -- "$db" "$db.failed-$stamp" || { echo "::error::could not keep $db aside"; return 1; }
    for suffix in -wal -shm -journal; do
        if [[ -e "$db$suffix" ]]; then
            as_owner_of "$db" mv -- "$db$suffix" "$db.failed-$stamp$suffix" ||
                { echo "::error::could not move $db$suffix aside"; return 1; }
        fi
    done
    as_owner_of "$db" mv -f -- "$temp" "$db" || { echo "::error::could not rename the snapshot over $db"; return 1; }
    echo "restored $db (the replaced database is $db.failed-$stamp)"
}

# Puts back what swap_in set aside, for a restore that failed partway.
swap_back() {
    local db="$1" stamp="$2" suffix
    [[ -e "$db.failed-$stamp" ]] || return 0
    for suffix in -wal -shm -journal; do
        if [[ -e "$db.failed-$stamp$suffix" ]]; then
            as_owner_of "$db" mv -f -- "$db.failed-$stamp$suffix" "$db$suffix" || return 1
        fi
    done
    as_owner_of "$db" mv -f -- "$db.failed-$stamp" "$db" || return 1
}

# restore_all <db>=<snapshot>...: copies every snapshot first, then stops the service
# and swaps them all in. On failure nothing stays changed, or it says loudly what did.
restore_all() {
    local stamp pair db i prepared
    local -a pending=() swapped=()
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    for pair in "$@"; do
        db="${pair%%=*}"
        if ! prepare_restore "$db" "${pair#*=}"; then
            echo "::error::$db cannot be restored; no database was changed"
            for i in "${pending[@]}"; do rm -f -- "${i#*=}"; done
            return 1
        fi
        pending+=("$db=$prepared")
    done
    if ! IMAGE_TAG="$new" docker compose stop "$service"; then
        for i in "${pending[@]}"; do rm -f -- "${i#*=}"; done
        return 1
    fi
    for pair in "${pending[@]}"; do
        db="${pair%%=*}"
        swapped+=("$db")
        swap_in "$db" "${pair#*=}" "$stamp" && continue
        for i in "${pending[@]}"; do rm -f -- "${i#*=}"; done
        for db in "${swapped[@]}"; do
            swap_back "$db" "$stamp" ||
                echo "::error::COULD NOT PUT $db BACK; its pre-restore copy is $db.failed-$stamp"
        done
        echo "::error::the restore failed; the databases were put back as they were"
        return 1
    done
}

check_snapshot_inputs
[[ -z "$new_digest" || "$new_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "image-digest must be sha256:<64 hex characters>, got '$new_digest'"

# A throwaway Docker config: other apps' deploys leave expired registry tokens in
# the shared ~/.docker/config.json, and a registry rejects a pull that presents one.
DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
if [[ -n "$registry_user" ]]; then
    printf '%s' "${REGISTRY_TOKEN:?registry-user is set but the token is empty}" |
        docker login "${image%%/*}" -u "$registry_user" --password-stdin >/dev/null
fi

cd "$app_dir"

# Prints the digest release.env records for <tag>, if any.
recorded_digest() {
    [[ -f release.env ]] || return 0
    local key value tag="" previous=""
    while IFS='=' read -r key value; do
        case "$key" in
        IMAGE_TAG) [[ "$value" == "$1" ]] && tag=1 ;;
        PREVIOUS_TAG) [[ "$value" == "$1" ]] && previous=1 ;;
        IMAGE_DIGEST) [[ -n "$tag" ]] && echo "$value" && return 0 ;;
        PREVIOUS_DIGEST) [[ -n "$previous" ]] && echo "$value" && return 0 ;;
        esac
    done <release.env
    return 0
}

# Points the local <image>:<tag> at <image>@<digest>, pulling it if it is not here.
pin() {
    local tag="$1" digest="$2"
    docker image inspect "$image@$digest" >/dev/null 2>&1 || docker pull "$image@$digest" || return 1
    docker tag "$image@$digest" "$image:$tag"
}

runs_digest() {
    local digest="$1" want got
    want=$(docker image inspect --format '{{.Id}}' "$image@$digest") || return 1
    got=$(docker inspect --format '{{.Image}}' "$container") || return 1
    [[ -n "$want" && "$got" == "$want" ]] && return 0
    echo "::error::$container runs image $got, not $image@$digest ($want); refusing it"
    return 1
}

# healthy <tag> [digest]: with a digest, compose must start exactly that image.
healthy() {
    local tag="$1" digest="${2:-}"
    if [[ -z "$digest" ]]; then
        IMAGE_TAG="$tag" docker compose up -d --wait --wait-timeout 120 "$service" &&
            curl -fsS -o /dev/null --max-time 10 "$health_url"
        return
    fi
    pin "$tag" "$digest" &&
        IMAGE_TAG="$tag" docker compose up -d --wait --wait-timeout 120 --pull never "$service" &&
        runs_digest "$digest" &&
        curl -fsS -o /dev/null --max-time 10 "$health_url"
}

prev=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null | sed 's/.*://') || true
prev=${prev:-latest}
prev_digest=$(recorded_digest "$prev")
[[ -z "$prev_digest" || "$prev_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "release.env records a malformed digest '$prev_digest' for $prev"
echo "deploying $image:$new${new_digest:+@$new_digest} (running: $prev${prev_digest:+@$prev_digest})"
if ((${#dbs[@]})) && [[ ! "$prev" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "cannot name snapshots after the running tag '$prev'; deploy by tag first"
fi

wanted=()
if [[ "$restore_snapshot" == true ]]; then
    # A re-run of a finished manual rollback would discard every write made since.
    [[ "$prev" != "$new" ]] || fail "$new is already running; refusing to restore its snapshot again"
    for db in "${dbs[@]}"; do
        snap=$(snapshots_of "$db" "$new" | sed -n 1p) || fail "could not list the snapshots of $db"
        [[ -n "$snap" ]] || fail "no snapshot of $db was taken while $new was running; nothing restored"
        wanted+=("$db=$snap")
    done
fi

# GHCR can take up to a minute after a push before it serves the new manifest,
# answering "not found" meanwhile; wait for it instead of failing the release.
pull_new() {
    if [[ -n "$new_digest" ]]; then
        docker pull "$image@$new_digest"
    else
        IMAGE_TAG="$new" docker compose pull "$service"
    fi
}
for attempt in 1 2 3 4 5 6; do
    pull_new && break
    if ((attempt == 6)); then
        echo "::error::the registry never served $image:$new${new_digest:+@$new_digest}"
        exit 1
    fi
    echo "pull attempt $attempt failed; retrying in 20s"
    sleep 20
done

declare -A taken=()
if ((${#dbs[@]})); then
    [[ -L "$snapshot_dir" ]] && fail "$snapshot_dir is a symlink"
    [[ -d "$snapshot_dir" ]] || mkdir "$snapshot_dir" || fail "could not create $snapshot_dir"
    # Not listable, but traversable by the databases' owners, who write and read the snapshots.
    chmod 711 "$snapshot_dir"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    for db in "${dbs[@]}"; do
        snapshot "$db" "$prev" "$stamp"
    done
fi

if ((${#wanted[@]})) && ! restore_all "${wanted[@]}"; then
    echo "::error::could not restore the snapshots of $new; it was not started, restarting $prev"
    healthy "$prev" "$prev_digest" || echo "::error::$prev did not come back either; production is likely down"
    exit 1
fi

if healthy "$new" "$new_digest"; then
    {
        echo "IMAGE_TAG=$new"
        [[ -z "$new_digest" ]] || echo "IMAGE_DIGEST=$new_digest"
        echo "PREVIOUS_TAG=$prev"
        [[ -z "$prev_digest" ]] || echo "PREVIOUS_DIGEST=$prev_digest"
        echo "DEPLOYED_AT=$(date -u +%FT%TZ)"
    } >release.env
    # Only once the release is live, so a short keep-snapshots never removes a snapshot
    # a restore still needs and retention can never take the service down.
    for db in "${dbs[@]}"; do
        prune_snapshots "$db"
    done
    exit 0
fi

echo "::error::$new failed its health check; rolling back to $prev"
IMAGE_TAG="$new" docker compose logs --tail 200 "$service" || true
if ((${#taken[@]})); then
    pairs=()
    for db in "${!taken[@]}"; do
        pairs+=("$db=${taken[$db]}")
    done
    # restore_all leaves the databases as they were when it fails, so starting the
    # previous tag anyway is no worse than before snapshots existed.
    restore_all "${pairs[@]}" ||
        echo "::error::COULD NOT RESTORE THE DATABASE SNAPSHOTS; $prev starts on the databases $new left behind"
fi
if healthy "$prev" "$prev_digest"; then
    echo "::error::rolled back; production is serving $prev"
else
    echo "::error::ROLLBACK TO $prev FAILED; production is likely down"
    IMAGE_TAG="$prev" docker compose logs --tail 200 "$service" || true
fi
exit 1
