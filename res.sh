#!/bin/bash
# V22 PhD Research Orchestrator (Force Download & Path Transparency)

WIKI_PATH="${WIKI_PATH:-/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki}"
REGISTRY="$WIKI_PATH/99_meta/.project_registry"
URL_LOG="$WIKI_PATH/99_meta/.downloaded_urls"
ACTIVE_INBOX="$WIKI_PATH/99_meta/Active_Inbox"
DEFAULT_INBOX="$WIKI_PATH/00_inbox/documents"

# Automatically retrieve Readwise Token
READWISE_TOKEN=$(grep -o '"token": *"[^"]*"' "$WIKI_PATH/.obsidian/plugins/readwise-official/data.json" 2>/dev/null | cut -d'"' -f4)

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
        cd "$PROJ_PATH/inbox"
        local AUTH_ARGS=()
        [[ "$TARGET" == *"readwise.io"* ]] && [[ -n "$READWISE_TOKEN" ]] && AUTH_ARGS=(-H "Authorization: Token $READWISE_TOKEN")

        # Snapshot inbox so we only pick up a file that's actually new.
        local BEFORE
        BEFORE=$(ls -t "$PROJ_PATH/inbox/" 2>/dev/null | head -n 1)

        # -f suppresses the error-body (which otherwise leaks into stdout when
        # there's no Content-Disposition) and makes curl exit non-zero on 4xx/5xx.
        # -w writes the http_code last; we keep the trailing 3 chars defensively.
        local RAW CURL_EXIT HTTP_STATUS
        RAW=$(curl -sfL "${AUTH_ARGS[@]}" -OJ -w "%{http_code}" "$TARGET" 2>/dev/null)
        CURL_EXIT=$?
        HTTP_STATUS=${RAW: -3}

        if [[ "$CURL_EXIT" -ne 0 || "$HTTP_STATUS" != "200" ]]; then
            echo "   ❌ Download FAILED (HTTP Status: ${HTTP_STATUS:-unknown})"
            case "$HTTP_STATUS" in
                401|403) echo "      Hint: Authentication issue. Check your Readwise token." ;;
                404)     echo "      Hint: The file no longer exists at this URL." ;;
                500|502|503) echo "      Hint: Server error. Try again later." ;;
            esac
            return 1
        fi

        local AFTER
        AFTER=$(ls -t "$PROJ_PATH/inbox/" 2>/dev/null | head -n 1)
        if [[ -z "$AFTER" || "$AFTER" == "$BEFORE" ]]; then
            echo "   ❌ Download reported success but no new file appeared in inbox."
            return 1
        fi
        FILE="$PROJ_PATH/inbox/$AFTER"
        [[ ! "$FORCE" == "true" ]] && echo "$TARGET" >> "$URL_LOG"
    else FILE=$TARGET; fi

    [[ ! -f "$FILE" ]] && return 1
    if [[ "$FILE" == *.pdf ]] && command -v autorename-pdf &> /dev/null; then
        autorename-pdf --heuristics-only "$FILE"
        FILE=$(ls -t "$(dirname "$FILE")"/*.pdf | head -n 1)
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
