# Repository Guidelines

Extensions for [Prism](https://github.com/natsustan/prism), the macOS launcher.
Everything in the Extension Gallery is built from this repository, Prism's own
extensions included. `README.md` explains the layout, checks, and release
pipeline for people; this file adds what an agent working here needs.

## Where things live

- `extensions/<folder>/`: one Gallery extension per folder. First-party
  folders have no dot (`extensions/caffeinate`) and their manifest ID adds the
  reserved `prism.` namespace (`prism.caffeinate`). Everyone else uses
  `<github-username>.<name>` as both ID and folder name. `prism-extension lint`
  enforces the match.
- `templates/swift/`: the starting point for a Swift extension.
- `examples/`: `focus-flag` and `folders` (plain sh), `todo-swift` (a Swift
  list). They are teaching material, not Gallery entries.
- `tools/`: the `prism-extension` CLI (`lint`, `smoke`, `pack`, `index`),
  `check.sh`, and `release.sh`.
- `.agents/skills/`: task playbooks (`.claude/skills` points here). Use them:
  `new-extension`, `extension-recipes`, `release-extension`, `kit-change`.

The protocol and the Swift runtime are not here. They live in the Prism
repository under `Packages/PrismExtensionKit` and are published read-only to
`natsustan/prism-extension-kit`. Its README is the protocol reference; read it
before designing commands, lists, widgets, or preferences.

## Build and check

Use macOS 26+ and Swift 6.1 or newer.

- `swift build --package-path extensions/<folder> -c release`: build one
  Swift extension (the manifest's `executable` points at
  `.build/release/<Target>`).
- `swift test --package-path extensions/<folder>`: its tests.
- `bash tools/check.sh extensions/<folder>`: build, test, `tests/run`, lint,
  and smoke, exactly as CI does. Run it before every commit that touches an
  extension; `--changed origin/main` checks everything a branch touched.
- `PRISM_KIT_PATH=<prism>/Packages/PrismExtensionKit`: build against the
  Prism checkout's unreleased Kit (`~/projects/prism` on the maintainer's Mac).
- `swift package --package-path <folder> update`: `Package.resolved` files
  are ignored, so a local one can lag the published Kit (in `tools/` that once
  dropped new index fields). Update before testing against a new Kit.
- `bash tools/release.sh --site <tmp> --dry-run`: what merging would publish.

To try an extension in the real app, build it and import the folder in Prism
(Settings → Extensions → Gallery → Import Extension…). Prism runs it in place
and picks up a rebuilt executable on the next request. Only Prism Dev accepts
a local folder whose ID uses `prism.`. Lint and tests do not show how a list
or widget looks; say so when a change is visible and has not been tried.

## How an extension behaves

Prism starts an extension on demand, talks NDJSON over stdin/stdout, and ends
it after a minute idle or above 150 MB. Design for that:

- Keep nothing important in process memory. Small values go in Prism
  (`context.setState`, 1 MB per extension); caches go in
  `context.dataDirectory`, which Prism deletes on uninstall.
- Read preferences from `context.preferences` on every request; they change
  while the process runs.
- stdout is the protocol. `print` goes to stderr; use `context.log` for lines
  worth keeping.
- A newer list load cancels the older one. Check `Task.checkCancellation()`
  between slow steps, and never let a cancelled load write state.
- Long-running helpers are manifest `tasks` started with `context.startTask`,
  never child processes left running after a request. `smoke` fails an
  extension that leaves processes behind.
- Item, action, filter, and command IDs are identity: keep them stable across
  reloads and versions. Hotkeys, favorites, and selection follow them.
- When a load can show something useful, return a list rather than throwing:
  an empty-state message (`emptyMessage`), a sign-in or grant row, or the last
  good data with `fetchedAt` and `error` so Prism shows it as stale. Throw
  `PrismExtensionError` only for a message the user should read as a failure.
- Return quickly. Serve cached data at once, refresh in the background, then
  call `context.listChanged` (Agent Usage), or cache responses per query with a
  max age (GitHub's `ResponseCache`).

## Manifest and permissions

- Declare every `capabilities` entry the code actually uses, and nothing
  more: `network`, `readHomeFiles`, `keychainRead`, `spawnProcesses`,
  `inspectProcesses`, `hostTasks`. Prism shows them before install and asks
  again when they grow.
- Protected folders (another app's container) go under `folders` with a
  plain `reason`; on a permission error offer a `grantFolder` action instead of
  asking for Full Disk Access (Apple Notes).
- Credentials: a `secret` preference (kept in the Keychain by Prism), with a
  fallback to a CLI the user already signed in to (`gh auth token`) when one
  exists. Read other apps' Keychain items through `/usr/bin/security`, which
  never prompts (Agent Usage's `ClaudeAuthStore`). Send a credential only to
  the service it belongs to.
- An extension must not download and run other programs, and every binary is
  built from the source in its folder.
- A `list` command that searches inside an app sets `searchesApp` to that
  app's bundle ID so Tab on the app's row opens it.

## Wording and design

Prism aims for Apple's taste: plain words, title case for commands and
actions, sentence case for captions, curly quotes and ellipses (`…`). No fake
or placeholder data in lists or widgets; show real data, an honest empty
state, or a loading row. Pick SF Symbols and tints from the README's list;
brand marks go in `icons/` as small SVGs with their license. For Chinese
content, add pinyin keywords so Latin typing finds it (`PinyinKeywords` in
Apple Notes).

## Code style and tests

Follow the existing Swift: four-space indentation, Swift 6 language mode,
`UpperCamelCase` types, `lowerCamelCase` members, files named after their
main type. The `@main` type keeps command, action, filter, and preference IDs
in nested `enum`s of `static let`s and stays thin; providers, clients, and
mapping live in their own files. Doc comments say why, not what.

Tests use Swift Testing (`@Suite`, `@Test("plain sentence")`, `#expect`) and
drive the extension through `PrismTestHost`, never a spawned process. Inject
what touches the outside world (HTTP transport, clock, CLI, file store,
process list) through an internal initializer, and keep the no-argument
`init()` for production. Tests are deterministic: fixed dates, canned JSON,
no network, no real Keychain, results that hold in every time zone.

## Versions, changelog, and the Kit

- A change that should reach users bumps `version` in the manifest and adds
  a `CHANGELOG.md` entry written for them: minor for new features, patch for
  fixes. Merging publishes only versions without a release, so an icon or
  README change needs a bump too, and a change without one (tests, a folder
  rename) publishes nothing; say so in the PR.
- `Package.swift` depends on the Kit by URL with `from:` the oldest published
  version that has everything the extension uses. Released tags never move.
- When an extension needs something the protocol lacks, change the Kit and
  the host in the Prism repository first, additively, publish a new Kit
  version, and only then merge the extension that needs it (`kit-change`
  skill). Never work around a missing protocol feature inside one extension.

## Commits and pull requests

Branch per change (`feat/<extension>`, `fix/…`, `chore/…`) and merge through a
pull request; merging to `main` publishes. Prefix commits with `feat:`,
`fix:`, or `chore:` in the imperative, describing what the user gets
("feat: open Search Notes with Tab from Notes' own row"). PRs describe the
behavior change, list the commands run (`tools/check.sh` output), and include
screenshots for visible changes. A Codex bot reviews PRs; weigh its findings
before merging. Work is not shipped until it is merged to `main`; before
wrapping up, check `git log origin/main..` on extension branches.

Never commit `.build/`, `.swiftpm/`, `Package.resolved` (ignored everywhere,
so each build resolves the newest Kit its `from:` allows), `*.prismextension`
packages, or signing material.
