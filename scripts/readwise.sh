#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

WIKI_PATH="${WIKI_PATH:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki}"
READWISE_BOOKS_DIR="${READWISE_BOOKS_DIR:-$WIKI_PATH/90_media/books}"
READWISE_BOOK_INBOX="${READWISE_BOOK_INBOX:-$REPO_DIR/inbox}"
READWISE_TOKEN_FILE="${READWISE_TOKEN_FILE:-$HOME/.config/readwise/api-token}"
READWISE_PROJECT_BIN="${READWISE_PROJECT_BIN:-$REPO_DIR/readwise-project}"
READWISE_BOOK_PROCESSOR="${READWISE_BOOK_PROCESSOR:-$SCRIPT_DIR/process_book_inbox.py}"
READWISE_CLI_BIN="${READWISE_CLI_BIN:-}"

# shellcheck source=scripts/lib/readwise_help.sh
source "$SCRIPT_DIR/lib/readwise_help.sh"
# shellcheck source=scripts/lib/readwise_common.sh
source "$SCRIPT_DIR/lib/readwise_common.sh"
# shellcheck source=scripts/lib/readwise_local.sh
source "$SCRIPT_DIR/lib/readwise_local.sh"
# shellcheck source=scripts/lib/readwise_dispatch.sh
source "$SCRIPT_DIR/lib/readwise_dispatch.sh"

main "$@"
