usage() {
    cat <<'USAGE'
Usage: res readwise <command> [args]
       res reader <command> [args]
       res rw <command> [args]

Cloud commands (official Readwise CLI):
  search <query> [options]              Search Reader documents
  highlights <query> [options]          Search Readwise highlights
  inbox [limit] [options]               List documents in Reader's new location
  read <document-id> [options]          Return a Reader document as Markdown
  save <url> [options]                  Save a URL to Reader
  move <ids> <location> [--apply]       Preview or move documents
  review [options]                      Get today's Daily Review

Local extensions:
  triage [options]                      Run vault-aware Reader triage
  download <url-or-id> [options]        Recover an original EPUB/PDF into the vault
  upload <file> [--apply]               Stage and process a local book
  route [file] [--apply|--review]       Preview or apply book-inbox routing

Discovery and diagnostics:
  commands [term]                       Show/filter official CLI commands
  capabilities [--json]                Print the agent routing contract
  doctor [--json] [--online]            Check local dependencies and optional auth
  help [command]                        Show facade help

Compatibility:
  Legacy flag-only calls such as `res rw --limit 10` still run `triage` and
  print a migration hint. Advanced vendor commands remain available directly
  through `readwise --help`.
USAGE
}

command_help() {
    case "${1:-}" in
        search)
            cat <<'EOF_HELP'
Usage: res readwise search <query> [official-options]

Delegates to:
  readwise reader-search-documents --query <query>
EOF_HELP
            ;;
        highlights)
            cat <<'EOF_HELP'
Usage: res readwise highlights <query> [official-options]

Delegates to:
  readwise readwise-search-highlights --vector-search-term <query>
EOF_HELP
            ;;
        inbox)
            cat <<'EOF_HELP'
Usage: res readwise inbox [limit] [official-options]

Delegates to:
  readwise reader-list-documents --location new [--limit N]
EOF_HELP
            ;;
        read)
            cat <<'EOF_HELP'
Usage: res readwise read <document-id> [official-options]

Delegates to:
  readwise reader-get-document-details --document-id <id>
EOF_HELP
            ;;
        save)
            cat <<'EOF_HELP'
Usage: res readwise save <url> [official-options]

Delegates to:
  readwise reader-create-document --url <url>
EOF_HELP
            ;;
        move)
            cat <<'EOF_HELP'
Usage: res readwise move <id[,id...]> <new|later|shortlist|archive> [--apply] [official-options]

Without --apply, prints the exact official CLI command and makes no change.
EOF_HELP
            ;;
        triage)
            cat <<'EOF_HELP'
Usage: res readwise triage [readwise-project-options]

Runs the existing vault-aware readwise-project workflow.
EOF_HELP
            ;;
        download)
            cat <<'EOF_HELP'
Usage: res readwise download <reader-url-or-document-id>
                              [--output-dir DIR | --output FILE]
                              [--force] [--json]

Uses Reader API v3 only to resolve the temporary original-file URL. The URL and
access token are never printed. Existing files are not overwritten unless
--force is supplied.
EOF_HELP
            ;;
        upload)
            cat <<'EOF_HELP'
Usage: res readwise upload <epub|pdf|mobi|azw3> [--apply] [processor-options]

Dry-run by default. With --apply, copies the source into the repository's book
inbox and invokes process_book_inbox.py for the staged copy.
EOF_HELP
            ;;
        route)
            cat <<'EOF_HELP'
Usage: res readwise route [staged-file] [--apply|--review] [processor-options]

Runs process_book_inbox.py. A selected file must already be inside the managed
book inbox; use `upload` to stage an external file.
EOF_HELP
            ;;
        doctor)
            cat <<'EOF_HELP'
Usage: res readwise doctor [--json] [--online]

Default checks are local-only. --online adds a read-only Reader list probe to
verify official CLI authentication.
EOF_HELP
            ;;
        capabilities)
            cat <<'EOF_HELP'
Usage: res readwise capabilities [--json]

Prints stable capability identifiers and the preferred agent routing order.
EOF_HELP
            ;;
        ""|help)
            usage
            ;;
        *)
            echo "No facade-specific help for: $1" >&2
            echo "Use: readwise --help" >&2
            return 1
            ;;
    esac
}

capabilities_json() {
    cat <<'EOF_JSON'
{
  "schema_version": 1,
  "service": "readwise",
  "facade": "res readwise",
  "routing": [
    {
      "context": "conversational_agent",
      "preferred_interface": "official_readwise_mcp",
      "endpoint": "https://mcp2.readwise.io/mcp"
    },
    {
      "context": "terminal_agent",
      "preferred_interface": "official_readwise_cli",
      "command": "readwise"
    },
    {
      "context": "vault_or_original_file_workflow",
      "preferred_interface": "research_orchestrator_facade",
      "command": "res readwise"
    }
  ],
  "capabilities": [
    {"id": "knowledge.readwise.search", "command": "res readwise search", "mutates": false, "owner": "official_cli"},
    {"id": "knowledge.readwise.highlights.search", "command": "res readwise highlights", "mutates": false, "owner": "official_cli"},
    {"id": "knowledge.readwise.read", "command": "res readwise read", "mutates": false, "owner": "official_cli"},
    {"id": "knowledge.readwise.review", "command": "res readwise review", "mutates": false, "owner": "official_cli"},
    {"id": "knowledge.readwise.save", "command": "res readwise save", "mutates": true, "owner": "official_cli"},
    {"id": "knowledge.readwise.move", "command": "res readwise move", "mutates": true, "requires_apply": true, "owner": "official_cli"},
    {"id": "knowledge.readwise.triage", "command": "res readwise triage", "mutates": false, "owner": "local"},
    {"id": "knowledge.readwise.download", "command": "res readwise download", "mutates": true, "owner": "local"},
    {"id": "knowledge.readwise.upload", "command": "res readwise upload", "mutates": true, "requires_apply": true, "owner": "local"},
    {"id": "knowledge.readwise.route", "command": "res readwise route", "mutates": true, "requires_apply": true, "owner": "local"}
  ]
}
EOF_JSON
}

capabilities_human() {
    cat <<'EOF_CAP'
Agent routing order:
  1. Conversational app: official Readwise MCP at https://mcp2.readwise.io/mcp
  2. Terminal agent: official `readwise` CLI for normal cloud operations
  3. `res readwise`: vault triage, original-file recovery, local upload/routing

Stable local capability identifiers:
  knowledge.readwise.search
  knowledge.readwise.highlights.search
  knowledge.readwise.read
  knowledge.readwise.review
  knowledge.readwise.save
  knowledge.readwise.move
  knowledge.readwise.triage
  knowledge.readwise.download
  knowledge.readwise.upload
  knowledge.readwise.route
EOF_CAP
}
