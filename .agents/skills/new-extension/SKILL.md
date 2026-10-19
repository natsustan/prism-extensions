---
name: new-extension
description: Create a new Prism extension in this repository from the Swift template or a script example — choose its ID and folder, design the manifest, rename the package, write README and CHANGELOG, tests, and get it running in Prism. Use when starting any new extension under extensions/.
---

# New extension

Read `AGENTS.md` and the Kit README (`~/projects/prism/Packages/PrismExtensionKit/README.md`,
or `.build/checkouts/prism-extension-kit/README.md` in any built extension)
before designing anything. For how to build a specific feature, use the
`extension-recipes` skill.

## 1. Design the surface first

Write down, before any code, what the user will see, and map each piece to the
protocol:

| The user wants… | Manifest | Swift (`PrismExtension`) |
| --- | --- | --- |
| An action from root search or a hotkey | command, `"mode": "no-view"` | `run(command:context:)` |
| To browse or search things | command, `"mode": "list"` | `list`, `perform`, optionally `detail` |
| To search inside an app from its row | list command + `"searchesApp": "<bundle id>"` | same as list |
| Live state on a row ("Caffeinated") | command + `"liveStatus": true` | `status(for:context:)`, `statusRefreshInterval` |
| A widget | `widgets` with a `template` | `widget(_:context:)` |
| Settings | `preferences` (`bool`, `text`, `secret`, `orderedList`, optional `section`) | `context.preferences`, `preferenceItems` for `orderedList` |
| A program that keeps running | `tasks` + `hostTasks` capability | `context.startTask` |
| Another app's protected files | `folders` + `readHomeFiles` | a `grantFolder` action on permission errors |

Keep the command count small and the titles plain ("Search Notes", "Toggle
Caffeinate"). Show the user the planned commands, lists, and widgets when the
extension is visible enough that the design is a real choice.

## 2. Pick the ID and folder

- Prism's own: ID `prism.<name>`, folder `extensions/<name>`, `"author": "Prism"`.
- Anyone else: ID and folder both `<github-username>.<name>`, author their name.
- `<name>` is lowercase letters, digits, and hyphens. The ID never changes
  after release; users' hotkeys, favorites, and state hang on it.

## 3. Copy and rename (Swift)

`Target` below is the UpperCamelCase name (`AppleNotes`). The maintainer's
shell aliases `cp`/`rm` to prompt, so call `/bin/cp` and `/bin/rm`.

```sh
cd ~/projects/prism-extensions
folder=extensions/<folder>; Target=<Target>
/bin/cp -R templates/swift "$folder"
/bin/rm -rf "$folder/.build" "$folder/.swiftpm" "$folder/Package.resolved" "$folder/.gitignore"
mv "$folder/Sources/HelloSwift" "$folder/Sources/$Target"
mv "$folder/Sources/$Target/HelloSwift.swift" "$folder/Sources/$Target/$Target.swift"
mv "$folder/Tests/HelloSwiftTests" "$folder/Tests/${Target}Tests"
mv "$folder/Tests/${Target}Tests/HelloSwiftTests.swift" "$folder/Tests/${Target}Tests/${Target}Tests.swift"
grep -rl HelloSwift "$folder" | xargs sed -i '' "s/HelloSwift/$Target/g"
```

Then edit by hand:

- `Package.swift`: keep the template's `from:` unless the extension uses Kit
  API added later; then raise it to the first version that has that API
  (`from:` is the oldest Kit the extension works with). Published versions,
  newest first:
  `git ls-remote --tags --refs --sort=-v:refname https://github.com/natsustan/prism-extension-kit.git`.
  Keep the `PRISM_KIT_PATH` switch as it is.
- `manifest.json`: `id`, `name`, `version` (`1.0.0` for the first Gallery
  release), `author`, a one-sentence `description` (the Gallery requires it),
  `icon`, `executable` (`.build/release/<Target>`), commands, preferences,
  widgets, `capabilities` (only what the code uses).
- `Sources/<Target>/<Target>.swift`: replace the greeting code. Keep IDs in
  nested `enum CommandID` / `ActionID` / `PreferenceID`, a production `init()`,
  and an internal `init(...)` that takes the outside world (transport, clock,
  store, process list) for tests.
- `Tests/`: replace the template tests with real ones (see below).

Script extension instead: copy `examples/focus-flag`, rename `bin/<name>`,
`chmod +x` it, point `executable` at it, and add an executable `tests/run` if
it has logic worth testing. Prefer Swift for anything beyond a few commands.

## 4. README and CHANGELOG

`README.md` follows the existing ones (`extensions/caffeinate/README.md`,
`extensions/github/README.md`): a short opening line, a bullet per command in
bold with what it does and its keys (⌘P filters, ⌘K actions, shortcuts), a
`## Setup` section when an account, token, CLI, or folder grant is needed,
and a closing line naming what it needs and why each capability is declared.

`CHANGELOG.md`:

```markdown
# Changelog

## 1.0.0

- <What the user can do, one bullet per command or feature.>
```

## 5. Tests

Drive the extension through `PrismTestHost` (Swift Testing, `@Test("plain
sentence")`). Cover each command, list (empty, populated, query, each filter),
action, widget, status, and every error path the user can hit (signed out,
no permission, network failure with cached data). Fake the outside world:
canned JSON through an injected transport (`extensions/github/Tests`), a
settable clock, a temporary `dataDirectory`. No network, real Keychain, or
real user files; fixed dates that hold in every time zone.

## 6. Build, check, and try it

```sh
swift build --package-path "$folder" -c release
bash tools/check.sh "$folder"
```

Fix everything `lint` and `smoke` report. Then the maintainer imports the
folder in Prism Dev (Settings → Extensions → Gallery → Import Extension…),
which reloads it on each rebuild. Ask them to try it; tests don't show how a
list or widget looks.

## 7. Ship

Commit on `feat/<folder>` (`feat: add <Name> as a first-party extension` or
`feat: add the <Name> extension`), then follow `release-extension`.
