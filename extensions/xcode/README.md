# Xcode

Quickly open your recently used Xcode projects from the launcher.

- **Recent Projects** lists projects (`.xcodeproj`), workspaces (`.xcworkspace`), Swift packages (`Package.swift`), and playgrounds (`.playground`) you have recently opened in Xcode, newest first. Filter by type with ⌘P.
- Return opens the item in Xcode. The action panel (⌘K) shows it in Finder (⌘⇧F), copies its path (⌘⇧C), or copies its containing folder path (⌘⇧D).
- Xcode’s own row in root search offers the list too: select Xcode and press Tab to browse recent projects right away; Backspace in the empty search returns to Xcode.
- To open projects with a specific build such as Xcode Beta, set **Xcode App Path** in the extension’s settings.

Recent projects are merged from Xcode’s Shared File List (`com.apple.dt.xcode.sfl4`/`.sfl3`/`.sfl2`), DerivedData `info.plist` records (including custom DerivedData locations), editor interactivity history (`IDEEditorInteractivityHistory`), and `com.apple.dt.Xcode.plist`. Deleted paths and internal Xcode or checkout directories are skipped automatically.

Capabilities: `readHomeFiles` (reads Xcode’s local recent-project records in `~/Library`).
