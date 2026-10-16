#!/bin/bash
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
WIKI_DIR="$TEST_ROOT/wiki"
FAKE_BIN="$TEST_ROOT/bin"
SIDEBAR_STATE="$TEST_ROOT/sidebar.tsv"
REGISTRY="$WIKI_DIR/99_meta/.project_registry"
PIN_STATE="$WIKI_DIR/99_meta/.finder_project_pins"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$WIKI_DIR/99_meta" "$WIKI_DIR/projects/sample-claim" "$WIKI_DIR/projects/second-project"
: > "$SIDEBAR_STATE"

cat > "$FAKE_BIN/mysides" <<'EOF'
#!/bin/bash
set -eu

COMMAND=${1:-}
LABEL=${2:-}

case "$COMMAND" in
    add)
        printf '%s\t%s\n' "$LABEL" "$3" >> "$MYSIDES_STATE"
        ;;
    remove)
        if [[ "${MYSIDES_REMOVE_ERROR_LABEL:-}" == "$LABEL" ]]; then
            exit 2
        fi
        TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/mysides-state.XXXXXX")
        if awk -F '\t' -v label="$LABEL" '
            $1 == label && !removed { removed=1; next }
            { print }
            END { exit removed ? 0 : 1 }
        ' "$MYSIDES_STATE" > "$TEMP_FILE"; then
            mv "$TEMP_FILE" "$MYSIDES_STATE"
        else
            rm -f "$TEMP_FILE"
            exit 1
        fi
        ;;
    list)
        awk -F '\t' '{ print $1 " -> " $2 }' "$MYSIDES_STATE"
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$FAKE_BIN/mysides"

run_res() {
    PATH="$FAKE_BIN:$PATH" WIKI_PATH="$WIKI_DIR" MYSIDES_STATE="$SIDEBAR_STATE" \
        "$REPO_DIR/res.sh" finder "$@"
}

count_label() {
    local LABEL=$1
    awk -F '\t' -v label="$LABEL" '$1 == label { count++ } END { print count + 0 }' "$SIDEBAR_STATE"
}

assert_label_count() {
    local LABEL=$1 EXPECTED=$2 ACTUAL
    ACTUAL=$(count_label "$LABEL")
    if [[ "$ACTUAL" != "$EXPECTED" ]]; then
        echo "Expected $EXPECTED sidebar entries for '$LABEL', found $ACTUAL" >&2
        exit 1
    fi
}

LABEL_ONE='[1] sample claim'
LABEL_TWO='[2] second project'
STALE_LABEL='[9] stale project'
MANUAL_LABEL='Manual Favorite'

printf '1:sample_claim:%s\n2:second_project:%s\n' \
    "$WIKI_DIR/projects/sample-claim" "$WIKI_DIR/projects/second-project" > "$REGISTRY"
printf '%s\tfile:///sample\n%s\tfile:///sample\n%s\tfile:///sample\n' \
    "$LABEL_ONE" "$LABEL_ONE" "$LABEL_ONE" > "$SIDEBAR_STATE"
printf '%s\tfile:///stale\n%s\tfile:///stale\n%s\tfile:///manual\n' \
    "$STALE_LABEL" "$STALE_LABEL" "$MANUAL_LABEL" >> "$SIDEBAR_STATE"
printf '%s\t%s\n%s\t%s\n' \
    "$LABEL_ONE" "$WIKI_DIR/projects/sample-claim" \
    "$STALE_LABEL" "$WIKI_DIR/projects/stale-project" > "$PIN_STATE"

run_res sync >/dev/null
assert_label_count "$LABEL_ONE" 1
assert_label_count "$LABEL_TWO" 1
assert_label_count "$STALE_LABEL" 0
assert_label_count "$MANUAL_LABEL" 1

run_res sync >/dev/null
assert_label_count "$LABEL_ONE" 1
assert_label_count "$LABEL_TWO" 1
assert_label_count "$MANUAL_LABEL" 1

rm -f "$PIN_STATE"
printf '%s\tfile:///sample\n%s\tfile:///sample\n%s\tfile:///manual\n' \
    "$LABEL_ONE" "$LABEL_ONE" "$MANUAL_LABEL" > "$SIDEBAR_STATE"
run_res sync >/dev/null
assert_label_count "$LABEL_ONE" 1
assert_label_count "$MANUAL_LABEL" 1

printf '%s\tfile:///sample\n%s\tfile:///sample\n%s\tfile:///sample\n%s\tfile:///manual\n' \
    "$LABEL_ONE" "$LABEL_ONE" "$LABEL_ONE" "$MANUAL_LABEL" > "$SIDEBAR_STATE"
printf '%s\t%s\n' "$LABEL_ONE" "$WIKI_DIR/projects/sample-claim" > "$PIN_STATE"
run_res clear >/dev/null
assert_label_count "$LABEL_ONE" 0
assert_label_count "$MANUAL_LABEL" 1
[[ ! -s "$PIN_STATE" ]] || { echo "Expected Finder pin state to be empty after clear" >&2; exit 1; }

printf '%s\tfile:///sample\n' "$LABEL_ONE" > "$SIDEBAR_STATE"
printf '%s\t%s\n' "$LABEL_ONE" "$WIKI_DIR/projects/sample-claim" > "$PIN_STATE"
if PATH="$FAKE_BIN:$PATH" WIKI_PATH="$WIKI_DIR" MYSIDES_STATE="$SIDEBAR_STATE" \
    MYSIDES_REMOVE_ERROR_LABEL="$LABEL_ONE" "$REPO_DIR/res.sh" finder sync >/dev/null 2>&1; then
    echo "Expected sync to fail when mysides removal fails" >&2
    exit 1
fi
assert_label_count "$LABEL_ONE" 1

mv "$REGISTRY" "${REGISTRY}.saved"
mkdir "$REGISTRY"
if run_res sync >/dev/null 2>&1; then
    echo "Expected sync to fail when the project registry cannot be read" >&2
    exit 1
fi
assert_label_count "$LABEL_ONE" 1
rmdir "$REGISTRY"
mv "${REGISTRY}.saved" "$REGISTRY"

# --- Test top-3 registered wiki project cap & focused project priority ---
printf '%s\tfile:///manual\n' "$MANUAL_LABEL" > "$SIDEBAR_STATE"
mkdir -p \
    "$WIKI_DIR/projects/p1/inbox" \
    "$WIKI_DIR/projects/p2/inbox" \
    "$WIKI_DIR/projects/p3/inbox" \
    "$WIKI_DIR/projects/p4/inbox" \
    "$WIKI_DIR/projects/p5/inbox"
cat > "$REGISTRY" <<EOF
1:proj_one:$WIKI_DIR/projects/p1
2:proj_two:$WIKI_DIR/projects/p2
3:proj_three:$WIKI_DIR/projects/p3
4:proj_four:$WIKI_DIR/projects/p4
5:proj_five:$WIKI_DIR/projects/p5
EOF

run_res sync >/dev/null
assert_label_count "[1] proj one" 0
assert_label_count "[2] proj two" 0
assert_label_count "[3] proj three" 1
assert_label_count "[4] proj four" 1
assert_label_count "[5] proj five" 1

# Focusing project 1 should promote it into the 3 project slots alongside 4 and 5
ln -sfn "$WIKI_DIR/projects/p1/inbox" "$WIKI_DIR/99_meta/Active_Inbox"
run_res sync >/dev/null
assert_label_count "[1] proj one" 1
assert_label_count "[3] proj three" 0
assert_label_count "[4] proj four" 1
assert_label_count "[5] proj five" 1

# --- Test dynamic ranking (created dirs + zoxide + Finder recents + ChatGPT routes) ---
FAKE_REPOS="$TEST_ROOT/repos"
mkdir -p \
    "$FAKE_REPOS/brand-new-tool" \
    "$FAKE_REPOS/frequent-alpha/subdir" \
    "$FAKE_REPOS/chatgpt-matched" \
    "$FAKE_REPOS/finder-favorite"

cat > "$FAKE_BIN/zoxide" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "query" && "\${2:-}" == "-ls" ]]; then
    printf "150.0 %s\n" "$FAKE_REPOS/frequent-alpha/subdir"
    printf "40.0 %s\n" "$FAKE_REPOS/chatgpt-matched"
fi
EOF
chmod +x "$FAKE_BIN/zoxide"

RECENTS_FILE="$TEST_ROOT/finder-recents.txt"
printf '%s\n' "$FAKE_REPOS/finder-favorite" > "$RECENTS_FILE"

ROUTES_FILE="$TEST_ROOT/chat-shortcut-routes.json"
cat > "$ROUTES_FILE" <<'EOF'
{
  "project_lookup": {
    "chatgpt_matched": {
      "name": "chatgpt-matched",
      "url": "https://chatgpt.com/g/g-p-123456/project"
    }
  }
}
EOF

# Set now_ts slightly above current time so newly created dirs fall inside the 14d window,
# and limit created_slots=1, frequent_slots=2 to test deterministic selection.
NOW_TS=$(python3 -c 'import time; print(int(time.time()) + 60)')
PATH="$FAKE_BIN:$PATH" \
    WIKI_PATH="$WIKI_DIR" \
    MYSIDES_STATE="$SIDEBAR_STATE" \
    RES_FINDER_ROOTS="$FAKE_REPOS" \
    RES_FINDER_ZOXIDE_BIN="$FAKE_BIN/zoxide" \
    RES_FINDER_RECENTS_FILE="$RECENTS_FILE" \
    RES_FINDER_CHATGPT_ROUTES="$ROUTES_FILE" \
    RES_FINDER_CREATED_SLOTS=1 \
    RES_FINDER_FREQUENT_SLOTS=2 \
    RES_FINDER_NOW="$NOW_TS" \
    "$REPO_DIR/res.sh" finder sync >/dev/null

# brand-new-tool is alphabetically first among identically-timestamped new dirs
assert_label_count "🆕 brand-new-tool" 1
assert_label_count "⚡ frequent-alpha" 1
assert_label_count "⚡ chatgpt-matched" 1

# Verify preview command outputs expected entries
PREVIEW_OUT=$(
    PATH="$FAKE_BIN:$PATH" \
        WIKI_PATH="$WIKI_DIR" \
        MYSIDES_STATE="$SIDEBAR_STATE" \
        RES_FINDER_ROOTS="$FAKE_REPOS" \
        RES_FINDER_ZOXIDE_BIN="$FAKE_BIN/zoxide" \
        RES_FINDER_RECENTS_FILE="$RECENTS_FILE" \
        RES_FINDER_CHATGPT_ROUTES="$ROUTES_FILE" \
        RES_FINDER_CREATED_SLOTS=1 \
        RES_FINDER_FREQUENT_SLOTS=2 \
        RES_FINDER_NOW="$NOW_TS" \
        "$REPO_DIR/res.sh" finder preview
)
echo "$PREVIEW_OUT" | grep -q "🆕 brand-new-tool" || { echo "Missing created dir in preview" >&2; exit 1; }
echo "$PREVIEW_OUT" | grep -q "⚡ chatgpt-matched" || { echo "Missing chatgpt dir in preview" >&2; exit 1; }

# Verify clear removes both project pins and dynamic pins while preserving manual pin
run_res clear >/dev/null
assert_label_count "🆕 brand-new-tool" 0
assert_label_count "⚡ frequent-alpha" 0
assert_label_count "⚡ chatgpt-matched" 0
assert_label_count "[1] proj one" 0
assert_label_count "$MANUAL_LABEL" 1

echo "Finder pin tests passed"
