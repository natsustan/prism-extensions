---
name: release-extension
description: Ship a change to a Prism extension to the Gallery — bump the version, write the changelog entry, run the checks, open the pull request, handle review, and confirm the release workflow published it. Use when an extension change is ready to commit, push, or merge, or to check whether something actually shipped.
---

# Release an extension

Merging to `main` is the release: `.github/workflows/release.yml` runs
`tools/release.sh`, which publishes every extension whose manifest version has
no `<id>@<version>` GitHub release yet. Nothing ships until the pull request
is merged.

## 1. Version and changelog

- Decide whether users should get this change. Tests, comments, and folder
  moves may skip the bump; then nothing publishes, and the PR says so.
- Otherwise bump `version` in `manifest.json`: minor for a new command,
  preference, widget, or visible behavior; patch for fixes; major only when
  something users rely on goes away. An icon or README change needs at least
  a patch, since released entries are not re-indexed.
- Add the entry at the top of `CHANGELOG.md`. The heading must be exactly
  `## <version>`; `release.sh` cuts the GitHub release notes from it.

```markdown
## 1.2.0

- <What changed for the user, in their words. No file or type names.>
```

- If the code now uses Kit API newer than `Package.swift`'s `from:`, raise
  `from:` to the first published version that has it. If that version is not
  published yet, stop and follow `kit-change`.

## 2. Check

```sh
cd ~/projects/prism-extensions
bash tools/check.sh extensions/<folder>
bash tools/check.sh --changed origin/main   # everything the branch touched
```

Both must pass without `PRISM_KIT_PATH`: CI builds against the published Kit.
For a visible change, ask the maintainer to try the rebuilt extension in
Prism Dev and capture a screenshot for the PR.

Optionally preview what merging would publish (needs `gh` signed in):

```sh
bash tools/release.sh --site "$(mktemp -d)" --dry-run
```

## 3. Commit and pull request

- Branch `feat/<folder>`, `fix/<folder>-…`, or `chore/…`; commits `feat:`,
  `fix:`, `chore:` in the imperative, about what the user gets.
- Push and open the PR with `gh pr create`. Body sections: `## Summary`
  (behavior changes, version), `## Notes` (anything the maintainer must do,
  such as re-importing a local folder), `## Verification` (the commands run
  and their results; screenshots for UI).
- Wait for the `Check` workflow (`gh pr checks <n> --watch`).
- A Codex bot reviews every PR. Read its comments
  (`gh api repos/natsustan/prism-extensions/pulls/<n>/comments` and
  `gh pr view <n> --comments`), fix real issues with new commits, and explain
  in a reply why the rest don't apply.
- Merge only when the maintainer says to.

## 4. Confirm it shipped

The release job runs in the `gallery` environment, which may wait for the
maintainer's approval.

```sh
gh run list --repo natsustan/prism-extensions --workflow release.yml --limit 3
gh release view '<id>@<version>' --repo natsustan/prism-extensions
curl -s https://natsustan.github.io/prism-extensions/index.json \
  | jq '.extensions[] | select(.manifest.id == "<id>") | .manifest.version'
```

The index is signed; Prism's Gallery picks up the new version on its next
refresh. When wrapping up a session, look for finished work that never
merged: `git log origin/main..<branch>` for each extension branch, and
`gh pr list --state open`.
