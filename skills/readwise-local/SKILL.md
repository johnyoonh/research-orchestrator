---
name: readwise-local
description: Route Readwise and Reader work between the official MCP, official CLI, and research-orchestrator local workflows.
---

# Readwise local routing

Use this skill when a request involves Readwise highlights, Reader documents, the Daily Review, local book imports, original EPUB/PDF recovery, or Obsidian-aware triage.

## Interface selection

1. In a conversational application with the official Readwise integration, use the official combined Readwise + Reader MCP server for normal cloud reads and writes.
2. In a terminal agent, use the official `readwise` CLI for normal cloud operations and structured output.
3. Use `res readwise` only for the repository's local extensions: vault-aware triage, original-file recovery, local upload, and book routing.
4. When only the facade script is available, invoke `bash scripts/readwise.sh ...` with the same arguments.

Do not reproduce the official Readwise command catalog in prompts. Use `readwise --help`, `res readwise commands [term]`, or `res readwise capabilities --json` for discovery. The stable capability registry is `commands.toml`.

## Safety

- Search, read, inbox, Daily Review, capabilities, commands, and local triage may run directly.
- `move`, `upload`, and `route` are previews unless `--apply` is explicit.
- `save` and `download` are single-object actions and execute when explicitly requested.
- Never expose `READWISE_TOKEN`, the token file contents, or a temporary `raw_source_url`.
- Do not delete documents through this facade. Use an official interface only after the user explicitly requests deletion and the selected documents are unambiguous.
- Keep official CLI/plugin behavior authoritative. Local code should not duplicate the full vendor API.

## Common commands

```sh
res readwise search "agent memory"
res readwise highlights "retrieval evaluation"
res readwise inbox 20
res readwise read <document-id>
res readwise review

res readwise triage --limit 20 --unsynced-only
res readwise download <reader-url-or-document-id>
res readwise upload /path/to/book.epub
res readwise upload /path/to/book.epub --apply
res readwise route
res readwise route --apply

res readwise doctor --json
res readwise capabilities --json
```

Legacy calls such as `res rw --limit 10` remain compatible and are interpreted as `res readwise triage --limit 10`. Prefer `readwise`, or `rw` when brevity matters; do not introduce new uses of the ambiguous `r` alias.
