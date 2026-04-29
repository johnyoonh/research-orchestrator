# PhD Research Orchestrator

A CLI tool for organizing PhD research assets, auto-routing PDFs, and syncing Readwise highlights.

## Install

Install the macOS command dependencies:

```sh
brew bundle --file "$HOME/repos/research-orchestrator/Brewfile"
```

Add this block to your `~/.zshrc`:

```zsh
# PhD Research Workflow
export PATH="$PATH:/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki/99_meta/scripts"
[ -f "$HOME/repos/research-orchestrator/shell/res.zsh" ] \
    && source "$HOME/repos/research-orchestrator/shell/res.zsh"
```

## Layout

- `res.sh` — the main dispatcher (`init`, `add`, `ln`, `unlink`, `relink`, `mv`, `repair`, `finalize`, …).
  Honors non-empty `$READWISE_TOKEN` and `$WIKI_PATH` from the environment; if
  `$READWISE_TOKEN` is unset, falls back to the Obsidian Readwise plugin’s
  `data.json` (a blank env var is treated the same as unset, so a failed
  Bitwarden/chezmoi lookup does *not* block the plugin file).
- For Readwise *Reader* URLs (`readwise.io/reader/document_raw_content/...` in
  note front-matter, or `read.readwise.io/read/...`), `res` does not download
  that URL with `Authorization: Token` (Readwise returns 401). It calls the
  Reader v3 `list` API to obtain a time-limited S3 `raw_source_url` for the
  underlying PDF, then downloads that. Requires `curl` and `jq` on `PATH`.
- Finder project pins are managed with `mysides`. Use `res finder sync` to pin
  registered projects with wiki/index labels like `📚 ⓪ Missional AI Summit`.
  `res finder clear` removes only pins recorded in the managed state file.
- `shell/res.zsh` — a small zsh integration that provides:
  - `res cd <id|name>` — `cd` into a project's root (requires a shell function).
  - `res search on|off` — toggle `TAVILY_ENABLED` in the current shell.
  - `res <anything else>` — resolves the Readwise token (env → chezmoi →
    Bitwarden), and delegates to `res.sh` (only **exports** a token if one was
    found, so the plugin `data.json` fallback still works when Bitwarden has no
    custom field set).
- `tavily_wrapper.sh` — Tavily search helper used by the Gemini CLI plugin.

## Source Links

Use `ln` to attach an existing wiki file to a project's `sources` folder:

```sh
res ln 1 swbts-application
```

Use `unlink` to remove a source link from a project without deleting or moving the
original file:

```sh
res unlink 0 swbts-application
```

Use `relink` / `rl` to make a project keep a source link, cleaning up matching
links from other projects when needed:

```sh
res rl 1 swbts-application
```

You can also give both source and destination projects for a precise relink:

```sh
res rl 0 1 swbts-application
```

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

## Reader triage

Use `readwise-project` to fetch recent Reader documents, detect whether they
have already synced into the Obsidian vault, count synced highlights, and emit
candidate area/project suggestions based on the vault's `.keywords` files and
project registry.

Examples:

```sh
./readwise-project --limit 10
./readwise-project --limit 10 --seen true --format tsv
./readwise-project --limit 20 --location new
./readwise-project --limit 10 --source-url-contains docs.google.com --unsynced-only
./readwise-project --limit 10 --source-url-contains docs.google.com --unsynced-only --interactive-route
```

The default output is JSON with fields like:

- `synced_to_wiki`
- `synced_note_path`
- `has_highlights`
- `highlight_count`
- `suggestions`

Interactive Google Docs routing:

- Only shows documents that are not already synced into `90_media/readwise`
  and are not previously routed/excluded.
- Prompts for a project id/name, `skip`, `exclude`, or `quit`.
- Saves routed markdown notes into the selected project's `sources/`.
- Persists triage state under `99_meta/readwise_triage/`.
