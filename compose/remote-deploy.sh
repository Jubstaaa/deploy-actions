#!/usr/bin/env bash
# Runs on the host, piped over SSH by the compose action:
#   remote-deploy.sh <app-dir> <service> <container> <image> <tag> <health-url>
#                    [registry-user] [sqlite-dbs] [keep-snapshots] [restore-snapshot]
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

snapshot_dir="$app_dir/snapshots"
stamp_glob='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z'
read -r -d '' -a dbs <<<"$sqlite_dbs" || true

fail() {
    echo "::error::$*"
    exit 1
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
    # immutable: a read-only open of a WAL database would leave empty -wal/-shm files behind.
    [[ "$(sqlite3 "file:$1?immutable=1" 'pragma integrity_check' 2>&1)" == ok ]]
}

snapshot() {
    local db="$1" tag="$2" stamp="$3" snap partial
    snap="$snapshot_dir/$(db_name "$db")-$tag-$stamp.sqlite"
    partial="$snapshot_dir/.$(basename "$snap").partial"
    rm -f "$partial"
    if ! sqlite3 "$db" ".timeout 30000" ".backup '$partial'"; then
        rm -f "$partial"
        fail "could not snapshot $db; the release did not start"
    fi
    if ! integrity_ok "$partial"; then
        rm -f "$partial"
        fail "the snapshot of $db failed its integrity check; the release did not start"
    fi
    if ! { chown --reference="$db" "$partial" && chmod --reference="$db" "$partial" && mv "$partial" "$snap"; }; then
        rm -f "$partial"
        fail "could not store the snapshot of $db"
    fi
    echo "snapshot $snap"
    taken["$db"]="$snap"
}

prune_snapshots() {
    local snap
    snapshots_of "$1" '*' | tail -n +$((keep_snapshots + 1)) | while read -r snap; do
        rm -f "$snap" && echo "removed old snapshot $snap"
    done
}

# Puts <snapshot> in place of <db>, with the service stopped. The database the failed
# release left behind stays next to it as <db>.failed-<stamp>, with its journal files.
# Every step checks its own status: callers run this inside `if`, where `set -e` is off.
restore() {
    local db="$1" snap="$2" stamp="$3" suffix
    integrity_ok "$snap" || { echo "::error::snapshot $snap failed its integrity check"; return 1; }
    cp --preserve=mode,ownership "$snap" "$db.restoring" || return 1
    chown --reference="$db" "$db.restoring" && chmod --reference="$db" "$db.restoring" || return 1
    ln -f "$db" "$db.failed-$stamp" || return 1
    for suffix in -wal -shm -journal; do
        if [[ -e "$db$suffix" ]]; then
            mv -f "$db$suffix" "$db.failed-$stamp$suffix" || return 1
        fi
    done
    mv -f "$db.restoring" "$db" || return 1
    echo "restored $db from $snap (the replaced database is $db.failed-$stamp)"
}

# restore_all <db>=<snapshot>... with the service stopped first.
restore_all() {
    local stamp pair
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    IMAGE_TAG="$new" docker compose stop "$service" || return 1
    for pair in "$@"; do
        restore "${pair%%=*}" "${pair#*=}" "$stamp" || return 1
    done
}

check_snapshot_inputs

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

healthy() {
    IMAGE_TAG="$1" docker compose up -d --wait --wait-timeout 120 "$service" &&
        curl -fsS -o /dev/null --max-time 10 "$health_url"
}

prev=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null | sed 's/.*://') || true
prev=${prev:-latest}
echo "deploying $image:$new (running: $prev)"

wanted=()
if [[ "$restore_snapshot" == true ]]; then
    for db in "${dbs[@]}"; do
        snap=$(snapshots_of "$db" "$new" | sed -n 1p)
        [[ -n "$snap" ]] || fail "no snapshot of $db was taken while $new was running; nothing restored"
        wanted+=("$db=$snap")
    done
fi

# GHCR can take up to a minute after a push before it serves the new manifest,
# answering "not found" meanwhile; wait for it instead of failing the release.
for attempt in 1 2 3 4 5 6; do
    IMAGE_TAG="$new" docker compose pull "$service" && break
    if ((attempt == 6)); then
        echo "::error::the registry never served $image:$new"
        exit 1
    fi
    echo "pull attempt $attempt failed; retrying in 20s"
    sleep 20
done

declare -A taken=()
if ((${#dbs[@]})); then
    [[ -d "$snapshot_dir" ]] || mkdir -m 700 "$snapshot_dir"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    for db in "${dbs[@]}"; do
        snapshot "$db" "$prev" "$stamp"
    done
fi

if ((${#wanted[@]})) && ! restore_all "${wanted[@]}"; then
    echo "::error::could not restore the snapshots of $new; it was not started, restarting $prev"
    healthy "$prev" || echo "::error::$prev did not come back either; production is likely down"
    exit 1
fi

# After the restore, so a short keep-snapshots never removes the snapshot it needs.
for db in "${dbs[@]}"; do
    prune_snapshots "$db"
done

if healthy "$new"; then
    printf 'IMAGE_TAG=%s\nPREVIOUS_TAG=%s\nDEPLOYED_AT=%s\n' \
        "$new" "$prev" "$(date -u +%FT%TZ)" >release.env
    exit 0
fi

echo "::error::$new failed its health check; rolling back to $prev"
IMAGE_TAG="$new" docker compose logs --tail 200 "$service" || true
if ((${#taken[@]})); then
    pairs=()
    for db in "${!taken[@]}"; do
        pairs+=("$db=${taken[$db]}")
    done
    # Starting the previous tag anyway is no worse than before snapshots existed.
    restore_all "${pairs[@]}" ||
        echo "::error::COULD NOT RESTORE THE DATABASE SNAPSHOTS; $prev starts on the database $new left behind"
fi
if healthy "$prev"; then
    echo "::error::rolled back; production is serving $prev"
else
    echo "::error::ROLLBACK TO $prev FAILED; production is likely down"
    IMAGE_TAG="$prev" docker compose logs --tail 200 "$service" || true
fi
exit 1
