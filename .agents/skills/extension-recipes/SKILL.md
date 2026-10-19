---
name: extension-recipes
description: Proven patterns for building features in Prism extensions, each pointing at the extension in this repo that already does it — list commands, filters, actions, detail panes, live status rows, widgets, preferences, credentials, caching and background refresh, protected folders, host tasks, CJK search, and tests with PrismTestHost. Use when adding or changing a feature in any extension.
---

# Extension recipes

Before inventing a pattern, find the extension that already solved it and
copy its shape. Paths are relative to the repository root. The Kit README is
the reference for every field named here.

## Command results

`run` returns `ExtensionCommandResult`:

- `.done`: finished; the launcher closes and focus returns.
- `.completed(message:restoreFocus:)`: finished with a brief message.
- `.keepOpen(message:)`: the launcher stays open and shows the message.
- `.failed(message:)`: an expected failure the user should read.

Throw `PrismExtensionError("…")` only for unexpected states. Example:
`extensions/caffeinate/Sources/Caffeinate/Caffeinate.swift`.

## List commands

`extensions/github/Sources/GitHub/GitHub.swift` is the fullest example;
`extensions/apple-notes/Sources/AppleNotes/AppleNotes.swift` the simplest real one.

- **Who filters.** `filtering: .prism` lets Prism filter the returned items
  as the user types (small, complete lists). `.extension` sends `query` to
  `list` on every keystroke (search APIs, large local data). A newer load
  cancels the older one.
- **⌘P filters.** Return `filters: [ExtensionListFilter(id:title:symbol:)]`;
  the chosen ID arrives as `filter` (`nil` until picked). Return the same
  `filters` from every load of that command (GitHub's `ListShape`).
- **Rows.** Stable `id`, `title`, `subtitle` (one line), `icon`,
  `accessories` (text, tinted symbol, meter ring, `help` tooltip), `section` to group,
  `keywords` for extra match terms.
- **Actions.** The first runs on Return. `kind` is `.perform` (calls
  `perform`), `.copy(text:)`, `.open(url:)`, or `.grantFolder(id:)`. Give
  secondary actions shortcuts such as `cmd+shift+c`; never a key the launcher
  uses. Destructive actions set `style: .destructive` or a
  `confirmationMessage`, and Prism confirms. Return `.reload(message:)` from
  `perform` when the list changed, `.done` to close.
- **Detail pane.** Inline `detail` on an item, or `showsDetail` plus
  `detail(command:item:context:)` for expensive ones. A detail has a header,
  `notice`, `markdown`, `sections` of rows (badge, meter, date), and pinned
  `metadata`. Example: `extensions/agent-usage/Sources/AgentUsage/AgentUsagePresentation.swift`.
- **Empty and failure states.** Always set `emptyMessage` with a title and
  symbol, different for "nothing yet" and "no match". When a refresh fails but
  older data exists, return that data with `fetchedAt` and `error` so Prism
  marks it stale. Sign-in, token, and grant prompts are rows with an action,
  not errors (`extensions/github/Sources/GitHub/GitHubRows.swift`).
- **Open a list from an app's row.** `"searchesApp": "<bundle id>"` on the
  command (Apple Notes, GitHub).

## Remote data

- **Cache with a max age per kind of request** to respect rate limits, and
  keep the last response for offline display:
  `extensions/github/Sources/GitHub/ResponseCache.swift`.
- **Parallel requests** with a throwing task group, merged in a fixed order
  (GitHub's `issues`).
- **Serve instantly, refresh after.** Return cached data at once, refresh in
  a background `Task`, then `context.listChanged(command)` so an open list
  reloads; persist the cache in `context.dataDirectory` because the process is
  stopped when idle: `extensions/agent-usage/Sources/AgentUsage/AgentUsageSession.swift`.
- `try Task.checkCancellation()` between network steps.
- One client and one mapper per service, mapper tested against canned JSON
  (`extensions/agent-usage/Sources/AgentUsage/<Provider>/`).

## Credentials

- `secret` preference: Prism stores it in the Keychain and passes it like any
  other preference. Trim whitespace; treat empty as unset.
- Fall back to a CLI's existing login (`gh auth token`) with
  `spawnProcesses`, cached and re-asked only when its login changes:
  `extensions/github/Sources/GitHub/GitHubCLI.swift`.
- Read another app's Keychain item with `/usr/bin/security
  find-generic-password`, which never prompts, plus `keychainRead`:
  `extensions/agent-usage/Sources/AgentUsage/Claude/ClaudeAuthStore.swift`.
- Env vars and config files in `~` as further fallbacks, with `readHomeFiles`:
  `extensions/agent-usage/Sources/AgentUsage/ZAI/ZAIAuthStore.swift`.
- Captions say where the credential is sent ("Sent only to GitHub").

## Local data and protected folders

- Declare the folder in the manifest (`folders: [{id, path, reason}]`); map
  the permission error to an "Allow Access…" row whose action is
  `.grantFolder(id:)`. Never ask for Full Disk Access.
- Open another app's SQLite database read-only (`SQLITE_OPEN_READONLY`),
  reread only when it changed, and search in memory:
  `extensions/apple-notes/Sources/AppleNotes/NoteStore.swift`,
  `NoteLibrary.swift`, `NoteSearch.swift`.
- Chinese text: add pinyin keywords and cache them in `dataDirectory`
  (`PinyinKeywords.swift`, `PinyinCache.swift`).
- Cap results per load (Apple Notes returns 100) and rank title matches first.

## Live status rows

Manifest `"liveStatus": true`; implement `status(for:context:)` returning
`ExtensionRowStatus(text:symbol:isLive:)` or `nil`. Set
`statusRefreshInterval` only when the state changes outside the extension
(Caffeinate polls every 2 s). Status reads cannot write state.
Example: `extensions/caffeinate`, `templates/swift`.

## Widgets

- `toggleCard`: an on/off card whose tap runs `toggleCommandID`
  (`extensions/caffeinate`).
- `quotaRing`, `quotaNumber` (one item), `quotaRings`, `quotaNumbers`,
  `quotaBars` (two): `ExtensionQuotaCard` of `ExtensionQuotaItem`s with
  `ExtensionMeter(fraction:tone:resetsAt:)`, and `openCommandID` to open a
  list on click (`extensions/agent-usage/Sources/AgentUsage/AgentUsageWidgetSnapshot.swift`).
- A widget load must be fast and must not show made-up numbers; use
  `emptyText` when there is nothing real yet.
- A widget that needs a template Prism lacks is a `kit-change`.

## Preferences

- Read on every request; values change while the process runs.
- `section` groups preferences in settings, in first-seen order.
- `orderedList`: implement `preferenceItems` with each item's default
  `isOn`, then resolve with
  `context.preferences.orderedList(id).enabledIDs(with: items)`
  (`extensions/agent-usage`, the `agents` preference).

## Host tasks and processes

- A program that must outlive the request (or Prism) is declared under
  `tasks` with an absolute `executable` and `survivesHost` when needed, plus
  `hostTasks`; start it with `context.startTask(id, arguments:)` and poll for
  it to appear (Caffeinate's `start`).
- Finding or stopping processes needs `inspectProcesses`; hide it behind a
  protocol so tests use a fake (`CaffeinateProcesses.swift`).
- Short-lived helpers (`gh`, `security`) run with `spawnProcesses`, are
  awaited within the request, and get a timeout.

## Icons

`ExtensionIcon` takes `symbol`, `tint`, `image`, `app`, and `style`. `app` shows an installed app's
icon (Apple Notes rows); `image` an SVG under `icons/` (GitHub's Octicons,
Agent Usage's provider marks), with its license file beside it; `style:
.glyph` colors a row's icon by meaning (pull request state); `.tile` puts a
brand mark on a tile for the extension's own icon.

## Testing patterns

`PrismTestHost(MyExtension(...), extensionID:, preferences:, state:, dataDirectory:)`
then `run`, `list(_:query:filter:)`, `detail(_:in:)`, `perform(_:on:in:)`,
`widget`, `status`, `preferenceItems`, `setPreferences`, `restart`, and the
recorded `state`, `startedTasks`, `changedLists`, `logs`.

- Fake HTTP with an actor that routes by path and records requests:
  `FakeGitHub` in `extensions/github/Tests/GitHubTests/GitHubTests.swift`.
- A settable `Clock` for cache expiry and relative dates; reference dates
  chosen so the test holds in every time zone.
- `restart` to prove that something survives the process stopping.
- Shared builders in a `*TestSupport.swift` file
  (`extensions/agent-usage/Tests/AgentUsageTests/AgentUsageTestSupport.swift`).
