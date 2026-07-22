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

echo "Finder pin tests passed"
