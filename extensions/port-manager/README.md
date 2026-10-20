# Port Manager

Shows which programs listen on which TCP ports, how far each port reaches,
and kills the process behind one.

- **Open Ports** lists every process that listens on a TCP port, one row per
  process, with its ports beside it. Each port’s color says how far it
  reaches: green for this Mac only, orange for every network interface (so
  other devices too), blue for the one address it is bound to; hover a port
  to see its addresses. Type a port, a process, an address, or part of a
  command line to find it. Return kills the process after you confirm; ⌘K
  also force kills it (⌘⇧⌫), kills the process that started it, such as
  `npm` for its `node`, opens a port in your browser (⌘O for the first),
  shows the program in Finder (⌘⇧F), or copies its PID (⌘⇧C) or command line
  (⌘⇧L). ⌘P shows only localhost, network, or single-interface ports. The
  detail pane shows the command line, every address, the process’s owner and
  parent, and when it started.

A kill asks the process to quit (`SIGTERM`) and reports it killed only once
it has gone; one that keeps running can be force killed (`SIGKILL`). Before
signalling, Port Manager checks that the port is still open and the PID still
belongs to the same process, so a stale row never stops something else.
Processes of other users, such as root’s, are listed with their owner but
can’t be killed from Prism.

## Setup

To name the ports you use often, open Settings → Extensions → Port Manager and
fill in **Port Names**, such as `3000 Web, 5432 Postgres`.

Needs nothing beyond macOS. Capabilities: `spawnProcesses` (runs
`/usr/sbin/netstat` to see every user’s ports, and `open -R` to show a program
in Finder), `inspectProcesses` (reads each process’s name, owner, and command
line, and signals the ones you kill). Nothing leaves your Mac.
