# 1Password

Your 1Password items in the launcher, through the 1Password CLI and its
desktop app integration: find an item, paste its password or one-time
password, or open it in 1Password. The extension only reads; edits happen in
1Password.

- **Search 1Password** lists the items of every account, most recently changed first, with each
  login's username and the vault it is in; favorites carry a star. Typing
  matches titles, usernames, vaults, categories, websites, and tags. ⌘P shows
  favorites, one category (Logins, Passwords, Secure Notes, …), or one vault.
  With several accounts, items are grouped by account.
- On a login, Return pastes the password into the app you opened Prism over
  (⌘⌥V), and ⌘⌥C copies it. ⌘⇧C copies the username and ⌘⇧V pastes it,
  ⌃⌘C copies the one-time password and ⌃⌘V pastes it, ⌘O opens the website,
  and ⌘⇧O opens the item in 1Password. These follow Raycast's 1Password
  extension, except ⌘O, since Prism's shortcuts need ⌘ or ⌃. Other items
  open in 1Password on Return.
- **Generate Password** shows new passwords: random ones of 20 and 32
  characters, 20 letters and digits, and a 6-digit PIN. Return pastes one,
  ⌘⇧C copies it, and ⌘R makes new ones. Letters and digits that look alike
  (l, I, O, 0, 1) are left out, except in the PIN.
- With 1Password selected in root search, Tab opens Search 1Password.

Passwords and one-time passwords are read from 1Password only when you paste
or copy one, never shown in the list. Prism marks them as concealed, so
clipboard managers, its own Clipboard History included, skip them, keeps
them off Universal Clipboard, and clears them from the clipboard after 90
seconds unless you copied something else since. Generated passwords are made
on your Mac from the system's secure random source and handled the same way.

## Setup

1. Install the [1Password CLI](https://developer.1password.com/docs/cli/get-started/)
   (`brew install 1password-cli`). Without it, the list offers the install
   guide and the Homebrew command.
2. In 1Password, choose Settings → Developer and turn on
   **Integrate with 1Password CLI**. Until then, the list says so.
3. Open Search 1Password. When the CLI has no session, as after 1Password
   locks, the list shows **Sign In**. It closes the launcher and asks the
   1Password app for a session (`op account get`, as Raycast's extension
   does); approve Prism in 1Password and the items appear.

Set **1Password CLI Path** when `op` is somewhere other than your `PATH`,
`/usr/local/bin`, or `/opt/homebrew/bin`. Turn off **Paste on Return** for
Return to copy a login's password instead.

With several accounts, Sign In asks 1Password for each in turn, and the list
shows the items of every account you allow.

Item lists are kept in memory for 30 seconds while the extension runs, so
reopening the list is instant, and never written to disk.

Needs Prism 0.1.1 or later, which keeps concealed text out of clipboard
histories. Capabilities: `spawnProcesses` (the `op` command, which talks to
the 1Password app).
