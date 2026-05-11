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
  registered projects with id labels like `[0] Missional AI Summit`.
  `res finder clear` removes only pins recorded in the managed state file.
- `shell/res.zsh` — a small zsh integration that provides:
  - `res init <name>` — create a project, then `cd` into the new project root.
  - `res cd <id|name>` — `cd` into a project's root (requires a shell function).
  - `res search on|off` — toggle `TAVILY_ENABLED` in the current shell.
  - `res <anything else>` — resolves the Readwise token (env → chezmoi →
    Bitwarden), and delegates to `res.sh` (only **exports** a token if one was
    found, so the plugin `data.json` fallback still works when Bitwarden has no
    custom field set).
- `tavily_wrapper.sh` — Tavily search helper used by the Gemini CLI plugin.

## Project Removal

Use `unregister` to remove a project from the registry and Finder pins while
leaving its directory alone:

```sh
res unregister 1
res unregister -f 1
```

Use `delete` to remove the project directory and unregister it:

```sh
res delete 1
res delete -f 1
```

Both commands default to the registered project whose directory is the current
directory or one of its parents. If you are not inside a registered project, they
print help instead. New projects use the next available project id above the
current maximum, so unregistering a project does not cause id reuse. When run
through `shell/res.zsh`, both commands show a `tree` preview before the
confirmation prompt, using the same `tree` command configured in your zsh
startup.

## Project Retrospective

Use `ledger` while a project is active to create a reviewable source ledger
without marking the project done:

```sh
res ledger
res sources 1
res ledger --no-llm 1
```

The ledger writes a compact LLM-first control file under
`reports/YYYY-MM-DD_Source_Ledger.md`: a short attention queue plus YAML for
source roles, weights, symlink status, review flags, and actions. Early on, scan
only the attention queue. Once the classifications are consistently right, you
can let future LLM runs consume the YAML directly and use `res finish` as the
final closure step.

Use `finish`, `done`, or `retro` to create the final retrospective note for a
project after the ledger is stable:

```sh
res finish
res done 1
res retro --model gpt-5-mini 1
res finish --no-llm 1
```

The command defaults to the registered project whose directory is the current
directory or one of its parents. It writes a retro note and the prompt/context
used to generate it under the project's `reports/` folder. By default it uses
`RES_RETRO_LLM_CMD` if set, otherwise the model from `RES_RETRO_LLM_MODEL` or
`OPENAI_EVERYDAY_MODEL`, then the `llm` CLI, then `gemini`; `--no-llm` only
writes the prompt and placeholder note.

Suggested transition:

1. Run `res ledger` and review every role/weight manually.
2. Rerun `res ledger` after source changes and compare the new draft.
3. When the ledger is trustworthy, use it as the project source-of-truth and run
   `res finish` only when you want a final retrospective.
4. Later, automate more aggressively by trusting low-risk ledger updates and only
   reviewing the attention queue or files marked `needs_review: true`.

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
