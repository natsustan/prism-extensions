# Kill Process

Finds running apps and processes on your Mac by CPU or memory usage, and kills or restarts them.

- **Kill Process** lists running processes in a full-width list with each item’s CPU and memory usage, grouping each app bundle’s helpers under the app by default. Type a process name, app name, helper name, PID, or path to filter the list, and use ⌘P to switch between CPU Usage and Memory Usage. Return kills the selected process or app group after confirmation (`SIGTERM`); ⌘K offers Force Kill (`⇧⌘⌫`, `SIGKILL`), Restart (`⌥⌘R`) and Force Restart (`⌥⇧⌘R`) for apps and preference panes, Kill All (`⌥⌘⌫`) and Force Kill All (`⌥⇧⌘⌫`) when multiple processes you own share a name, Show in Finder (`⇧⌘F`), a Copy submenu for Path (`⇧⌘C`) and PID, plus Toggle App Grouping (`⇧⌘G`).

Before sending any signal, Kill Process re-reads the process table and verifies that the PID still belongs to the same process start time so a stale row never stops another program, and never signals itself or `launchd` (PID 1). Processes owned by other users such as `root` can’t be killed from Prism; their Copy submenu offers Copy Kill Command (`⇧⌘D`, `sudo kill <PID>`) and Copy Force Kill Command (`sudo kill -9 <PID>`) to run in Terminal.

## Setup

Open Settings → Extensions → Kill Process to toggle **Close After Kill** (close the launcher with a HUD confirmation instead of keeping the list open).

Needs nothing beyond macOS. Capabilities: `spawnProcesses` (runs `/bin/ps` for live CPU and memory snapshots, `/usr/bin/open` to relaunch apps, and `/usr/bin/open -R` to show a program in Finder), `inspectProcesses` (reads process identities and start times via `sysctl` and `libproc`, and signals the processes you choose to kill or restart). Nothing leaves your Mac.
