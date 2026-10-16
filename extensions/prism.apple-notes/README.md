# Apple Notes

Search your Apple Notes from the launcher.

- **Search Notes** lists every note that is not in Recently Deleted, pinned
  notes first and the rest newest first. Type to filter by title, content
  snippet, folder, account, or tag; Chinese text also matches its pinyin
  (`xuanguan` or `xg` finds “玄关”).
- Return opens the note in Notes. The action panel (⌘K) copies the note's
  link (⌘⇧C) or title (⌘⇧T).
- Rows show the folder, and whether the note is locked or has a checklist.

The list is read from Notes' own database
(`~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`),
read-only, on every load, so it follows edits made in Notes. It shows the
1,000 most recently edited notes.

macOS keeps that database behind Full Disk Access. The extension runs as part
of Prism, so turn on Full Disk Access for Prism (Prism Dev for development
builds) in System Settings → Privacy & Security; the list offers to open that
page when access is missing.

Capabilities: `readHomeFiles` (reads the Notes database).
