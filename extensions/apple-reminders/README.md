# Reminders

Search, complete, organize, and quick-add Reminders from the launcher.

- **My Reminders** lists your Apple Reminders grouped by due date (Overdue, Today, Scheduled, No Due Date), with trailing badges for due dates, recurrence, location alarms, priority, tags, and lists. Search by title, notes, list, tags, priority, location, or Chinese pinyin (`mnn` or `mainiunai` finds “买牛奶”). Press ⌘P to switch between All, Today, Overdue, Scheduled, Completed, or any individual reminder list.
  - Return completes or uncompletes a reminder. The action panel (⌘K) opens the reminder in Reminders (⌘⇧O), sets a due date (⌘⇧D), sets priority, moves the reminder to another list (⌘⇧M), opens attached links (⌘⇧L), copies title (⌘⇧T), notes (⌘⇧N), or link (⌘⇧C), or deletes the reminder.
  - When nothing matches in an active filter, press Return to create a new reminder right away (using Quick Add syntax, into the active list if one is selected).
  - Reminders’ own row in root search offers the search too: select Reminders and press Tab to search inside it; Backspace in the empty search returns to Reminders.
- **Quick Add Reminder** parses a single line into a new reminder with a live preview before you press Return. Supports English and Chinese dates and times (`tomorrow 9am`, `in 30m`, `friday`, `明天 下午3点半`, `2小时后`), priority (`!` / `!!` / `!!!` or `!low` / `!medium` / `!high`), list selection (`#List` / `@List`), `#tags`, and inline notes (`// notes`). Press ⌘⇧O to create and open in Reminders, or ⌘⇧M to pick another list.

## Setup

Apple Reminders uses macOS’s native EventKit framework directly—no background launches of Reminders.app and no Full Disk Access required. Pinyin keywords are cached in the extension’s data directory.

The first time you open **My Reminders**, it shows **Allow Access to Your Reminders** — press Return and allow Prism to access Reminders when macOS asks. If access was turned off earlier, it offers **Open Privacy Settings** to take you directly to **System Settings → Privacy & Security → Reminders**.

Requires Apple Reminders on macOS and Prism 0.12.1 or later. Capabilities: none (access is managed directly by macOS Reminders permission).
