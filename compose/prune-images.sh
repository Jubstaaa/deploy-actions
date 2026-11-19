#!/usr/bin/env bash
# Runs on the host after a healthy release, piped over SSH by the compose action:
#   prune-images.sh <app-dir> <image> <keep>
# Removes old tags of <image> only. The live tag and the rollback target recorded in
# <app-dir>/release.env are always kept, plus the newest other tags up to <keep>.
# Other apps share the host, so nothing outside this repository is touched, and
# nothing is forced: Docker refuses to remove an image a container still uses.
set -euo pipefail

app_dir="$1"
image="$2"
keep="$3"

[[ "$keep" =~ ^[0-9]+$ ]] || { echo "::error::keep-images must be a whole number, got '$keep'"; exit 1; }
if ((keep == 0)); then
    echo "image pruning is off (keep-images: 0)"
    exit 0
fi

live=$(sed -n 's/^IMAGE_TAG=//p' "$app_dir/release.env" 2>/dev/null || true)
previous=$(sed -n 's/^PREVIOUS_TAG=//p' "$app_dir/release.env" 2>/dev/null || true)
if [[ -z "$live" ]]; then
    echo "::warning::$app_dir/release.env names no live tag; not pruning"
    exit 0
fi

declare -A kept=(["$live"]=1)
[[ -n "$previous" ]] && kept["$previous"]=1
removed=0

remove() {
    if docker image rm "$1" >/dev/null; then
        echo "removed $1"
        removed=$((removed + 1))
    else
        echo "::warning::could not remove $1; it stays on disk"
    fi
}

# Newest first, so the tags kept beyond the live and previous ones are the most recent.
while IFS=$'\t' read -r _ tag id; do
    if [[ "$tag" == "<none>" ]]; then
        remove "$id"
    elif [[ "$tag" == latest || -n "${kept[$tag]:-}" ]]; then
        # The compose file falls back to :latest when IMAGE_TAG is unset.
        continue
    elif ((${#kept[@]} < keep)); then
        kept["$tag"]=1
    else
        remove "$image:$tag"
    fi
done < <(docker image ls "$image" --format '{{.CreatedAt}}\t{{.Tag}}\t{{.ID}}' | sort -r)

echo "kept ${!kept[*]}; removed $removed old image(s) of $image"
