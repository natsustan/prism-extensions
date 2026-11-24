# Bear

Search your Bear notes and tags from Prism, preview Markdown, and create or open notes in Bear.

- **Search Bear Notes** searches active notes by title, tags, snippet, body text, or Chinese pinyin (`xuanguan` or `xg` finds “玄关”). Every typed word must match. Press ⌘P to switch between All Notes, Pinned, Todo, Untagged, Locked, and Archived. The detail pane previews the note’s Markdown and metadata. When nothing matches in All Notes, press Return to create a new note with that title in Bear.
  - Return opens the note in Bear. The action panel (⌘K) opens in a new window (⌘⇧O), copies the note link (⌘⇧C), Markdown (⌘⇧M), or title (⌘⇧T), archives the note (⌘⇧A), or moves it to Trash.
  - Bear’s own row in root search offers the search too: select Bear and press Tab to search inside it; Backspace in the empty search returns to Bear.
- **Search Bear Tags** lists active Bear tags (pinned first), with note counts and pinyin search. Return opens the tag in Bear; ⌘K copies `#tag` (⌘⇧C) or its Bear link (⌘⇧L).
- **New Note from Clipboard** creates a new Bear note from the current clipboard text and opens it for editing.

## Setup

Notes and tags are read directly from Bear’s SQLite database (`~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite`), read-only. Each load checks whether Bear changed the database and rereads it only then; pinyin keywords are cached in the extension’s data directory.

macOS protects Bear’s Group Container. The first time you open a Bear list, it shows **Allow Access to Your Bear Notes** — press Return and click **Allow** in the folder panel. Full Disk Access is not needed.

Requires Bear for macOS. Capabilities: `readHomeFiles` (reads Bear’s local database).
