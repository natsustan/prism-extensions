# Agent Usage

Quotas for your AI coding agents in the Prism launcher and in widgets:
Codex, Claude, Grok, Amp, Antigravity, Devin, and Z.ai.

- **Agent Usage** lists each agent with its primary quota as a ring and the
  time until it resets. The detail shows every window, per-model limits, and
  credits. Return refreshes; ⌘⇧C copies a plain-text summary.
- **Widgets** show the first one or two agents as numbers, rings, or bars.
- **Settings**: choose and order the agents (those already signed in on this
  Mac are on by default and marked Configured), switch between remaining and
  used quota, and optionally paste a Z.ai API key.

Agent Usage reads the logins each agent's own CLI or app already saved; it
never signs in for you. Usage is fetched when you open the list or a widget
appears, at most once a minute per agent, and the last results are kept in
Prism's data folder for this extension so they show at once next time.

| Agent | Reads | Sends to |
| --- | --- | --- |
| Codex | `~/.codex/auth.json`, `~/.config/codex/auth.json`, or `CODEX_HOME` | chatgpt.com |
| Claude | Claude Code's login in the Keychain, or `~/.claude/.credentials.json` | api.anthropic.com |
| Grok | `~/.grok/auth.json` | cli-chat-proxy.grok.com, auth.x.ai |
| Amp | `~/.local/share/amp/secrets.json` | ampcode.com |
| Antigravity | the running language server (`ps`, `lsof`), or its saved Google login under `~/.gemini` | localhost, Google (Cloud Code, OAuth) |
| Devin | `~/.local/share/devin/credentials.toml`, or the Devin app's saved login | server.codeium.com |
| Z.ai | the key from settings, `ZAI_API_KEY`, `~/.config/zai/key.json`, or a Claude Code token pointed at z.ai | api.z.ai |

Capabilities: `network`, `readHomeFiles`, `keychainRead` (Claude Code's
login), `spawnProcesses` (`ps` and `lsof` to find Antigravity). The first
Keychain read asks for permission.

## Development

```sh
swift test                      # 218 tests, stub providers, no network
bash ../../tools/check.sh .     # build, test, lint, smoke
```

`smoke` loads the list and widgets once, which reads your real logins and
fetches usage like the app would.
