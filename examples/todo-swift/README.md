# To-Do (Swift)

A list extension written with `PrismExtensionKit`. It shows the parts of a
`list` command:

- `list(command:query:filter:context:)` returns items with accessories,
  inline detail, and actions; `filtering: .extension` makes Prism send the
  query with every load;
- a ⌘P filter (`All To-Dos`, `Added Today`);
- `perform(action:item:command:context:)` saves to Prism's state and returns
  `.reload(message:)`; `Mark as Done` is `destructive`, so Prism asks first;
- a `copy` action Prism carries out itself, with a ⌘⇧C shortcut.

```sh
swift build -c release
```

Then open Prism Settings → Extensions → Gallery → Import Extension… and choose
this folder.
