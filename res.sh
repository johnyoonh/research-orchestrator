#!/bin/bash
# V22 PhD Research Orchestrator (Force Download & Path Transparency)

WIKI_PATH="${WIKI_PATH:-/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki}"
REGISTRY="$WIKI_PATH/99_meta/.project_registry"
URL_LOG="$WIKI_PATH/99_meta/.downloaded_urls"
ACTIVE_INBOX="$WIKI_PATH/99_meta/Active_Inbox"
DEFAULT_INBOX="$WIKI_PATH/00_inbox/documents"

# Readwise token: prefer an already-exported env var (so the shell wrapper
# can resolve it from chezmoi/Bitwarden/etc.), and only fall back to grepping
# the Obsidian Readwise plugin's data.json.
if [[ -z "${READWISE_TOKEN// }" ]]; then
    READWISE_TOKEN=$(grep -o '"token": *"[^"]*"' "$WIKI_PATH/.obsidian/plugins/readwise-official/data.json" 2>/dev/null | cut -d'"' -f4)
fi

touch "$REGISTRY" "$URL_LOG"

sanitize_name() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]-]+/_/g' | sed -E 's/[^a-z0-9_]//g' | sed -E 's/_+/_/g'; }
get_project_path() { grep "^$1:" "$REGISTRY" | cut -d':' -f3; }
get_project_name() { grep "^$1:" "$REGISTRY" | cut -d':' -f2; }

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
    add|ad|a)
        FORCE=false; [[ "$2" == "-f" ]] && FORCE=true && shift
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && FILE=$3 && DEST=$4 || { ID=0; FILE=$2; DEST=$3; }
        smart_add_file "$ID" "$FILE" "$DEST" "$FORCE"
        ;;
    init|i)
        PROJECT=$(sanitize_name "$2"); ID=$(wc -l < "$REGISTRY" | tr -d ' ')
        PROJ_ROOT="$WIKI_PATH/$(route_directory "$PROJECT")/projects/$PROJECT"
        mkdir -p "$PROJ_ROOT/inbox" "$PROJ_ROOT/sources" "$PROJ_ROOT/permanent"
        echo "${ID}:${PROJECT}:${PROJ_ROOT}" >> "$REGISTRY"
        echo "# 🧠 Project: $PROJECT (ID: $ID)" > "$PROJ_ROOT/${PROJECT}_Master.md"
        echo -e "## 📚 Sourced Materials\n" >> "$PROJ_ROOT/${PROJECT}_Master.md"
        ln -sfn "$PROJ_ROOT/inbox" "$ACTIVE_INBOX"
        echo "✅ Project initialized: $PROJECT (ID: $ID)"
        ;;
    list|ls|l)
        printf "%-4s | %-25s | %s\n" "ID" "Project Name" "Path"
        while IFS=: read -r id name path; do printf "%-4s | %-25s | %s\n" "$id" "$name" "${path#$WIKI_PATH/}"; done < "$REGISTRY"
        ;;
    path)
        [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 || ID=0; get_project_path "$ID" ;;
    focus|f|fo)
        [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 || ID=0; [[ "$2" == "default" ]] && ln -sfn "$DEFAULT_INBOX" "$ACTIVE_INBOX" && exit 0
        PATH=$(get_project_path "$ID"); ln -sfn "$PATH/inbox" "$ACTIVE_INBOX"; echo "🎯 Focused: Project $ID" ;;
    move|mv|m)
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && FILE=$3 && DEST=$4 || { ID=0; FILE=$2; DEST=$3; }
        PROJ_PATH=$(get_project_path "$ID"); SRC=$(readlink "$PROJ_PATH/sources/$FILE")
        mkdir -p "$WIKI_PATH/$DEST"; mv "$SRC" "$WIKI_PATH/$DEST/$FILE"
        ln -sf "$WIKI_PATH/$DEST/$FILE" "$PROJ_PATH/sources/$FILE"; echo "✅ Moved to: $DEST" ;;
    repair|rp|r)
        [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 || ID=0; PROJ_PATH=$(get_project_path "$ID")
        for LINK in "$PROJ_PATH/sources"/*; do
            if [[ -L "$LINK" && ! -e "$LINK" ]]; then
                FILENAME=$(basename "$LINK"); NEW=$(find "$WIKI_PATH" -iname "$FILENAME" -not -path "*/.*" | head -n 1)
                [[ -n "$NEW" ]] && ln -sf "$NEW" "$LINK" && echo "   ✅ Re-linked: $FILENAME"
            fi
        done ;;
    link|ln)
        FORCE=false; [[ "$2" == "-f" ]] && FORCE=true && shift
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && TARGET=$3 || { ID=0; TARGET=$2; }
        PROJ_PATH=$(get_project_path "$ID"); PROJECT=$(get_project_name "$ID")
        SRC_FILE=$(find "$WIKI_PATH" -iname "*${TARGET}*" -not -path "*/.*" | head -n 1)
        if [[ -f "$SRC_FILE" ]]; then
            ln -sf "$SRC_FILE" "$PROJ_PATH/sources/$(basename "$SRC_FILE")"
            echo "   + Linked: $(basename "$SRC_FILE")"
            if [[ "$SRC_FILE" == *.md ]]; then
                URL=$(grep -E "^url: |^- URL: " "$SRC_FILE" | head -n 1 | awk '{print $NF}' | tr -d '"' | tr -d "'")
                [[ -n "$URL" && "$URL" =~ ^https?:// ]] && smart_add_file "$ID" "$URL" "" "$FORCE"
            fi
        fi ;;
    finalize|fi|pub)
        ID=0; [[ "$2" =~ ^[0-9]+$ ]] && ID=$2 && DEST=$3 || { ID=0; DEST=$2; }
        PROJ_PATH=$(get_project_path "$ID"); PROJECT=$(get_project_name "$ID")
        FINAL_PATH="$WIKI_PATH/$DEST/${PROJECT}_Final.md"
        echo -e "# $PROJECT\n\n## 📚 Sources\n" > "$FINAL_PATH"
        ls -l "$PROJ_PATH/sources" | grep "->" | awk '{print "- " $NF}' | sed "s|$WIKI_PATH/||" >> "$FINAL_PATH"
        echo -e "\n---\n" >> "$FINAL_PATH"
        cat "$PROJ_PATH/${PROJECT}_Master.md" >> "$FINAL_PATH"
        echo "✅ Published to: $DEST" ;;
esac
