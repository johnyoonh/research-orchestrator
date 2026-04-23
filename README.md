# PhD Research Orchestrator

A CLI tool for organizing PhD research assets, auto-routing PDFs, and syncing Readwise highlights.

## Install

Add this block to your `~/.zshrc`:

```zsh
# PhD Research Workflow
export PATH="$PATH:/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki/99_meta/scripts"
[ -f "$HOME/repos/research-orchestrator/shell/res.zsh" ] \
    && source "$HOME/repos/research-orchestrator/shell/res.zsh"
```

## Layout

- `res.sh` — the main dispatcher (`init`, `add`, `ln`, `mv`, `repair`, `finalize`, …).
  Honors non-empty `$READWISE_TOKEN` and `$WIKI_PATH` from the environment; if
  `$READWISE_TOKEN` is unset, falls back to the Obsidian Readwise plugin’s
  `data.json` (a blank env var is treated the same as unset, so a failed
  Bitwarden/chezmoi lookup does *not* block the plugin file).
- For Readwise *Reader* URLs (`readwise.io/reader/document_raw_content/...` in
  note front-matter, or `read.readwise.io/read/...`), `res` does not download
  that URL with `Authorization: Token` (Readwise returns 401). It calls the
  Reader v3 `list` API to obtain a time-limited S3 `raw_source_url` for the
  underlying PDF, then downloads that. Requires `curl` and `jq` on `PATH`.
- `shell/res.zsh` — a small zsh integration that provides:
  - `res cd <id|name>` — `cd` into a project's root (requires a shell function).
  - `res search on|off` — toggle `TAVILY_ENABLED` in the current shell.
  - `res <anything else>` — resolves the Readwise token (env → chezmoi →
    Bitwarden), and delegates to `res.sh` (only **exports** a token if one was
    found, so the plugin `data.json` fallback still works when Bitwarden has no
    custom field set).
- `tavily_wrapper.sh` — Tavily search helper used by the Gemini CLI plugin.

## Readwise token resolution

The zsh wrapper tries, in order:

1. `$READWISE_TOKEN` already in the environment.
2. `chezmoi execute-template '{{ .readwise_token }}'` (then `.secrets.readwise_token`).
3. Bitwarden (`bw get item readwise`) — only if `bw` is unlocked.

If none of those produce a token, `res.sh` still falls back to the Obsidian
Readwise plugin's `data.json`.

To override for a single command:

```sh
READWISE_TOKEN=abc123 res add <url>
```
