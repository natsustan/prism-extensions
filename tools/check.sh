#!/usr/bin/env bash
# Builds, tests, lints, and smoke-tests extensions. CI runs it on the folders a
# change touches; run it locally before opening a pull request.
#
#   bash tools/check.sh extensions/octocat.focus-flag   # one or more folders
#   bash tools/check.sh --changed origin/main            # folders changed since a ref
#   bash tools/check.sh --all                            # everything
#
# Set PRISM_KIT_PATH to a Prism checkout's Packages/PrismExtensionKit to build
# against an unreleased Kit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

all_folders() {
    find extensions examples templates -mindepth 1 -maxdepth 1 -type d | sort
}

folders=()
case "${1:-}" in
    --all)
        while IFS= read -r folder; do folders+=("$folder"); done < <(all_folders)
        ;;
    --changed)
        base="${2:?--changed needs a git ref}"
        changed="$(git diff --name-only "$base"...HEAD)"
        if grep -q '^tools/' <<<"$changed"; then
            # The checks themselves changed: run them everywhere.
            while IFS= read -r folder; do folders+=("$folder"); done < <(all_folders)
        else
            while IFS= read -r folder; do
                [[ -d "$folder" ]] && folders+=("$folder")
            done < <(grep -E '^(extensions|examples|templates)/[^/]+/' <<<"$changed" | cut -d/ -f1-2 | sort -u)
        fi
        ;;
    "")
        echo "Usage: bash tools/check.sh <folder>... | --changed <ref> | --all" >&2
        exit 2
        ;;
    *)
        folders=("$@")
        ;;
esac

if [[ ${#folders[@]} -eq 0 ]]; then
    echo "No extension folders to check."
    exit 0
fi

swift build --package-path tools -c release
tool="$ROOT/tools/.build/release/prism-extension"

for folder in "${folders[@]}"; do
    echo "==> $folder"
    if [[ -f "$folder/Package.swift" ]]; then
        swift build --package-path "$folder" -c release
        if [[ -d "$folder/Tests" ]]; then
            swift test --package-path "$folder"
        fi
    fi
    if [[ -d "$folder/tests" && -x "$folder/tests/run" ]]; then
        "$folder/tests/run"
    fi
    "$tool" lint "$folder"
    "$tool" smoke "$folder"
done
