#!/usr/bin/env bash
# Runs on the host, piped over SSH by the compose action:
#   remote-deploy.sh <app-dir> <service> <container> <image> <tag> <health-url> [registry-user]
# REGISTRY_TOKEN comes from the environment (read from stdin by the caller).
# Deploys <tag> behind compose's health gate, rolls back to the previously running
# tag if it never becomes healthy, and records the release in <app-dir>/release.env
# (prune-images.sh reads it afterwards to know which tags to keep).
set -euo pipefail

app_dir="$1"
service="$2"
container="$3"
image="$4"
new="$5"
health_url="$6"
registry_user="${7:-}"

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

if healthy "$new"; then
    printf 'IMAGE_TAG=%s\nPREVIOUS_TAG=%s\nDEPLOYED_AT=%s\n' \
        "$new" "$prev" "$(date -u +%FT%TZ)" >release.env
    exit 0
fi

echo "::error::$new failed its health check; rolling back to $prev"
IMAGE_TAG="$new" docker compose logs --tail 200 "$service" || true
if healthy "$prev"; then
    echo "::error::rolled back; production is serving $prev"
else
    echo "::error::ROLLBACK TO $prev FAILED; production is likely down"
    IMAGE_TAG="$prev" docker compose logs --tail 200 "$service" || true
fi
exit 1
