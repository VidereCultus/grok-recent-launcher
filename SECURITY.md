# Security

This is a **local-only** Windows helper. It does not talk to the network.

## What it reads

- `~\.grok\sessions\<encoded-cwd>\<session-id>\summary.json`
  - working directory (`info.cwd`)
  - generated title / session summary
  - timestamps

It does **not** open `chat_history.jsonl`, `updates.jsonl`, `system_prompt.txt`, auth files, or `~\.grok\auth.json`.

## What it writes

Preferences (pinned folders, “hide missing”) go to:

```
%APPDATA%\GrokRecentLauncher\config.json
```

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
