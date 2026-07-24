#!/bin/bash
# V22 PhD Research Orchestrator (Force Download & Path Transparency)

WIKI_PATH="${WIKI_PATH:-/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki}"
REGISTRY="$WIKI_PATH/99_meta/.project_registry"
URL_LOG="$WIKI_PATH/99_meta/.downloaded_urls"
ACTIVE_INBOX="$WIKI_PATH/99_meta/Active_Inbox"
DEFAULT_INBOX="$WIKI_PATH/00_inbox/documents"
FINDER_PIN_STATE="$WIKI_PATH/99_meta/.finder_project_pins"

# Readwise API access uses the standard READWISE_TOKEN environment variable.
READWISE_TOKEN="${READWISE_TOKEN:-}"

touch "$REGISTRY" "$URL_LOG"

print_res_help() {
    cat <<'EOF'
Usage: res <command> [args]

Commands:
  add|ad|a [id] <file|url> [dest]
  init|i <name>
  list|ls|l
  path <id>
  focus|f|fo <id|default>
  move|mv|m [id] <file> <dest>
  unlink|unln|ul [id] <name>
  link|ln [-f] [id] <name>
  relink|rl [-f] ...
  unregister|unreg [-f] [id|name]
  delete|del|rm [-f] [id|name]
  repair|rp [project-id]
  readwise|reader|rw|r ...
  finder|pins <sync|clear|list>
  ledger|sources [--no-llm] [--model <model>] [id|name]
  finish|done|retro [--no-llm] [--model <model>] [id|name]
  finalize|fi|pub [id] <dest>

Examples:
  res r --limit 10 --source-url-contains docs.google.com --unsynced-only --interactive-route
  res rp 0
  res ln 1 some-note
EOF
}

print_repair_help() {
    cat <<'EOF'
Usage: res repair [project-id]
       res rp [project-id]

Repair broken symlinks under a project's `sources/` directory by searching the
wiki for a file with the same basename and relinking it.
EOF
}

print_add_help() {
    cat <<'EOF'
Usage: res add [project-id] <file|url> [dest]
       res ad  [project-id] <file|url> [dest]
       res a   [project-id] <file|url> [dest]

Add a local file or URL into a project. When `dest` is `project`, keep the file
under the project's own permanent folder; otherwise it is auto-routed.
EOF
}

print_init_help() {
    cat <<'EOF'
Usage: res init <project-name>
       res i    <project-name>

Initialize a new project directory, register it, and focus the active inbox on it.
EOF
}

print_list_help() {
    cat <<'EOF'
Usage: res list
       res ls
       res l

List registered projects.
EOF
}

print_path_help() {
    cat <<'EOF'
Usage: res path <project-id>

Print the absolute path for a registered project.
EOF
}

print_focus_help() {
    cat <<'EOF'
Usage: res focus <project-id|default>
       res f     <project-id|default>
       res fo    <project-id|default>

Point the active inbox symlink at a project's inbox, or reset to the default inbox.
EOF
}

print_finder_help() {
    cat <<'EOF'
Usage: res finder sync
       res finder clear
       res finder list
       res pins   sync|clear|list

Sync Finder sidebar pins from the project registry using `mysides`.
Managed pins use bracketed project ids.
Only managed pins are removed.
EOF
}

print_move_help() {
    cat <<'EOF'
Usage: res move [project-id] <file> <dest>
       res mv   [project-id] <file> <dest>
       res m    [project-id] <file> <dest>

Move a linked project source to another wiki destination and refresh the symlink.
EOF
}

print_unlink_help() {
    cat <<'EOF'
Usage: res unlink [project-id] <source-name>
       res unln  [project-id] <source-name>
       res ul    [project-id] <source-name>

Remove a source symlink from a project without deleting the original file.
EOF
}

print_link_help() {
    cat <<'EOF'
Usage: res link [-f] [project-id] <source-name>
       res ln   [-f] [project-id] <source-name>

Link an existing wiki file into a project's `sources/` folder. `-f` forces URL re-add.
EOF
}

print_relink_help() {
    cat <<'EOF'
Usage:
  res relink [-f] <to-project-id> <source-name>
  res relink [-f] <from-project-id> <to-project-id> <source-name>
  res relink [-f] --all <to-project-id> <source-name>
  res rl     [-f] ...

Reassign source link ownership between projects, optionally removing matching links
from every other project with `--all`.
EOF
}

print_unregister_help() {
    cat <<'EOF'
Usage: res unregister [-f] [project-id|project-name]
       res unreg      [-f] [project-id|project-name]

Remove a project from the registry and Finder pins, but leave its directory alone.
When no project is provided, defaults to the project containing the current directory.
Requires confirmation unless `-f` is used.
EOF
}

print_delete_help() {
    cat <<'EOF'
Usage: res delete [-f] [project-id|project-name]
       res del    [-f] [project-id|project-name]
       res rm     [-f] [project-id|project-name]

Delete a project directory, remove it from the registry, and refresh Finder pins.
When no project is provided, defaults to the project containing the current directory.
Requires confirmation unless `-f` is used.
EOF
}

print_finish_help() {
    cat <<'EOF'
Usage: res finish [--no-llm] [--model <model>] [project-id|project-name]
       res done   [--no-llm] [--model <model>] [project-id|project-name]
       res retro  [--no-llm] [--model <model>] [project-id|project-name]

Create a final project retrospective note. Defaults to the project containing
the current directory when no project is provided.

The command writes:
  - reports/YYYY-MM-DD_Project_Retro.md
  - reports/YYYY-MM-DD_Project_Retro_Prompt.md

LLM selection:
  - Uses RES_RETRO_LLM_CMD when set. The prompt is sent on stdin.
  - Otherwise uses RES_RETRO_LLM_MODEL, then OPENAI_EVERYDAY_MODEL, as the model.
  - Uses `llm prompt --no-stream` when available.
  - Falls back to `gemini -p` when available.
  - Use --no-llm to only create the prompt and placeholder note.
EOF
}

print_ledger_help() {
    cat <<'EOF'
Usage: res ledger  [--no-llm] [--model <model>] [project-id|project-name]
       res sources [--no-llm] [--model <model>] [project-id|project-name]

Create a reviewable source ledger draft without marking the project done.
Defaults to the registered project whose directory is the current directory or
one of its parents.

The command writes:
  - reports/YYYY-MM-DD_Source_Ledger.md
  - reports/YYYY-MM-DD_Source_Ledger_Prompt.md

Use this while a project is active to review source roles, weights, symlink
status, and cleanup decisions. After the ledger stabilizes, `res finish` can
create the final retrospective.
EOF
}

print_finalize_help() {
    cat <<'EOF'
Usage: res finalize [project-id] <dest>
       res fi       [project-id] <dest>
       res pub      [project-id] <dest>

Publish a project's master note and linked sources into a final note under `dest`.
EOF
}

sanitize_name() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]-]+/_/g' | sed -E 's/[^a-z0-9_]//g' | sed -E 's/_+/_/g'; }
get_project_path() { grep "^$1:" "$REGISTRY" | cut -d':' -f3; }
get_project_name() { grep "^$1:" "$REGISTRY" | cut -d':' -f2; }

next_project_id() {
    awk -F: 'NF >= 3 && $1 ~ /^[0-9]+$/ { if ($1 > max) max = $1 } END { print max + 1 }' "$REGISTRY"
}

get_project_id_by_name() {
    local KEY MATCHES COUNT
    KEY=$(sanitize_name "$1")
    MATCHES=$(awk -F: -v name="$KEY" '$2 == name { print $1 ":" $2 ":" $3 }' "$REGISTRY")
    [[ -n "$MATCHES" ]] || return 1

    COUNT=$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')
    if (( COUNT > 1 )); then
        echo "   ❌ Ambiguous project name: $1" >&2
        printf '%s\n' "$MATCHES" | sed 's/^/      /' >&2
        echo "      Use the numeric project id." >&2
        return 2
    fi

    printf '%s\n' "$MATCHES" | cut -d: -f1
}

path_is_in_project() {
    local CANDIDATE=$1 PROJECT_PATH=$2
    [[ "$CANDIDATE" == "$PROJECT_PATH" || "$CANDIDATE" == "$PROJECT_PATH"/* ]]
}

current_project_id() {
    local CWD_LOGICAL CWD_PHYSICAL BEST_ID="" BEST_LEN=0 id name path path_physical len
    CWD_LOGICAL="${PWD:-$(pwd)}"
    CWD_PHYSICAL=$(pwd -P)
    while IFS=: read -r id name path; do
        [[ -z "$id" || -z "$path" ]] && continue
        path_physical="$path"
        [[ -d "$path" ]] && path_physical=$(cd "$path" && pwd -P)
        if path_is_in_project "$CWD_LOGICAL" "$path" \
            || path_is_in_project "$CWD_PHYSICAL" "$path_physical" \
            || path_is_in_project "$CWD_PHYSICAL" "$path"; then
            len=${#path}
            if (( len > BEST_LEN )); then
                BEST_ID=$id
                BEST_LEN=$len
            fi
        fi
    done < "$REGISTRY"
    echo "$BEST_ID"
}

resolve_project_id() {
    local REF=$1 ID
    if [[ -z "$REF" ]]; then
        current_project_id
        return
    fi
    if [[ "$REF" =~ ^[0-9]+$ ]]; then
        echo "$REF"
        return
    fi
    get_project_id_by_name "$REF"
}

remove_project_from_registry() {
    local ID=$1 TMP
    TMP=$(mktemp)
    awk -F: -v id="$ID" '$1 != id' "$REGISTRY" > "$TMP" && mv "$TMP" "$REGISTRY"
}

reset_active_inbox_if_project() {
    local PROJ_PATH=$1 ACTIVE_TARGET
    ACTIVE_TARGET=$(readlink "$ACTIVE_INBOX" 2>/dev/null || true)
    if [[ "$ACTIVE_TARGET" == "$PROJ_PATH/inbox" ]]; then
        ln -sfn "$DEFAULT_INBOX" "$ACTIVE_INBOX"
    fi
}

confirm_project_action() {
    local FORCE=$1 ACTION=$2 ID=$3 NAME=$4 PROJ_PATH=$5 REPLY
    [[ "$FORCE" == "true" ]] && return 0
    if [[ ! -t 0 ]]; then
        echo "   ❌ Refusing to $ACTION without confirmation. Re-run with -f to force." >&2
        return 1
    fi
    echo "Project $ID: $NAME"
    echo "Path: $PROJ_PATH"
    read -r -p "Confirm $ACTION? [y/N] " REPLY
    [[ "$REPLY" == "y" || "$REPLY" == "Y" || "$REPLY" == "yes" || "$REPLY" == "YES" ]]
}

unregister_project() {
    local ID=$1 FORCE=$2 NAME PROJ_PATH
    NAME=$(get_project_name "$ID")
    PROJ_PATH=$(get_project_path "$ID")
    if [[ -z "$NAME" || -z "$PROJ_PATH" ]]; then
        echo "   ❌ Project not found: $ID" >&2
        return 1
    fi
    confirm_project_action "$FORCE" "unregister this project" "$ID" "$NAME" "$PROJ_PATH" || return 1
    remove_project_from_registry "$ID"
    reset_active_inbox_if_project "$PROJ_PATH"
    sync_finder_project_pins || true
    echo "✅ Unregistered project $ID: $NAME"
    echo "   Left directory in place: $PROJ_PATH"
}

delete_project() {
    local ID=$1 FORCE=$2 NAME PROJ_PATH
    NAME=$(get_project_name "$ID")
    PROJ_PATH=$(get_project_path "$ID")
    if [[ -z "$NAME" || -z "$PROJ_PATH" ]]; then
        echo "   ❌ Project not found: $ID" >&2
        return 1
    fi
    if [[ "$PROJ_PATH" != "$WIKI_PATH"/* || "$PROJ_PATH" != *"/projects/"* ]]; then
        echo "   ❌ Refusing to delete unexpected project path: $PROJ_PATH" >&2
        return 1
    fi
    confirm_project_action "$FORCE" "delete this project directory and unregister it" "$ID" "$NAME" "$PROJ_PATH" || return 1
    rm -rf "$PROJ_PATH"
    remove_project_from_registry "$ID"
    reset_active_inbox_if_project "$PROJ_PATH"
    sync_finder_project_pins || true
    echo "✅ Deleted project $ID: $NAME"
}

run_project_report() {
    local KIND=$1 ID=$2 MODEL=$3 NO_LLM=$4 NAME PROJ_PATH PYTHON_BIN SCRIPT ARGS=()
    NAME=$(get_project_name "$ID")
    PROJ_PATH=$(get_project_path "$ID")
    if [[ -z "$NAME" || -z "$PROJ_PATH" ]]; then
        echo "   ❌ Project not found: $ID" >&2
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v python3)
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v python)
    else
        echo "   ❌ Python is required to build the project report." >&2
        return 1
    fi

    SCRIPT="$HOME/repos/research-orchestrator/scripts/project_retro.py"
    [[ -f "$SCRIPT" ]] || SCRIPT="$(cd "$(dirname "$0")" && pwd)/scripts/project_retro.py"
    [[ -f "$SCRIPT" ]] || { echo "   ❌ Retro helper not found: scripts/project_retro.py" >&2; return 1; }

    [[ "$NO_LLM" == "true" ]] && ARGS+=(--no-llm)
    [[ -n "$MODEL" ]] && ARGS+=(--model "$MODEL")

    "$PYTHON_BIN" "$SCRIPT" \
        --kind "$KIND" \
        --project-id "$ID" \
        --project-name "$NAME" \
        --project-path "$PROJ_PATH" \
        "${ARGS[@]}"
}

finish_project() {
    run_project_report retro "$@"
}

ledger_project() {
    run_project_report ledger "$@"
}

finder_project_label() {
    local ID=$1; local NAME=$2
    local DISPLAY_NAME
    DISPLAY_NAME=$(echo "$NAME" | sed -E 's/_+/ /g')
    echo "[${ID}] ${DISPLAY_NAME}"
}

path_to_file_url() {
    local INPUT_PATH=$1
    local OUT="" CHAR HEX IDX
    local LC_ALL=C

    for ((IDX = 0; IDX < ${#INPUT_PATH}; IDX++)); do
        CHAR="${INPUT_PATH:IDX:1}"
        case "$CHAR" in
            [a-zA-Z0-9.~_/-]) OUT+="$CHAR" ;;
            *) printf -v HEX '%%%02X' "'$CHAR"; OUT+="$HEX" ;;
        esac
    done
    echo "file://$OUT"
}

require_mysides() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "   ⏩ Finder pins are only available on macOS."
        return 1
    fi
    if ! command -v mysides >/dev/null 2>&1; then
        echo "   ❌ \`mysides\` is required for Finder pins. Install with: brew bundle --file $HOME/repos/research-orchestrator/Brewfile" >&2
        return 1
    fi
}

remove_all_finder_pins_by_label() {
    local LABEL=$1
    local STATUS REMOVED=0
    local MAX_REMOVALS=100

    while ((REMOVED < MAX_REMOVALS)); do
        mysides remove "$LABEL" >/dev/null 2>&1
        STATUS=$?
        case "$STATUS" in
            0) ((REMOVED++)) ;;
            1) return 0 ;;
            *)
                echo "   Error: Failed to remove Finder pin '$LABEL' (mysides exit $STATUS)." >&2
                return "$STATUS"
                ;;
        esac
    done

    echo "   Error: Refusing to remove more than $MAX_REMOVALS Finder pins named '$LABEL'." >&2
    return 1
}

clear_finder_project_pins() {
    require_mysides || return 1
    [[ -f "$FINDER_PIN_STATE" ]] || { echo "📌 No managed Finder project pins to clear."; return 0; }

    local LABEL COUNT=0 STATUS
    local LABELS_FILE
    LABELS_FILE=$(mktemp "${TMPDIR:-/tmp}/res-finder-labels.XXXXXX") || return 1
    if ! awk -F '\t' 'NF && !seen[$1]++ { print $1 }' "$FINDER_PIN_STATE" > "$LABELS_FILE"; then
        echo "   Error: Failed to read Finder pin state: $FINDER_PIN_STATE" >&2
        rm -f "$LABELS_FILE"
        return 1
    fi

    while IFS= read -r LABEL; do
        [[ -z "$LABEL" ]] && continue
        remove_all_finder_pins_by_label "$LABEL"
        STATUS=$?
        if ((STATUS != 0)); then
            rm -f "$LABELS_FILE"
            return "$STATUS"
        fi
        ((COUNT++))
    done < "$LABELS_FILE"

    rm -f "$LABELS_FILE"
    if ! : > "$FINDER_PIN_STATE"; then
        echo "   Error: Failed to clear Finder pin state: $FINDER_PIN_STATE" >&2
        return 1
    fi
    echo "📌 Cleared Finder pins: $COUNT managed project(s)"
}

sync_finder_project_pins() {
    require_mysides || return 1
    mkdir -p "$(dirname "$FINDER_PIN_STATE")" || return 1
    if [[ ! -f "$REGISTRY" ]] || ! awk '{ next }' "$REGISTRY" >/dev/null; then
        echo "   Error: Failed to read project registry: $REGISTRY" >&2
        return 1
    fi

    local OWNED_LABELS CURRENT_PINS DEDUPED_PINS NEW_STATE
    OWNED_LABELS=$(mktemp "${TMPDIR:-/tmp}/res-finder-owned.XXXXXX") || return 1
    CURRENT_PINS=$(mktemp "${TMPDIR:-/tmp}/res-finder-current.XXXXXX") || {
        rm -f "$OWNED_LABELS"
        return 1
    }
    DEDUPED_PINS=$(mktemp "${TMPDIR:-/tmp}/res-finder-deduped.XXXXXX") || {
        rm -f "$OWNED_LABELS" "$CURRENT_PINS"
        return 1
    }
    NEW_STATE=$(mktemp "${FINDER_PIN_STATE}.tmp.XXXXXX") || {
        rm -f "$OWNED_LABELS" "$CURRENT_PINS" "$DEDUPED_PINS"
        return 1
    }

    if [[ -f "$FINDER_PIN_STATE" ]] \
        && ! awk -F '\t' 'NF { print $1 }' "$FINDER_PIN_STATE" >> "$OWNED_LABELS"; then
        echo "   Error: Failed to read Finder pin state: $FINDER_PIN_STATE" >&2
        rm -f "$OWNED_LABELS" "$CURRENT_PINS" "$DEDUPED_PINS" "$NEW_STATE"
        return 1
    fi

    local ID NAME PROJ_PATH LABEL COUNT=0 STATUS=0 REMOVE_STATUS
    while IFS=: read -r ID NAME PROJ_PATH; do
        [[ -z "$ID" || -z "$NAME" || -z "$PROJ_PATH" ]] && continue
        LABEL=$(finder_project_label "$ID" "$NAME")
        printf '%s\n' "$LABEL" >> "$OWNED_LABELS"
        [[ -d "$PROJ_PATH" ]] || continue
        printf '%s\t%s\n' "$LABEL" "$PROJ_PATH" >> "$CURRENT_PINS"
    done < "$REGISTRY"
    STATUS=$?
    if ((STATUS != 0)); then
        echo "   Error: Failed to read project registry: $REGISTRY" >&2
        rm -f "$OWNED_LABELS" "$CURRENT_PINS" "$DEDUPED_PINS" "$NEW_STATE"
        return "$STATUS"
    fi

    if ! awk 'NF && !seen[$0]++' "$OWNED_LABELS" > "${OWNED_LABELS}.unique" \
        || ! mv "${OWNED_LABELS}.unique" "$OWNED_LABELS" \
        || ! awk -F '\t' 'NF && !seen[$1]++' "$CURRENT_PINS" > "$DEDUPED_PINS"; then
        echo "   Error: Failed to prepare Finder pin reconciliation." >&2
        rm -f "$OWNED_LABELS" "${OWNED_LABELS}.unique" "$CURRENT_PINS" "$DEDUPED_PINS" "$NEW_STATE"
        return 1
    fi

    while IFS= read -r LABEL; do
        [[ -z "$LABEL" ]] && continue
        remove_all_finder_pins_by_label "$LABEL"
        REMOVE_STATUS=$?
        if ((REMOVE_STATUS != 0)); then
            rm -f "$OWNED_LABELS" "$CURRENT_PINS" "$DEDUPED_PINS" "$NEW_STATE"
            return "$REMOVE_STATUS"
        fi
    done < "$OWNED_LABELS"

    while IFS=$'\t' read -r LABEL PROJ_PATH; do
        [[ -z "$LABEL" || -z "$PROJ_PATH" ]] && continue
        if mysides add "$LABEL" "$(path_to_file_url "$PROJ_PATH")" >/dev/null; then
            printf '%s\t%s\n' "$LABEL" "$PROJ_PATH" >> "$NEW_STATE"
            ((COUNT++))
        else
            echo "   Error: Failed to add Finder pin '$LABEL'." >&2
            STATUS=1
        fi
    done < "$DEDUPED_PINS"

    if ! mv "$NEW_STATE" "$FINDER_PIN_STATE"; then
        echo "   Error: Failed to update Finder pin state: $FINDER_PIN_STATE" >&2
        rm -f "$OWNED_LABELS" "$CURRENT_PINS" "$DEDUPED_PINS" "$NEW_STATE"
        return 1
    fi
    rm -f "$OWNED_LABELS" "$CURRENT_PINS" "$DEDUPED_PINS"
    echo "📌 Synced Finder pins: $COUNT project(s)"
    return "$STATUS"
}

find_source_file() {
    local TARGET=$1
    local SRC_FILE

    # If TARGET is an existing file path, use it directly.
    if [[ -f "$TARGET" ]]; then
        echo "$TARGET"
        return 0
    fi

    SRC_FILE=$(find "$WIKI_PATH" -type f -iname "*${TARGET}*" -not -path "*/.*" -not -path "*/projects/*/sources/*" | head -n 1)
    [[ -z "$SRC_FILE" ]] && SRC_FILE=$(find "$WIKI_PATH" -iname "*${TARGET}*" -not -path "*/.*" | head -n 1)
    echo "$SRC_FILE"
}

find_project_source_link() {
    local ID=$1; local TARGET=$2
    local PROJ_PATH=$(get_project_path "$ID")
    local LINK TARGET_BASE

    TARGET_BASE=$(basename "$TARGET")
    for LINK in "$PROJ_PATH/sources/"*; do
        [[ -e "$LINK" || -L "$LINK" ]] || continue
        if [[ "$(basename "$LINK")" == "$TARGET_BASE" || "$(basename "$LINK")" == *"$TARGET_BASE"* ]]; then
            echo "$LINK"
            return 0
        fi
    done
    return 1
}

link_file_to_project() {
    local ID=$1; local SRC_FILE=$2
    local PROJ_PATH=$(get_project_path "$ID")

    if [[ -z "$PROJ_PATH" || ! -d "$PROJ_PATH/sources" ]]; then
        echo "   ❌ Project not found: $ID"
        return 1
    fi
    if [[ ! -f "$SRC_FILE" ]]; then
        echo "   ❌ Source file not found: $SRC_FILE"
        return 1
    fi

    ln -sf "$SRC_FILE" "$PROJ_PATH/sources/$(basename "$SRC_FILE")"
    echo "   + Linked: $(basename "$SRC_FILE")"
}

link_source() {
    local ID=$1; local TARGET=$2; local FORCE=$3
    local SRC_FILE URL

    if [[ -z "$TARGET" ]]; then
        echo "   ❌ Usage: res ln <project-id> <source-name>"
        return 1
    fi

    SRC_FILE=$(find_source_file "$TARGET")
    if [[ ! -f "$SRC_FILE" ]]; then
        echo "   ❌ Source not found: $TARGET"
        return 1
    fi

    link_file_to_project "$ID" "$SRC_FILE" || return 1
    if [[ "$SRC_FILE" == *.md ]]; then
        URL=$(grep -E "^url: |^- URL: " "$SRC_FILE" | head -n 1 | awk '{print $NF}' | tr -d '"' | tr -d "'")
        [[ -n "$URL" && "$URL" =~ ^https?:// ]] && smart_add_file "$ID" "$URL" "" "$FORCE"
    fi
}

unlink_source() {
    local ID=$1; local TARGET=$2
    local PROJ_PATH=$(get_project_path "$ID")

    if [[ -z "$PROJ_PATH" || ! -d "$PROJ_PATH/sources" ]]; then
        echo "   ❌ Project not found: $ID"
        return 1
    fi
    if [[ -z "$TARGET" ]]; then
        echo "   ❌ Usage: res unlink <project-id> <source-name>"
        return 1
    fi

    local MATCHED=false
    local LINK TARGET_BASE
    TARGET_BASE=$(basename "$TARGET")
    for LINK in "$PROJ_PATH/sources/"*; do
        [[ -e "$LINK" || -L "$LINK" ]] || continue
        if [[ "$(basename "$LINK")" == "$TARGET_BASE" || "$(basename "$LINK")" == *"$TARGET_BASE"* ]]; then
            MATCHED=true
            if [[ -L "$LINK" ]]; then
                local ORIGINAL
                ORIGINAL=$(readlink "$LINK")
                if rm "$LINK"; then
                    echo "   - Unlinked: $(basename "$LINK")"
                    echo "     Original kept: $ORIGINAL"
                else
                    echo "   ❌ Could not remove link: $LINK"
                    return 1
                fi
            else
                echo "   ⚠️  Not a symlink, left in place: $LINK"
            fi
        fi
    done

    if ! $MATCHED; then
        echo "   ❌ No source link matched: $TARGET"
        return 1
    fi
}

relink_source() {
    local FROM_ID=$1; local TO_ID=$2; local TARGET=$3; local FORCE=$4
    local LINK SRC_FILE

    if [[ -z "$TARGET" ]]; then
        echo "   ❌ Usage: res relink <from-project-id> <to-project-id> <source-name>"
        return 1
    fi

    LINK=$(find_project_source_link "$FROM_ID" "$TARGET") || {
        echo "   ❌ No source link matched in project $FROM_ID: $TARGET"
        return 1
    }

    if [[ -L "$LINK" ]]; then
        SRC_FILE=$(readlink "$LINK")
    else
        SRC_FILE="$LINK"
    fi

    link_file_to_project "$TO_ID" "$SRC_FILE" || return 1
    if [[ "$FROM_ID" != "$TO_ID" ]]; then
        unlink_source "$FROM_ID" "$(basename "$LINK")"
    fi
}

relink_source_all() {
    local TO_ID=$1; local TARGET=$2; local FORCE=$3
    local SRC_FILE id name path

    if [[ -z "$TARGET" ]]; then
        echo "   ❌ Usage: res relink --all <to-project-id> <source-name>"
        return 1
    fi

    SRC_FILE=$(find_source_file "$TARGET")
    if [[ ! -f "$SRC_FILE" ]]; then
        echo "   ❌ Source not found: $TARGET"
        return 1
    fi

    link_file_to_project "$TO_ID" "$SRC_FILE" || return 1
    while IFS=: read -r id name path; do
        [[ -z "$id" || "$id" == "$TO_ID" ]] && continue
        find_project_source_link "$id" "$TARGET" >/dev/null && unlink_source "$id" "$TARGET"
    done < "$REGISTRY"
}

route_directory() {
    local NAME=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    local BEST_DIR="00_inbox/documents"; local BEST_SCORE=0
    for KEY_FILE in "$WIKI_PATH"/*/.keywords; do
        if [[ -f "$KEY_FILE" ]]; then
            SCORE=0; for word in $(cat "$KEY_FILE"); do [[ "$NAME" == *"$word"* ]] && ((SCORE++)); done
            if (( SCORE > BEST_SCORE )); then BEST_SCORE=$SCORE; BEST_DIR=${KEY_FILE%/.keywords}; BEST_DIR=${BEST_DIR#$WIKI_PATH/}; fi
        fi
    done
    echo "$BEST_DIR"
}

project_parent_directory() {
    local ROUTED_DIR TOP_LEVEL_DIR
    ROUTED_DIR=$(route_directory "$1")
    TOP_LEVEL_DIR="${ROUTED_DIR%%/*}"
    [[ -n "$TOP_LEVEL_DIR" ]] || TOP_LEVEL_DIR="00_inbox"
    echo "$TOP_LEVEL_DIR"
}

# readwise.io/reader/document_raw_content/<num> and read.readwise.io/read/<ulid> are
# *not* downloadable with `curl -H "Authorization: Token …"` (they 401). The real
# file URL is a presigned S3 link from the Reader v3 `list` API (withRawSourceUrl=true).
rw_curl_list_json() {
    # GET https://readwise.io/api/v3/list/... — print response body to stdout on HTTP 2xx.
    # On failure sets _RW_LIST_HTTP, _RW_LIST_CURL_EXIT, _RW_LIST_CURL_ERR, _RW_LIST_ERRBODY.
    local api_url=$1
    _RW_LIST_HTTP=""
    _RW_LIST_CURL_EXIT=""
    _RW_LIST_CURL_ERR=""
    _RW_LIST_ERRBODY=""
    local tmp_out tmp_hdr tmp_code tmp_cerr http ce
    tmp_out=$(mktemp)
    tmp_hdr=$(mktemp)
    tmp_code=$(mktemp)
    tmp_cerr=$(mktemp)
    set +e
    curl -sS -L --connect-timeout 20 --max-time 120 \
        -D "$tmp_hdr" \
        -o "$tmp_out" \
        -w "%{http_code}" \
        -H "Authorization: Token $READWISE_TOKEN" -H "Accept: application/json" \
        "$api_url" >"$tmp_code" 2>"$tmp_cerr"
    ce=$?
    set -e
    _RW_LIST_CURL_EXIT=$ce
    _RW_LIST_CURL_ERR=$(head -c 1200 "$tmp_cerr" 2>/dev/null | tr '\r' ' ' | sed 's/  */ /g' || true)
    # Note: with `set -e`, a failed `tr` in $(...) can abort the function before
    # _RW_LIST_HTTP is assigned — so read the status file without a subshell.
    IFS= read -r http <"$tmp_code" 2>/dev/null || true
    http=${http//[^0-9]/}
    _RW_LIST_HTTP="${http:-}"

    if (( ce != 0 )); then
        _RW_LIST_HTTP="curl_exit_${ce}"
        _RW_LIST_ERRBODY="curl: $_RW_LIST_CURL_ERR"
        [[ -s "$tmp_out" ]] && _RW_LIST_ERRBODY+=$'\nresponse_start='"$(head -c 500 "$tmp_out" 2>/dev/null | tr '\n' ' ')"
        rm -f "$tmp_out" "$tmp_hdr" "$tmp_code" "$tmp_cerr"
        return 2
    fi

    if [[ -z "$http" || ! "$http" =~ ^[0-9][0-9][0-9]$ ]]; then
        _RW_LIST_HTTP="unknown"
        _RW_LIST_ERRBODY="Could not parse HTTP status from curl (-w). stderr: $_RW_LIST_CURL_ERR headers: $(head -c 200 "$tmp_hdr" 2>/dev/null | tr '\n' ' ')"
        rm -f "$tmp_out" "$tmp_hdr" "$tmp_code" "$tmp_cerr"
        return 2
    fi

    if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
        _RW_LIST_HTTP="$http"
        cat "$tmp_out"
        rm -f "$tmp_out" "$tmp_hdr" "$tmp_code" "$tmp_cerr"
        return 0
    fi

    _RW_LIST_HTTP="$http"
    _RW_LIST_ERRBODY=$(head -c 2000 "$tmp_out" 2>/dev/null || true)
    rm -f "$tmp_out" "$tmp_hdr" "$tmp_code" "$tmp_cerr"
    return 1
}

resolve_readwise_reader_download_url() {
    local target=$1
    if [[ -z "$READWISE_TOKEN" ]]; then
        echo "   ❌ No Readwise token. Set READWISE_TOKEN." >&2
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "   ❌ \`jq\` is required to resolve Readwise reader URLs. Install it (e.g. brew install jq)." >&2
        return 1
    fi

    local list_id="" raw_json dl_url enc
    if [[ "$target" =~ read\.readwise\.io/read/([0-9a-z]+) ]]; then
        list_id="${BASH_REMATCH[1]}"
    elif [[ "$target" =~ readwise\.io/reader/document_raw_content/([0-9]+) ]]; then
        local internal_id doc_id
        internal_id="${BASH_REMATCH[1]}"
        # Paginate the reader list until we find a document whose source_url
        # ends with the same /document_raw_content/<id> (works for 9k+ docs).
        local cursor="" page=0
        while (( page < 500 )); do
            local api_url="https://readwise.io/api/v3/list/?limit=100&withRawSourceUrl=true"
            if [[ -n "$cursor" ]]; then
                if command -v python3 &>/dev/null; then
                    enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$cursor" 2>/dev/null) || enc="$cursor"
                else
                    enc="$cursor"
                fi
                api_url+="&pageCursor=${enc}"
            fi
            raw_json=$(rw_curl_list_json "$api_url") || {
                echo "   ❌ Readwise list API failed: HTTP=${_RW_LIST_HTTP:-?} curl_exit=${_RW_LIST_CURL_EXIT:-?} url=${api_url:0:120}..." >&2
                if [[ -n "$_RW_LIST_CURL_ERR" ]]; then
                    echo "      curl stderr: ${_RW_LIST_CURL_ERR:0:500}" | sed 's/^/      /' >&2
                fi
                if [[ -n "$_RW_LIST_ERRBODY" ]]; then
                    echo "      body: ${_RW_LIST_ERRBODY:0:800}" | tr '\n' ' ' | sed 's/  */ /g;s/^/      /' >&2
                fi
                return 1
            }
            list_id=$(echo "$raw_json" | jq -r --arg suf "/reader/document_raw_content/${internal_id}" \
                '.results[] | select((.source_url // "") | endswith($suf)) | .id' | head -n 1)
            if [[ -n "$list_id" ]]; then
                break
            fi
            cursor=$(echo "$raw_json" | jq -r '.nextPageCursor // empty')
            [[ -z "$cursor" ]] && break
            ((page++)) || true
        done
        if [[ -z "$list_id" ]]; then
            echo "   ❌ Could not find a Reader document for document_raw_content/${internal_id} in your library. Open it once in Readwise Reader, then try again." >&2
            return 1
        fi
    else
        return 1
    fi

    local by_id_url="https://readwise.io/api/v3/list/?id=${list_id}&withRawSourceUrl=true"
    raw_json=$(rw_curl_list_json "$by_id_url") || {
        echo "   ❌ Readwise list (by id) failed: HTTP=${_RW_LIST_HTTP:-?} curl_exit=${_RW_LIST_CURL_EXIT:-?} id=${list_id}" >&2
        [[ -n "$_RW_LIST_CURL_ERR" ]] && echo "      curl stderr: ${_RW_LIST_CURL_ERR:0:500}" | sed 's/^/      /' >&2
        [[ -n "$_RW_LIST_ERRBODY" ]] && echo "      body: ${_RW_LIST_ERRBODY:0:800}" | tr '\n' ' ' | sed 's/  */ /g;s/^/      /' >&2
        return 1
    }
    dl_url=$(echo "$raw_json" | jq -r '.results[0].raw_source_url // empty')
    if [[ -z "$dl_url" || "$dl_url" == "null" ]]; then
        echo "   ❌ Readwise has no presigned file URL for this item yet. Try re-opening the document in Reader, or use “Export / save original” from the Readwise app." >&2
        return 1
    fi
    echo "$dl_url"
}

smart_add_file() {
    local ID=$1; local TARGET=$2; local DEST=$3; local FORCE=$4
    local PROJ_PATH=$(get_project_path "$ID")
    local PROJECT=$(get_project_name "$ID")
    local FILE=""

    if [[ "$TARGET" =~ ^https?:// ]]; then
        if grep -qF "$TARGET" "$URL_LOG" && ! $FORCE; then 
            echo "   ⏩ Skipping existing URL."
            echo "      Registry: $URL_LOG"
            echo "      Use -f flag to override."
            return 0
        fi
        echo "   🌐 Downloading..."

        local CURL_URL="$TARGET"
        local S3_MODE=0
        if [[ "$TARGET" == *"readwise.io/reader/document_raw_content/"* || "$TARGET" == *"read.readwise.io/read/"* ]]; then
            local resolved
            resolved=$(resolve_readwise_reader_download_url "$TARGET") && [[ -n "$resolved" ]] || return 1
            CURL_URL="$resolved"
            S3_MODE=1
        fi

        local AUTH_ARGS=()
        if (( S3_MODE == 0 )); then
            [[ "$TARGET" == *"readwise.io"* ]] && [[ -n "$READWISE_TOKEN" ]] && AUTH_ARGS=(-H "Authorization: Token $READWISE_TOKEN")
        fi

        # Download to explicit tempfiles so we pick the filename ourselves
        # (curl -OJ is unreliable when the URL basename contains escape/paren
        # characters and there's no Content-Disposition header).
        local TMP_HDR TMP_BODY RAW CURL_EXIT HTTP_STATUS
        TMP_HDR=$(mktemp); TMP_BODY=$(mktemp)

        RAW=$(curl -sfL "${AUTH_ARGS[@]}" -D "$TMP_HDR" -o "$TMP_BODY" -w "%{http_code}" "$CURL_URL" 2>/dev/null)
        CURL_EXIT=$?
        HTTP_STATUS=${RAW: -3}

        if [[ "$CURL_EXIT" -ne 0 || "$HTTP_STATUS" != "200" ]]; then
            echo "   ❌ Download FAILED (HTTP Status: ${HTTP_STATUS:-unknown})"
            case "$HTTP_STATUS" in
                401|403) echo "      Hint: Authentication issue. Check your Readwise token." ;;
                404)     echo "      Hint: The file no longer exists at this URL." ;;
                500|502|503) echo "      Hint: Server error. Try again later." ;;
            esac
            rm -f "$TMP_HDR" "$TMP_BODY"
            return 1
        fi

        # Filename: prefer Content-Disposition, then URL basename (URL-decoded).
        local FNAME=""
        FNAME=$(grep -i -m1 '^content-disposition:' "$TMP_HDR" 2>/dev/null \
            | sed -nE 's/.*filename\*?=(\"[^\"]+\"|[^;[:space:]]+).*/\1/ip' \
            | tr -d '"\r\n')
        if [[ -z "$FNAME" ]]; then
            FNAME="${CURL_URL##*/}"; FNAME="${FNAME%%\?*}"; FNAME="${FNAME%%#*}"
            FNAME=$(printf '%b' "${FNAME//%/\\x}" 2>/dev/null || echo "$FNAME")
        fi

        # Sanitize: drop backslashes/control chars, replace reserved chars,
        # strip leading punctuation left over from broken URL basenames.
        FNAME=$(echo "$FNAME" | tr -d '\\\r\n' | sed -E 's#[/<>:"|?*]#_#g' | sed -E 's/^[^[:alnum:]]+//')
        [[ -z "$FNAME" ]] && FNAME="download_$(date +%s)"

        mkdir -p "$PROJ_PATH/inbox"
        mv "$TMP_BODY" "$PROJ_PATH/inbox/$FNAME"
        rm -f "$TMP_HDR"
        FILE="$PROJ_PATH/inbox/$FNAME"
        [[ ! "$FORCE" == "true" ]] && echo "$TARGET" >> "$URL_LOG"
    else FILE=$TARGET; fi

    [[ ! -f "$FILE" ]] && return 1
    # PDF rename: prefer `autorename` on PATH; otherwise fall back to the known
    # venv + entry-point pair (mirrors the zsh alias in ~/.zshrc, which bash
    # can't see when res.sh is invoked directly from bash).
    if [[ "$FILE" == *.pdf ]]; then
        local AUTORENAME_CMD=()
        if command -v autorename &>/dev/null; then
            AUTORENAME_CMD=(autorename)
        elif [[ -x "$HOME/repos/autorename/.venv/bin/python" && -f "$HOME/repos/autorename/autorename-files.py" ]]; then
            AUTORENAME_CMD=("$HOME/repos/autorename/.venv/bin/python" "$HOME/repos/autorename/autorename-files.py")
        fi
        if (( ${#AUTORENAME_CMD[@]} > 0 )); then
            "${AUTORENAME_CMD[@]}" rename --heuristics-only --rename-anyway "$FILE"
            FILE=$(ls -t "$(dirname "$FILE")"/*.pdf | head -n 1)
        fi
    fi

    local FILENAME=$(basename "$FILE")
    [[ "$DEST" == "project" ]] && local DEST_DIR="${PROJ_PATH#$WIKI_PATH/}/permanent" || local DEST_DIR=$(route_directory "$FILENAME")
    mkdir -p "$WIKI_PATH/$DEST_DIR"
    mv "$FILE" "$WIKI_PATH/$DEST_DIR/$FILENAME"
    ln -sf "$WIKI_PATH/$DEST_DIR/$FILENAME" "$PROJ_PATH/sources/$FILENAME"
    sed -i '' "/## 📚 Sourced Materials/a\\
\![[$FILENAME]]
" "$PROJ_PATH/${PROJECT}_Master.md"
    echo "   ✅ Added: $FILENAME"
}

case "$1" in
    ""|-h|--help|help)
        print_res_help
        ;;
    add|ad|a)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_add_help
            exit 0
        fi
        FORCE=false; [[ "$2" == "-f" ]] && FORCE=true && shift
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && FILE=$3 && DEST=$4 || { ID=0; FILE=$2; DEST=$3; }
        [[ -n "$FILE" ]] || { print_add_help; exit 1; }
        smart_add_file "$ID" "$FILE" "$DEST" "$FORCE"
        ;;
    init|i)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_init_help
            exit 0
        fi
        [[ -n "$2" ]] || { print_init_help; exit 1; }
        PROJECT=$(sanitize_name "$2"); ID=$(next_project_id)
        if EXISTING_ID=$(get_project_id_by_name "$PROJECT"); then
            echo "   ❌ Project already exists: $PROJECT (ID: $EXISTING_ID)" >&2
            exit 1
        elif [[ $? -eq 2 ]]; then
            exit 1
        fi
        PROJ_ROOT="$WIKI_PATH/$(project_parent_directory "$PROJECT")/projects/$PROJECT"
        mkdir -p "$PROJ_ROOT/inbox" "$PROJ_ROOT/sources" "$PROJ_ROOT/permanent"
        echo "${ID}:${PROJECT}:${PROJ_ROOT}" >> "$REGISTRY"
        echo "# 🧠 Project: $PROJECT (ID: $ID)" > "$PROJ_ROOT/${PROJECT}_Master.md"
        echo -e "## 📚 Sourced Materials\n" >> "$PROJ_ROOT/${PROJECT}_Master.md"
        ln -sfn "$PROJ_ROOT/inbox" "$ACTIVE_INBOX"
        sync_finder_project_pins || true
        echo "✅ Project initialized: $PROJECT (ID: $ID)"
        ;;
    list|ls|l)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_list_help
            exit 0
        fi
        printf "%-4s | %-25s | %s\n" "ID" "Project Name" "Path"
        while IFS=: read -r id name path; do printf "%-4s | %-25s | %s\n" "$id" "$name" "${path#$WIKI_PATH/}"; done < "$REGISTRY"
        ;;
    path)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_path_help
            exit 0
        fi
        [[ -n "$2" ]] || { print_path_help; exit 1; }
        [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 || ID=0; get_project_path "$ID" ;;
    focus|f|fo)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_focus_help
            exit 0
        fi
        [[ -n "$2" ]] || { print_focus_help; exit 1; }
        [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 || ID=0
        if [[ "$2" == "default" ]]; then
            ln -sfn "$DEFAULT_INBOX" "$ACTIVE_INBOX"
            clear_finder_project_pins || true
            exit 0
        fi
        PROJ_PATH=$(get_project_path "$ID"); ln -sfn "$PROJ_PATH/inbox" "$ACTIVE_INBOX"
        sync_finder_project_pins || true
        echo "🎯 Focused: Project $ID" ;;
    finder|pin|pins)
        case "$2" in
            ""|sync)
                sync_finder_project_pins
                ;;
            clear)
                clear_finder_project_pins
                ;;
            list)
                require_mysides || exit 1
                mysides list
                ;;
            -h|--help|help)
                print_finder_help
                ;;
            *)
                print_finder_help
                exit 1
                ;;
        esac
        ;;
    move|mv|m)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_move_help
            exit 0
        fi
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && FILE=$3 && DEST=$4 || { ID=0; FILE=$2; DEST=$3; }
        [[ -n "$FILE" && -n "$DEST" ]] || { print_move_help; exit 1; }
        PROJ_PATH=$(get_project_path "$ID"); SRC=$(readlink "$PROJ_PATH/sources/$FILE")
        mkdir -p "$WIKI_PATH/$DEST"; mv "$SRC" "$WIKI_PATH/$DEST/$FILE"
        ln -sf "$WIKI_PATH/$DEST/$FILE" "$PROJ_PATH/sources/$FILE"; echo "✅ Moved to: $DEST" ;;
    unlink|unln|ul)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_unlink_help
            exit 0
        fi
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && TARGET=$3 || { ID=0; TARGET=$2; }
        [[ -n "$TARGET" ]] || { print_unlink_help; exit 1; }
        unlink_source "$ID" "$TARGET"
        ;;
    readwise|reader|rw|r)
        shift
        "$HOME/repos/research-orchestrator/readwise-project" "$@"
        ;;
    repair|rp)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_repair_help
            exit 0
        fi
        [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 || ID=0; PROJ_PATH=$(get_project_path "$ID")
        for LINK in "$PROJ_PATH/sources"/*; do
            if [[ -L "$LINK" && ! -e "$LINK" ]]; then
                FILENAME=$(basename "$LINK"); NEW=$(find "$WIKI_PATH" -iname "$FILENAME" -not -path "*/.*" | head -n 1)
                [[ -n "$NEW" ]] && ln -sf "$NEW" "$LINK" && echo "   ✅ Re-linked: $FILENAME"
            fi
        done ;;
    link|ln)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_link_help
            exit 0
        fi
        FORCE=false; [[ "$2" == "-f" ]] && FORCE=true && shift
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && TARGET=$3 || { ID=0; TARGET=$2; }
        [[ -n "$TARGET" ]] || { print_link_help; exit 1; }
        link_source "$ID" "$TARGET" "$FORCE" ;;
    relink|rl)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_relink_help
            exit 0
        fi
        FORCE=false; [[ "$2" == "-f" ]] && FORCE=true && shift
        [[ -n "$2" ]] || { print_relink_help; exit 1; }
        if [[ "$2" == "--all" ]]; then
            [[ "$3" =~ ^[0-9]+$ ]] && ID=$3 && TARGET=$4 || { print_relink_help; exit 1; }
            relink_source_all "$ID" "$TARGET" "$FORCE"
        elif [[ "$2" =~ ^[0-9]+$ && -n "$3" && ! "$3" =~ ^[0-9]+$ ]]; then
            relink_source_all "$2" "$3" "$FORCE"
        else
            [[ "$2" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] || { print_relink_help; exit 1; }
            relink_source "$2" "$3" "$4" "$FORCE"
        fi ;;
    unregister|unreg)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_unregister_help
            exit 0
        fi
        FORCE=false
        [[ "$2" == "-f" ]] && FORCE=true && shift
        ID=$(resolve_project_id "$2")
        [[ -n "$ID" ]] || { print_unregister_help; exit 1; }
        unregister_project "$ID" "$FORCE"
        ;;
    delete|del|rm)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_delete_help
            exit 0
        fi
        FORCE=false
        [[ "$2" == "-f" ]] && FORCE=true && shift
        ID=$(resolve_project_id "$2")
        [[ -n "$ID" ]] || { print_delete_help; exit 1; }
        delete_project "$ID" "$FORCE"
        ;;
    ledger|sources)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_ledger_help
            exit 0
        fi
        MODEL=""
        NO_LLM=false
        REF=""
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --no-llm)
                    NO_LLM=true
                    shift
                    ;;
                --model|-m)
                    [[ -n "$2" ]] || { print_ledger_help; exit 1; }
                    MODEL="$2"
                    shift 2
                    ;;
                -*)
                    print_ledger_help
                    exit 1
                    ;;
                *)
                    REF="$1"
                    shift
                    ;;
            esac
        done
        ID=$(resolve_project_id "$REF")
        [[ -n "$ID" ]] || { print_ledger_help; exit 1; }
        ledger_project "$ID" "$MODEL" "$NO_LLM"
        ;;
    finish|done|retro)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_finish_help
            exit 0
        fi
        MODEL=""
        NO_LLM=false
        REF=""
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --no-llm)
                    NO_LLM=true
                    shift
                    ;;
                --model|-m)
                    [[ -n "$2" ]] || { print_finish_help; exit 1; }
                    MODEL="$2"
                    shift 2
                    ;;
                -*)
                    print_finish_help
                    exit 1
                    ;;
                *)
                    REF="$1"
                    shift
                    ;;
            esac
        done
        ID=$(resolve_project_id "$REF")
        [[ -n "$ID" ]] || { print_finish_help; exit 1; }
        finish_project "$ID" "$MODEL" "$NO_LLM"
        ;;
    finalize|fi|pub)
        if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
            print_finalize_help
            exit 0
        fi
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && DEST=$3 || { ID=0; DEST=$2; }
        [[ -n "$DEST" ]] || { print_finalize_help; exit 1; }
        PROJ_PATH=$(get_project_path "$ID"); PROJECT=$(get_project_name "$ID")
        FINAL_PATH="$WIKI_PATH/$DEST/${PROJECT}_Final.md"
        echo -e "# $PROJECT\n\n## 📚 Sources\n" > "$FINAL_PATH"
        ls -l "$PROJ_PATH/sources" | grep "->" | awk '{print "- " $NF}' | sed "s|$WIKI_PATH/||" >> "$FINAL_PATH"
        echo -e "\n---\n" >> "$FINAL_PATH"
        cat "$PROJ_PATH/${PROJECT}_Master.md" >> "$FINAL_PATH"
        echo "✅ Published to: $DEST" ;;
    *)
        print_res_help
        exit 1
        ;;
esac
