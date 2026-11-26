# Screen Sharing

Quickly connect to Macs on your local network, pinned machines, or saved hosts using macOS’s built-in Screen Sharing app.

- **Search Screen** discovers nearby Macs advertising Screen Sharing (`_rfb._tcp.`) over Bonjour and merges them with your pinned, saved, and recently connected hosts. Filter between All, Pinned, Local Network, and Recent with ⌘P.
- Type any IP address, `.local` hostname, `user@host:port`, or `vnc://` URL into the search field to connect directly without configuring it first.
- Return opens the host in Screen Sharing (`vnc://…`) and records it in Recent. The action panel (⌘K) pins or unpins hosts (⌘⇧P), copies the `vnc://` link (⌘⇧C), copies the address (⌘⇧A), removes a recent entry (⌘⌫), or refreshes the local network scan (⌘R).
- Screen Sharing’s own row in root search offers the list too: select Screen Sharing and press Tab to pick a Mac right away; Backspace in the empty search returns to Screen Sharing.
- Add Tailscale, VPN, or cross-subnet hosts under **Saved Hosts** in extension settings using `Name = host[:port]` or plain addresses, separated by commas or new lines.

Credentials stay in macOS Keychain—choose “Remember this password in my keychain” the first time Screen Sharing asks, and future connections sign in automatically.

Capabilities: `network` (discovers Macs on your local network via Bonjour `_rfb._tcp.` and `_device-info._tcp.`).
