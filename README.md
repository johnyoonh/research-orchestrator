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
  Honors `$READWISE_TOKEN` and `$WIKI_PATH` from the environment.
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
  - `res <anything else>` — delegates to `res.sh`.
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

## Readwise token

Set `READWISE_TOKEN` before running commands that call the Readwise API:

```sh
READWISE_TOKEN=abc123 res add <url>
```

## Book Download Automation

Downloaded books are cleaned and moved by `scripts/ingest_books.py` from
`~/Downloads` into the Obsidian book library:

```sh
/Users/john/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/wiki/90_media/books
```

To override the library destination for one run:

```sh
BOOK_INGEST_LIBRARY_DIR=/path/to/books scripts/ingest_books.py
```

To use the older staging workflow, send downloads to `inbox/<ext>/` explicitly:

```sh
BOOK_INGEST_DESTINATION=inbox scripts/ingest_books.py
```

When staging to the inbox, print a proposed route for each newly staged book
without moving/uploading it with:

```sh
BOOK_INGEST_DESTINATION=inbox BOOK_INGEST_AUTO_TRIAGE=plan scripts/ingest_books.py
```

To review and confirm each proposed route in one manual run, use:

```sh
BOOK_INGEST_DESTINATION=inbox BOOK_INGEST_AUTO_TRIAGE=ask scripts/ingest_books.py
```

To review books already in the inbox with an approval menu:

```sh
scripts/process_book_inbox.py --review
```

The zsh integration also runs that review automatically whenever you `cd` into
the EPUB inbox:

```sh
cd ~/repos/research-orchestrator/inbox/epub
```

To route each newly staged book immediately after it lands in the inbox, run:

```sh
BOOK_INGEST_DESTINATION=inbox BOOK_INGEST_AUTO_TRIAGE=1 scripts/ingest_books.py
```

Auto-triage uses `scripts/process_book_inbox.py --file <staged-book>`. It adds
`--apply` when `BOOK_INGEST_AUTO_TRIAGE` is `1`, `true`, `yes`, or `apply`; it
prompts first when the value is `ask` or `confirm`:

- obvious seminary books move to `50_faith/seminary/<course>/assets/books/`
- obvious stale/duplicate books move to `inbox/quarantine/YYYY-MM-DD-low-value-or-duplicates/`
- remaining EPUB/PDF books upload to Readwise and then move to `inbox/uploaded-to-readwise/YYYY-MM-DD/`

When `--review` is run from `inbox/epub`, `inbox/pdf`, `inbox/mobi`, or
`inbox/azw3`, it reviews that directory. Otherwise it reviews all supported
inbox directories. The menu supports approve all, select by number/range,
one-by-one approval, refresh, and cancel.

To print or apply proposed actions without the interactive menu:

```sh
scripts/process_book_inbox.py
scripts/process_book_inbox.py --apply
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
