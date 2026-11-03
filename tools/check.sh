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
        run_tool_tests=1
        while IFS= read -r folder; do folders+=("$folder"); done < <(all_folders)
        ;;
    --changed)
        base="${2:?--changed needs a git ref}"
        changed="$(git diff --name-only "$base"...HEAD)"
        if grep -q '^tools/' <<<"$changed"; then
            # The checks themselves changed: test them and run them everywhere.
            run_tool_tests=1
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

# Swift Build compiles string catalogs into .lproj folders. The native build
# system, the default with CI's Xcode, copies them as is, and the extension
# would show only English.
build_system=(--build-system swiftbuild)

# Builds a Swift extension where its manifest looks for it. Swift Build before
# Swift 6.4 leaves the product in .build/out without a .build/release link.
build_extension() {
    swift build --package-path "$1" -c release "${build_system[@]}"
    if [[ ! -e "$1/.build/release" ]]; then
        ln -s "$(swift build --package-path "$1" -c release "${build_system[@]}" --show-bin-path)" "$1/.build/release"
    fi
}

swift build --package-path tools -c release
tool="$ROOT/tools/.build/release/prism-extension"
if [[ "${run_tool_tests:-}" == 1 ]]; then
    swift test --package-path tools
fi

for folder in "${folders[@]}"; do
    echo "==> $folder"
    if [[ -f "$folder/Package.swift" ]]; then
        build_extension "$folder"
        if [[ -d "$folder/Tests" ]]; then
            swift test --package-path "$folder" "${build_system[@]}"
        fi
    fi
    if [[ -d "$folder/tests" && -x "$folder/tests/run" ]]; then
        "$folder/tests/run"
    fi
    "$tool" lint "$folder"
    "$tool" smoke "$folder"
done
