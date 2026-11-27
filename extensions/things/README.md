# Things

Search, complete, organize, and quick-add Things to-dos from the launcher.

- **My To-Dos** lists your Things to-dos grouped by list (Today, Inbox, Upcoming, Anytime, Someday), with trailing badges for deadlines, scheduled dates, projects or areas, and tags. Search by title, notes, project, area, tags, or Chinese pinyin (`mnn` or `mainiunai` finds “买牛奶”). Press ⌘P to switch between All Active, Today, Inbox, Upcoming, Anytime, Someday, Logbook, or any individual Project or Area.
  - Return completes or reopens a to-do. The action panel (⌘K) opens it in Things (⌘⇧O), cancels it (⌘⇧X), schedules it (⌘⇧S), sets or clears its deadline (⌘⇧D), moves it to Inbox, a project, or an area (⌘⇧M), opens attached links (⌘⇧L), copies title (⌘⇧T), notes (⌘⇧N), or its Things link (⌘⇧C), or moves it to Trash.
  - When nothing matches in an active filter, press Return to add a new to-do right away (using Quick Add syntax, into the active project or area if one is selected).
  - Things’ own row in root search offers the search too: select Things and press Tab to search inside it; Backspace in the empty search returns to Things.
- **Quick Add To-Do** parses a single line into a new Things to-do with a live preview before you press Return. Supports English and Chinese schedules (`today`, `evening`, `tomorrow 9am`, `friday`, `someday`, `明天 下午3点半`, `3天后`), deadlines (`due:friday`, `ddl:2026-12-01`, `截止:周六`), project or area (`@Project`), `#tags`, and inline notes (`// notes`). Press Return to add silently in the background, ⌘⇧O to add and open in Things, ⌘⇧S to override the schedule, or ⌘⇧M to pick a project or area.

## Setup

Things uses Things 3’s official AppleScript interface and `things:///` URL scheme—no Full Disk Access and no direct database reads required. Pinyin keywords are cached in the extension’s data directory.

The first time you browse or update to-dos, macOS asks whether Prism may control Things. If access was turned off earlier, the list offers **Open Automation Settings** to take you directly to **System Settings → Privacy & Security → Automation**.

Requires Things 3 for macOS and Prism 0.12.1 or later. Capabilities: `appleEvents` (reads and updates to-dos via Things’ AppleScript interface), `spawnProcesses` (runs `/usr/bin/osascript`).
