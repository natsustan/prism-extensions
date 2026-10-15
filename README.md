# Prism Extensions

Extensions for [Prism](https://github.com/natsustan/prism), the macOS
launcher. Everything in the Extension Gallery is built from this repository,
Prism's own extensions included.

An extension runs outside Prism and answers its requests over stdio; Prism
draws every view from the data it returns. Write one as a script with no build
step, or in Swift with
[PrismExtensionKit](https://github.com/natsustan/prism-extension-kit), whose
README documents the protocol.

## Layout

```
extensions/<id>/     one folder per Gallery extension
  manifest.json      commands, preferences, widgets, capabilities
  README.md          what it does and what it needs (accounts, tools)
  CHANGELOG.md       one entry per version
  Package.swift      Swift extensions: Sources/ and Tests/
  bin/, tests/run    script extensions: the script and an optional test runner
templates/swift/     start here for a Swift extension
examples/            focus-flag and folders (sh), todo-swift (a list in Swift)
tools/               prism-extension lint / smoke, and check.sh
```

`extensions/prism.*` are Prism's own extensions. The `prism.` namespace is
reserved for them; everyone else uses `<github-username>.<name>`.

## Making an extension

1. Copy `templates/swift` (or an example) to `extensions/<your-github-name>.<name>`
   and edit `manifest.json`, `Package.swift`, and `Sources/`.
2. Build it: `swift build -c release`.
3. In Prism, open Settings → Extensions → Gallery → Import Extension… and
   choose the folder. Prism runs it in place and reloads it when you rebuild.
4. Write tests next to it. Swift extensions use `PrismTestHost` from
   `PrismExtensionTesting`, which plays Prism in memory (see the template's
   `Tests/`). Script extensions may add an executable `tests/run`.

To build against a Prism checkout's unreleased Kit, set
`PRISM_KIT_PATH=<prism>/Packages/PrismExtensionKit`.

## Checking

```sh
bash tools/check.sh extensions/<id>     # build, test, lint, smoke
bash tools/check.sh --changed origin/main
```

`check.sh` builds Swift extensions, runs their tests and `tests/run`, then:

- `lint`: the manifest and executable checks Prism itself applies on import,
  plus this repository's rules (folder named after the ID, README, changelog,
  a `description`);
- `smoke`: starts the extension in its own process group, sends `initialize`,
  loads each list and widget once, closes stdin, and fails if it does not exit
  or leaves processes behind. Commands are not run, since they may have side
  effects.

CI runs the same script on every pull request, for the folders it changes.

## Submitting

Fork this repository, add your folder under `extensions/`, and open a pull
request. Every change bumps `version` in the manifest and adds a
`CHANGELOG.md` entry. After review and merge, the release pipeline builds the
extension from source, signs the package, and publishes it to the Gallery;
you do not need a signing certificate. Binaries must be built from the source
in the folder, and an extension must not download and run other programs.
