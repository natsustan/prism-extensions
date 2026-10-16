# Apple Notes

Search your Apple Notes from the launcher.

- **Search Notes** searches every note that is not in Recently Deleted, by
  title, content snippet, folder, account, or tag; Chinese text also matches
  its pinyin (`xuanguan` or `xg` finds “玄关”). Every typed word must match.
  Pinned notes come first, then notes whose title matches, then the rest,
  newest first. It shows the best 100 results; with nothing typed, the 100
  most recently edited notes.
- Return opens the note in Notes. The action panel (⌘K) copies the note's
  link (⌘⇧C) or title (⌘⇧T).
- Rows show the folder, and whether the note is locked or has a checklist.

The list is read from Notes' own database
(`~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`),
read-only, on every search, so it follows edits made in Notes. Pinyin is
computed once per text and kept in the extension's data directory.

macOS keeps that database behind Full Disk Access. The extension runs as part
of Prism, so turn on Full Disk Access for Prism (Prism Dev for development
builds) in System Settings → Privacy & Security; the list offers to open that
page when access is missing.

Capabilities: `readHomeFiles` (reads the Notes database).
