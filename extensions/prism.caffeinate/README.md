# Caffeinate

Keeps your Mac awake from the launcher, a hotkey, or a widget, using the
`caffeinate` tool that ships with macOS.

- **Caffeinate** keeps the display and the system awake (`caffeinate -d -i`,
  plus `-m` with Prevent Disk Sleep on).
- **Decaffeinate** stops every `caffeinate` process you own, including ones
  started outside Prism.
- **Toggle Caffeinate** and the **Keep Awake** widget switch between the two.
- **Caffeinate Status** shows Caffeinated or Decaffeinated live in the launcher.

Prism starts `caffeinate` as a host task, so it keeps running after this
extension stops and after Prism quits. Turning the extension off or
uninstalling it ends the task.

Needs nothing beyond macOS. Capabilities: `hostTasks` (Prism runs
`/usr/bin/caffeinate`), `inspectProcesses` (finds running `caffeinate`
processes to show their state and stop them).
