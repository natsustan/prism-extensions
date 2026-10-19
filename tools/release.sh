#!/usr/bin/env bash
# Publishes every extension whose manifest version has no release yet:
# builds it from source, signs first-party binaries when a Developer ID is
# available, packs it, creates the GitHub release `<id>@<version>` with the
# package, and adds it to the Gallery index in the site folder, which is then
# signed. The release workflow runs this on main and pushes the site to the
# gh-pages branch.
#
#   bash tools/release.sh --site <folder> [--dry-run]
#
# Environment: GITHUB_REPOSITORY (owner/name), PRISM_GALLERY_SIGNING_KEY and
# PRISM_GALLERY_KEY_ID (index signature), and optionally DEVELOPER_ID_IDENTITY
# (a codesigning identity already in the keychain) for prism.* binaries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

site=""
dry_run=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site) site="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
done
[[ -n "$site" ]] || { echo "Usage: bash tools/release.sh --site <folder> [--dry-run]" >&2; exit 2; }
repository="${GITHUB_REPOSITORY:-natsustan/prism-extensions}"
mkdir -p "$site"
# Nothing is released unless the index that lists it can be signed.
if ! $dry_run && [[ -z "${PRISM_GALLERY_SIGNING_KEY:-}" || -z "${PRISM_GALLERY_KEY_ID:-}" ]]; then
    echo "PRISM_GALLERY_SIGNING_KEY and PRISM_GALLERY_KEY_ID must be set to publish." >&2
    exit 1
fi

swift build --package-path tools -c release
tool="$ROOT/tools/.build/release/prism-extension"
packages="$(mktemp -d)"
trap '/bin/rm -rf "$packages"' EXIT

manifest_field() {
    /usr/bin/plutil -extract "$2" raw -o - "$1/manifest.json"
}

# The section for one version in CHANGELOG.md, without its heading.
release_notes() {
    awk -v version="$2" '
        $0 ~ "^## " { if (found) exit; if ($2 == version) { found = 1; next } }
        found { print }
    ' "$1/CHANGELOG.md"
}

published=0
moved=0
for folder in extensions/*/; do
    folder="${folder%/}"
    [[ -f "$folder/manifest.json" ]] || continue
    id="$(manifest_field "$folder" id)"
    version="$(manifest_field "$folder" version)"
    tag="$id@$version"
    source_url="https://github.com/$repository/tree/main/$folder"
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
        # A released version keeps its entry, but its source link follows the
        # folder when that moves.
        if [[ -f "$site/index.json" ]] && [[ "$("$tool" index source --index "$site/index.json" \
            --id "$id" --url "$source_url")" == Moved* ]]; then
            moved=$((moved + 1))
        fi
        continue
    fi
    echo "==> $tag"

    if [[ -f "$folder/Package.swift" ]]; then
        swift build --package-path "$folder" -c release
        executable="$folder/$(manifest_field "$folder" executable)"
        if [[ "$id" == prism.* && -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
            # Prism's own code keeps one signing identity across versions, so
            # macOS remembers Keychain and privacy permissions after updates.
            codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$executable"
        fi
    fi

    "$tool" lint "$folder"
    "$tool" pack "$folder" --output "$packages" >/dev/null
    package="$packages/$id-$version.prismextension"
    asset_url="https://github.com/$repository/releases/download/${tag//@/%40}/$(basename "$package")"
    notes="$packages/$id-notes.md"
    release_notes "$folder" "$version" > "$notes"

    if $dry_run; then
        echo "Would release $tag with $(basename "$package")"
    else
        gh release create "$tag" "$package" --repo "$repository" \
            --title "$(manifest_field "$folder" name) $version" --notes-file "$notes"
    fi
    "$tool" index add --index "$site/index.json" --package "$package" --url "$asset_url" \
        --source "$source_url" --notes "$notes"
    published=$((published + 1))
done

if [[ $published -eq 0 && $moved -eq 0 ]]; then
    echo "Nothing new to publish."
    exit 0
fi
if [[ -n "${PRISM_GALLERY_SIGNING_KEY:-}" ]]; then
    "$tool" index sign --index "$site/index.json" --key-id "$PRISM_GALLERY_KEY_ID"
fi
echo "Published $published extension version(s); moved $moved source link(s)."
