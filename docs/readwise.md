# Readwise command architecture

`res readwise` is the small, stable command surface for this repository. It does not reimplement the official Readwise tooling. Normal cloud operations delegate to the official CLI; repository-specific operations remain local.

## Which interface to use

| Context | Preferred interface | Reason |
|---|---|---|
| ChatGPT or another conversational agent with the official integration | Official Readwise MCP | Structured tool discovery and hosted authentication |
| Codex or another terminal agent | Official `readwise` CLI | JSON-friendly scripts, pipes, and deterministic command execution |
| Obsidian triage, original-file recovery, or local book routing | `res readwise` | These workflows depend on this repository and the local vault |

The combined official MCP endpoint is `https://mcp2.readwise.io/mcp`. The local facade intentionally contains only high-frequency delegates and repository-specific extensions.

## Canonical commands

```text
res readwise search <query>
res readwise highlights <query>
res readwise inbox [limit]
res readwise read <document-id>
res readwise save <url>
res readwise move <ids> <new|later|shortlist|archive> [--apply]
res readwise review

res readwise triage [options]
res readwise download <url-or-id> [options]
res readwise upload <file> [--apply]
res readwise route [file] [--apply|--review]

res readwise commands [term]
res readwise capabilities [--json]
res readwise doctor [--json] [--online]
```

`move`, `upload`, and `route` default to a preview. `save` and `download` execute because the command itself names one explicit object. The facade does not expose deletion.

## Local extensions

`triage` delegates to `readwise-project` and preserves its existing vault-aware project suggestions and interactive routing.

`download` resolves a Reader document through API v3, obtains the temporary original-file URL without printing it, validates supported PDF/EPUB downloads, and saves the file under `90_media/books` by default. Set `READWISE_BOOKS_DIR` or pass `--output-dir` to change the destination.

`upload` is a dry run unless `--apply` is present. Applying it copies the source into the repository book inbox and invokes `scripts/process_book_inbox.py` for the staged copy. `route` runs the same processor for files already in that managed inbox.

## Discovery for agents

`commands.toml` is the static capability registry. `res readwise capabilities --json` exposes the same stable identifiers at runtime. Agents should select interfaces in this order:

1. Official MCP in a connected conversational application.
2. Official CLI in a terminal.
3. Local facade for vault or original-file workflows.

The repository skill at `skills/readwise-local/SKILL.md` defines the routing and safety contract.

## Migration

The `readwise`, `reader`, and `rw` aliases are supported by the sourced zsh integration. Existing flag-only calls, such as `res rw --limit 10`, continue to run the legacy triage workflow and emit a migration hint. The shorter `r` alias remains compatible but is intentionally omitted from examples because it is ambiguous.

For direct use without the sourced zsh function:

```sh
bash scripts/readwise.sh capabilities --json
bash scripts/readwise.sh triage --limit 10
```

Authentication and installation remain owned by the official tooling. The repository does not install the CLI, register MCP servers, or change account settings.
