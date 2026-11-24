# Zed

Quickly open your recently used Zed projects from the launcher.

- **Recent Projects** lists local folders, multi-folder workspaces, files, and remote SSH or container workspaces you have recently opened in Zed, newest first, along with the current Git branch for local repositories. Filter between local and remote workspaces with ⌘P.
- Return opens the item in Zed. The action panel (⌘K) shows local items in Finder (⌘⇧F), copies the path (⌘⇧C), or copies the containing folder path for single files (⌘⇧D).
- Zed’s own row in root search offers the list too: select Zed and press Tab to browse recent projects right away; Backspace in the empty search returns to Zed.
- To use a different build such as Zed Preview or Zed Nightly, set **Zed App Path** in the extension’s settings; its matching workspace database (`0-preview`, `0-nightly`, or `0-dev`) is read automatically.

Recent workspaces are read read-only from Zed’s SQLite database under `~/Library/Application Support/Zed/db/`. Empty windows and deleted local paths are skipped automatically.

Capabilities: `readHomeFiles` (reads Zed’s local workspace history in `~/Library/Application Support/Zed/db`).
