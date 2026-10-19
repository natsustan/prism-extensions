# GitHub

Your GitHub notifications, pull requests, issues, and repositories in the
launcher, on GitHub.com or GitHub Enterprise Server. Every row opens its page
on GitHub; the extension only reads and never changes anything there.

- **GitHub Notifications** lists your unread notifications, newest first,
  with why you got each one (Review Requested, Mentioned, …). ⌘P switches to
  All, which adds the read ones below.
- **My Pull Requests** groups open pull requests as GitHub does: Created,
  Review Requests, Assigned, Mentioned, Reviewed, and those closed in the last
  14 days. A pull request in several groups shows only in the first. ⌘P shows
  one group. Typing searches every pull request you took part in, or only the
  chosen group.
- **My Issues** does the same for issues: Created, Assigned, Mentioned, and
  those closed in the last 60 days.
- **GitHub Repositories** lists the repositories you own, collaborate on, or
  reach through an organization, most recently updated first, and narrows them
  as you type. ⌘P switches to Starred, or to All of GitHub, which searches every
  repository on the server.
- Return opens the page in your browser. The action panel (⌘K) copies its URL
  (⌘⇧C) or its title or name (⌘⇧T).
- With GitHub Desktop selected in root search, Tab opens these lists too.

## Setup

If you use the [GitHub CLI](https://cli.github.com) and have run
`gh auth login`, there is nothing to set up: with no token in preferences, the
extension asks `gh auth token` for that login and follows `gh auth login`,
`gh auth switch`, and `gh auth logout` on the next load. When `gh` is installed but signed out, each list shows
**Sign In with GitHub CLI** with the command to run.

Otherwise, use a **classic** personal access token; GitHub does not share
notifications with fine-grained tokens. Each list shows **Add a GitHub Token**:
press Return to open GitHub's page for a new token with the scopes filled in
(`repo`, `read:org`, `notifications`), create it, and paste it in
Settings → Extensions → GitHub. Prism keeps it in the Keychain and sends it only
to the server below. A token in preferences comes before the `gh` login.

For GitHub Enterprise Server, set **Server** to its address
(`https://github.example.com`); the API is read from `/api/v3` there, and the
`gh` login for that host is used (`gh auth login --hostname github.example.com`).

## Requests

Lists ask GitHub's REST API each time they open, and keep the answers while
the extension runs: searches for a minute, since GitHub allows 30 searches a
minute and My Pull Requests alone runs six, and repository lists for five
minutes. Notifications are always asked again. When GitHub can't be reached or
the rate limit is hit, the list keeps its last rows and says why; a rejected
token clears them.

Capabilities: `network` (GitHub's API) and `spawnProcesses` (`gh auth token`,
when no token is set).

The extension's icon is GitHub's mark on a graphite tile. Rows draw their
state with GitHub's own [Octicons](https://primer.style/octicons) (MIT,
`icons/octicons/LICENSE`) in GitHub's colors: green open, gray draft or not
planned, purple merged or completed, red closed; notifications are blue while
unread.
