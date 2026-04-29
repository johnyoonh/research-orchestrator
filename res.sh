#!/bin/bash
# V22 PhD Research Orchestrator (Force Download & Path Transparency)

WIKI_PATH="${WIKI_PATH:-/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki}"
REGISTRY="$WIKI_PATH/99_meta/.project_registry"
URL_LOG="$WIKI_PATH/99_meta/.downloaded_urls"
ACTIVE_INBOX="$WIKI_PATH/99_meta/Active_Inbox"
DEFAULT_INBOX="$WIKI_PATH/00_inbox/documents"
FINDER_PIN_STATE="$WIKI_PATH/99_meta/.finder_project_pins"

# Readwise token: prefer an already-exported env var (so the shell wrapper
# can resolve it from chezmoi/Bitwarden/etc.), and only fall back to grepping
# the Obsidian Readwise plugin's data.json.
if [[ -z "${READWISE_TOKEN// }" ]]; then
    READWISE_TOKEN=$(grep -o '"token": *"[^"]*"' "$WIKI_PATH/.obsidian/plugins/readwise-official/data.json" 2>/dev/null | cut -d'"' -f4)
fi

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
  repair|rp [project-id]
  readwise|reader|rw|r ...
  finder|pins <sync|clear|list>
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
Managed pins use a wiki marker plus circled project indexes.
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

finder_project_label() {
    local ID=$1; local NAME=$2
    local DISPLAY_NAME PREFIX
    DISPLAY_NAME=$(echo "$NAME" | sed -E 's/_+/ /g')
    case "$ID" in
        0) PREFIX="⓪" ;;
        1) PREFIX="⓵" ;;
        2) PREFIX="⓶" ;;
        3) PREFIX="⓷" ;;
        4) PREFIX="⓸" ;;
        5) PREFIX="⓹" ;;
        6) PREFIX="⓺" ;;
        7) PREFIX="⓻" ;;
        8) PREFIX="⓼" ;;
        9) PREFIX="⓽" ;;
        10) PREFIX="⓾" ;;
        *) PREFIX="(${ID})" ;;
    esac
    echo "📚 ${PREFIX} ${DISPLAY_NAME}"
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

clear_finder_project_pins() {
    require_mysides || return 1
    [[ -f "$FINDER_PIN_STATE" ]] || { echo "📌 No managed Finder project pins to clear."; return 0; }

    local LABEL PIN_PATH COUNT=0
    while IFS=$'\t' read -r LABEL PIN_PATH; do
        [[ -z "$LABEL" ]] && continue
        mysides remove "$LABEL" >/dev/null 2>&1 || true
        ((COUNT++))
    done < "$FINDER_PIN_STATE"
    : > "$FINDER_PIN_STATE"
    echo "📌 Cleared Finder pins: $COUNT managed project(s)"
}

sync_finder_project_pins() {
    require_mysides || return 1
    mkdir -p "$(dirname "$FINDER_PIN_STATE")"

    [[ -f "$FINDER_PIN_STATE" ]] && clear_finder_project_pins >/dev/null || true

    local ID NAME PROJ_PATH LABEL COUNT=0
    : > "$FINDER_PIN_STATE"
    while IFS=: read -r ID NAME PROJ_PATH; do
        [[ -z "$ID" || -z "$NAME" || -z "$PROJ_PATH" ]] && continue
        [[ -d "$PROJ_PATH" ]] || continue
        LABEL=$(finder_project_label "$ID" "$NAME")
        if mysides add "$LABEL" "$(path_to_file_url "$PROJ_PATH")" >/dev/null; then
            printf '%s\t%s\n' "$LABEL" "$PROJ_PATH" >> "$FINDER_PIN_STATE"
            ((COUNT++))
        fi
    done < "$REGISTRY"
    echo "📌 Synced Finder pins: $COUNT project(s)"
}

find_source_file() {
    local TARGET=$1
    local SRC_FILE

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
        echo "   ❌ No Readwise token. Set READWISE_TOKEN or add one to the Obsidian Readwise plugin’s data.json." >&2
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
        PROJECT=$(sanitize_name "$2"); ID=$(wc -l < "$REGISTRY" | tr -d ' ')
        PROJ_ROOT="$WIKI_PATH/$(route_directory "$PROJECT")/projects/$PROJECT"
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
