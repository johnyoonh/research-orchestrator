#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
FACADE="$REPO_DIR/scripts/readwise.sh"
TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/bin"
CLI_LOG="$TEST_ROOT/readwise-cli.log"
TRIAGE_LOG="$TEST_ROOT/triage.log"
PROCESSOR_LOG="$TEST_ROOT/processor.log"
WIKI_DIR="$TEST_ROOT/wiki"
BOOKS_DIR="$WIKI_DIR/90_media/books"
INBOX_DIR="$TEST_ROOT/inbox"
TOKEN_FILE="$TEST_ROOT/readwise-token"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$BOOKS_DIR" "$INBOX_DIR/epub"
printf 'test-token\n' > "$TOKEN_FILE"
: > "$CLI_LOG"
: > "$TRIAGE_LOG"
: > "$PROCESSOR_LOG"

cat > "$FAKE_BIN/readwise" <<'EOF_FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$READWISE_CLI_LOG"
if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF_HELP'
reader-search-documents
reader-get-document-details
reader-list-documents
readwise-search-highlights
readwise-get-daily-review
EOF_HELP
    exit 0
fi
if [[ "${1:-}" == "reader-list-documents" ]]; then
    printf '{"results":[]}\n'
fi
EOF_FAKE
chmod +x "$FAKE_BIN/readwise"

cat > "$FAKE_BIN/readwise-project" <<'EOF_FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TRIAGE_LOG"
EOF_FAKE
chmod +x "$FAKE_BIN/readwise-project"

cat > "$FAKE_BIN/process_book_inbox.py" <<'EOF_FAKE'
#!/usr/bin/env python3
import os
import sys
with open(os.environ["PROCESSOR_LOG"], "a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
EOF_FAKE
chmod +x "$FAKE_BIN/process_book_inbox.py"

cat > "$FAKE_BIN/curl" <<'EOF_FAKE'
#!/usr/bin/env bash
set -euo pipefail
headers=""
output=""
url=""
while (($#)); do
    case "$1" in
        -D|-o|-H|--connect-timeout|--max-time)
            if [[ "$1" == "-D" ]]; then headers=$2; fi
            if [[ "$1" == "-o" ]]; then output=$2; fi
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            url=$1
            shift
            ;;
    esac
done

case "$url" in
    *'/api/v3/list/?id=doc-original&withRawSourceUrl=true')
        printf '%s\n' '{"results":[{"id":"doc-original","title":"Recovered Book","author":"Test Author","category":"pdf","raw_source_url":"https://download.invalid/recovered"}]}'
        ;;
    *'/api/v3/list/?id=doc-invalid&withRawSourceUrl=true')
        printf '%s\n' '{"results":[{"id":"doc-invalid","title":"Invalid Book","author":"Test Author","category":"pdf","raw_source_url":"https://download.invalid/invalid"}]}'
        ;;
    'https://download.invalid/recovered')
        printf 'content-type: application/pdf\r\n' > "$headers"
        printf '%%PDF-1.7\nmock book\n' > "$output"
        ;;
    'https://download.invalid/invalid')
        printf 'content-type: application/pdf\r\n' > "$headers"
        printf 'not a pdf\n' > "$output"
        ;;
    *)
        echo "Unexpected curl URL: $url" >&2
        exit 2
        ;;
esac
EOF_FAKE
chmod +x "$FAKE_BIN/curl"

run_facade() {
    PATH="$FAKE_BIN:$PATH" \
    READWISE_CLI_BIN="$FAKE_BIN/readwise" \
    READWISE_CLI_LOG="$CLI_LOG" \
    READWISE_PROJECT_BIN="$FAKE_BIN/readwise-project" \
    TRIAGE_LOG="$TRIAGE_LOG" \
    READWISE_BOOK_PROCESSOR="$FAKE_BIN/process_book_inbox.py" \
    PROCESSOR_LOG="$PROCESSOR_LOG" \
    WIKI_PATH="$WIKI_DIR" \
    READWISE_BOOKS_DIR="$BOOKS_DIR" \
    READWISE_BOOK_INBOX="$INBOX_DIR" \
    READWISE_TOKEN_FILE="$TOKEN_FILE" \
    bash "$FACADE" "$@"
}

assert_last_line() {
    local file=$1 expected=$2 actual
    actual=$(tail -n 1 "$file")
    if [[ "$actual" != "$expected" ]]; then
        echo "Expected last line in $file:" >&2
        echo "  $expected" >&2
        echo "Actual:" >&2
        echo "  $actual" >&2
        exit 1
    fi
}

help_output=$(run_facade help)
grep -q 'Cloud commands' <<<"$help_output"
grep -q 'download <url-or-id>' <<<"$help_output"

capabilities=$(run_facade capabilities --json)
python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["schema_version"] == 1; assert any(c["id"] == "knowledge.readwise.download" for c in data["capabilities"])' <<<"$capabilities"

: > "$CLI_LOG"
run_facade search 'aggregation theory' --limit 3 >/dev/null
assert_last_line "$CLI_LOG" 'reader-search-documents --query aggregation theory --limit 3'

run_facade highlights compounding >/dev/null
assert_last_line "$CLI_LOG" 'readwise-search-highlights --vector-search-term compounding'

run_facade inbox 7 >/dev/null
assert_last_line "$CLI_LOG" 'reader-list-documents --location new --limit 7'

run_facade read doc-123 >/dev/null
assert_last_line "$CLI_LOG" 'reader-get-document-details --document-id doc-123'

run_facade save https://example.com/article >/dev/null
assert_last_line "$CLI_LOG" 'reader-create-document --url https://example.com/article'

before=$(wc -l < "$CLI_LOG" | tr -d ' ')
preview=$(run_facade move 'doc-1,doc-2' archive)
after=$(wc -l < "$CLI_LOG" | tr -d ' ')
[[ "$before" == "$after" ]] || { echo 'Move preview unexpectedly invoked the CLI' >&2; exit 1; }
grep -q 'Preview only' <<<"$preview"
grep -Eq -- '--document-ids doc-1(\\,|,)doc-2 --location archive' <<<"$preview"

run_facade move 'doc-1,doc-2' archive --apply >/dev/null
assert_last_line "$CLI_LOG" 'reader-move-documents --document-ids doc-1,doc-2 --location archive'

run_facade review >/dev/null
assert_last_line "$CLI_LOG" 'readwise-get-daily-review'

: > "$TRIAGE_LOG"
run_facade triage --limit 5 --format json >/dev/null
assert_last_line "$TRIAGE_LOG" '--limit 5 --format json'

legacy_stderr="$TEST_ROOT/legacy.stderr"
run_facade --limit 4 >/dev/null 2>"$legacy_stderr"
assert_last_line "$TRIAGE_LOG" '--limit 4'
grep -q "treating it as 'res readwise triage'" "$legacy_stderr"

commands=$(run_facade commands search)
grep -q 'reader-search-documents' <<<"$commands"

doctor_json=$(run_facade doctor --json)
python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["official_cli"]["found"] is True; assert data["local"]["triage"] is True; assert data["api_token_available"] is True' <<<"$doctor_json"

download_json=$(run_facade download doc-original --output-dir "$BOOKS_DIR" --json)
download_path=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])' <<<"$download_json")
[[ -f "$download_path" ]] || { echo 'Download did not create the recovered book' >&2; exit 1; }
[[ $(head -c 5 "$download_path") == '%PDF-' ]] || { echo 'Recovered book failed PDF header validation' >&2; exit 1; }
[[ "$download_json" != *'test-token'* && "$download_json" != *'download.invalid'* ]] || {
    echo 'Download output leaked a token or temporary URL' >&2
    exit 1
}

if run_facade download doc-invalid --output-dir "$BOOKS_DIR" >/dev/null 2>&1; then
    echo 'Invalid PDF download unexpectedly succeeded' >&2
    exit 1
fi
[[ ! -e "$BOOKS_DIR/Invalid Book - Test Author.pdf" ]] || {
    echo 'Invalid PDF was moved into the book library before validation' >&2
    exit 1
}

source_book="$TEST_ROOT/Example Book.epub"
printf 'not-a-real-epub-for-dispatch-test' > "$source_book"
upload_preview=$(run_facade upload "$source_book")
grep -q 'Dry run: no files changed' <<<"$upload_preview"
[[ ! -e "$INBOX_DIR/epub/Example Book.epub" ]] || { echo 'Upload dry run created a file' >&2; exit 1; }

run_facade upload "$source_book" --apply --no-upload >/dev/null
[[ -f "$INBOX_DIR/epub/Example Book.epub" ]] || { echo 'Upload apply did not stage the book' >&2; exit 1; }
assert_last_line "$PROCESSOR_LOG" "--file $INBOX_DIR/epub/Example Book.epub --apply --no-upload"

: > "$PROCESSOR_LOG"
run_facade route "$INBOX_DIR/epub/Example Book.epub" --apply --no-upload >/dev/null
assert_last_line "$PROCESSOR_LOG" "--apply --file $INBOX_DIR/epub/Example Book.epub --no-upload"

if run_facade route "$source_book" --apply >/dev/null 2>&1; then
    echo 'Route accepted a file outside the managed inbox' >&2
    exit 1
fi

if run_facade move doc-1 invalid-location --apply >/dev/null 2>&1; then
    echo 'Move accepted an invalid Reader location' >&2
    exit 1
fi

echo 'Readwise facade tests passed'
