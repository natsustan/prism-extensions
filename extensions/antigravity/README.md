# Antigravity

Quickly browse and open your Antigravity projects and remote SSH hosts from the launcher.

- **Recent Projects** lists your Antigravity projects (single- and multi-folder) sorted by most recent conversation activity, along with the current Git branch for local repositories, plus your recently connected remote SSH hosts. Filter between local projects and remote hosts with ⌘P.
- Return opens Antigravity for local projects or connects directly to remote SSH hosts (`--ssh-host=`). The action panel (⌘K) copies the `agy --project` CLI command (⌘⇧T), shows local project folders in Finder (⌘⇧F), or copies the path or SSH host (⌘⇧C).
- Antigravity’s own row in root search offers the list too: select Antigravity and press Tab to browse projects right away; Backspace in the empty search returns to Antigravity.
- To target a different build such as Antigravity Insiders or Antigravity Dev, set **Antigravity App Path** in the extension’s settings; its matching data folders are read automatically.

Projects are read from `~/.gemini/config/projects/`, recent conversation timestamps read-only from `~/.gemini/antigravity/conversation_summaries.db`, and recent SSH hosts from `~/Library/Application Support/Antigravity/app_storage.json` and `ssh_windows.json`. Internal sidecar projects, the implicit CLI project, and deleted local folders are skipped automatically.

Capabilities: `readHomeFiles` (reads Antigravity’s local project definitions, conversation timestamps, and recent SSH host history).
