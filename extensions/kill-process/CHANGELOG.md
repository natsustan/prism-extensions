# Changelog

## 1.0.0

- Kill Process lists running apps and processes in a full-width list showing both CPU and memory usage, with ⌘P sorting between CPU Usage and Memory Usage.
- Groups each app bundle’s helper processes under the app by default, with ⇧⌘G to toggle between grouped apps and individual processes.
- Kill, Force Kill, Restart, Force Restart, Kill All, and Force Kill All confirm before signalling and verify process identity (PID and start time) so stale rows never hit reused PIDs.
- Show in Finder and a Copy submenu (path, PID, and `sudo kill` commands for other users’ processes).
- Full Simplified Chinese and Traditional Chinese translations for the manifest, filters, actions, confirmations, and messages.
