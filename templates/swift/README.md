# Hello Swift

A template for Prism extensions written in Swift with `PrismExtensionKit`.

```sh
swift build -c release
```

Then open Prism Settings → Extensions → Gallery → Import Extension… and choose
this folder. After the first import, rebuilding is enough: Prism notices the
new executable and runs it on the next command.

To start your own extension, copy this folder and change:

- `manifest.json`: `id` (`<your-github-name>.<name>`), `name`, commands,
  preferences, and `executable` (`.build/release/<YourTarget>`);
- `Package.swift`: the package, target, and test target names;
- `Sources/`: one type marked `@main` that conforms to `PrismExtension`;
- `Tests/`: tests that drive it through `PrismTestHost` (`swift test`).

`print` goes to stderr, which Prism keeps for diagnostics. Save anything that
must last with `context.setState`; Prism stops idle extensions.
