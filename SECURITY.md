# Security

This is a Windows helper. Most pages stay on disk. The dashboard quota strip is the only network call.

## What it reads

- `~\.grok\sessions\<encoded-cwd>\<session-id>\summary.json`
  - working directory (`info.cwd`)
  - generated title / session summary
  - timestamps
- The Watch page also reads local `grok.exe` process IDs, working directories, `updates.jsonl` timestamps, and `signals.json` context usage. It does not read chat transcripts.
- The Dashboard sums `usage.json` token totals (shown in millions) and timestamps.
- Account quota on the home page reads `~\.grok\auth.json` **in memory** to call `cli-chat-proxy.grok.com/v1/billing`. Tokens are never written to this repo, the quota cache, or the error log.

It does **not** open `chat_history.jsonl` or `system_prompt.txt`.

## What it writes

Preferences (pinned folders, “hide missing”) go to:

```
%APPDATA%\GrokRecentLauncher\config.json
```

Quota numbers (percent used, reset time, plan label — never tokens) go to `quota-cache.json` in the same folder.

Crash traces go to `last-error.log` in the same folder. Both stay on the machine. They are gitignored if a copy ever appears next to the scripts.

## What not to publish

Do not commit:

- `config.json` (may contain your local project paths)
- `last-error.log`
- desktop `.lnk` files
- anything under `~\.grok\` (sessions, credentials, API-related files)

This repository must only contain the launcher scripts and docs.

## Reporting issues

Open a GitHub issue. Do not attach session logs, `auth.json`, `.env`, or API keys.
