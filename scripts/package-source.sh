#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    printf 'Usage: %s GIT_REVISION OUTPUT.tar.gz\n' "$0" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
revision="$(git -C "$root" rev-parse --verify --end-of-options "$1^{commit}")"
output="$2"
if [[ -e "$output" || -L "$output" ]]; then
    printf 'Output already exists: %s\n' "$output" >&2
    exit 1
fi
mkdir -p "$(dirname "$output")"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

git -C "$root" archive --prefix=AetherUnzip/ "$revision" | tar -xf - -C "$staging"
source_root="$staging/AetherUnzip"
archive_dir="$source_root/third_party/source-archives"
mkdir "$archive_dir"
printf '%s\n' "$revision" > "$source_root/SOURCE-REVISION"

while IFS=$'\t' read -r dependency filename url sha256; do
    case "$dependency" in ''|'#'*) continue ;; esac
    if [[ "$filename" == */* || "$url" != https://* || "${#sha256}" != 64 ]]; then
        printf 'Invalid source pin for %s\n' "$dependency" >&2
        exit 1
    fi
    archive="$archive_dir/$filename"
    curl --fail --silent --show-error --location --retry 2 --max-time 120 \
        --proto '=https' --proto-redir '=https' "$url" --output "$archive"
    actual="$(cmake -E sha256sum "$archive")"
    if [[ "${actual%% *}" != "$sha256" ]]; then
        printf 'SHA-256 mismatch for %s\n' "$filename" >&2
        exit 1
    fi
done < "$source_root/cmake/source-archives.tsv"

COPYFILE_DISABLE=1 tar -czf "$staging/AetherUnzip-source.tar.gz" -C "$staging" AetherUnzip
mv "$staging/AetherUnzip-source.tar.gz" "$output"
cmake -E sha256sum "$output"
