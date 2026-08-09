fail() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

json_escape() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

print_command() {
    local arg
    printf '$'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

resolve_readwise_cli() {
    if [[ -n "$READWISE_CLI_BIN" ]]; then
        [[ -x "$READWISE_CLI_BIN" ]] || fail "READWISE_CLI_BIN is not executable: $READWISE_CLI_BIN"
        printf '%s\n' "$READWISE_CLI_BIN"
        return 0
    fi
    command -v readwise 2>/dev/null || {
        cat >&2 <<'EOF_ERR'
Error: official Readwise CLI not found.
Install/authenticate it separately, then rerun:
  npm install -g @readwise/cli
  readwise login
EOF_ERR
        exit 127
    }
}

run_official() {
    local cli
    cli=$(resolve_readwise_cli)
    "$cli" "$@"
}

run_triage() {
    [[ -f "$READWISE_PROJECT_BIN" ]] || fail "readwise-project not found: $READWISE_PROJECT_BIN"
    bash "$READWISE_PROJECT_BIN" "$@"
}

run_processor() {
    [[ -f "$READWISE_BOOK_PROCESSOR" ]] || fail "book processor not found: $READWISE_BOOK_PROCESSOR"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    python3 "$READWISE_BOOK_PROCESSOR" "$@"
}

load_readwise_token() {
    local token="${READWISE_TOKEN:-}"
    if [[ -z "$token" && -f "$READWISE_TOKEN_FILE" ]]; then
        token=$(tr -d '\r\n' < "$READWISE_TOKEN_FILE")
    fi
    [[ -n "$token" ]] || fail "Readwise API token not found; set READWISE_TOKEN or create $READWISE_TOKEN_FILE"
    printf '%s' "$token"
}

urlencode() {
    command -v python3 >/dev/null 2>&1 || fail "python3 is required to encode Reader cursors"
    python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

reader_api_get() {
    local token=$1 url=$2
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    curl -fsSL --connect-timeout 20 --max-time 120 \
        -H "Authorization: Token $token" \
        -H "Accept: application/json" \
        "$url"
}

resolve_reader_document_json() {
    local target=$1 token=$2
    command -v jq >/dev/null 2>&1 || fail "jq is required for original-file recovery"

    local document_id="" internal_id="" cursor="" page=0 api_url response encoded
    if [[ "$target" =~ read\.readwise\.io/read/([0-9A-Za-z_-]+) ]]; then
        document_id=${BASH_REMATCH[1]}
    elif [[ "$target" =~ readwise\.io/reader/document_raw_content/([0-9]+) ]]; then
        internal_id=${BASH_REMATCH[1]}
    elif [[ "$target" =~ ^[0-9A-Za-z_-]+$ ]]; then
        document_id=$target
    else
        fail "unsupported Reader reference: $target"
    fi

    if [[ -n "$internal_id" ]]; then
        while (( page < 500 )); do
            api_url="https://readwise.io/api/v3/list/?limit=100&withRawSourceUrl=true"
            if [[ -n "$cursor" ]]; then
                encoded=$(urlencode "$cursor")
                api_url+="&pageCursor=$encoded"
            fi
            response=$(reader_api_get "$token" "$api_url") || fail "Reader list API failed while resolving document_raw_content/$internal_id"
            document_id=$(jq -r --arg suffix "/reader/document_raw_content/$internal_id" \
                'first(.results[]? | select((.source_url // "") | endswith($suffix)) | .id) // empty' \
                <<<"$response")
            [[ -n "$document_id" ]] && break
            cursor=$(jq -r '.nextPageCursor // empty' <<<"$response")
            [[ -n "$cursor" ]] || break
            ((page += 1))
        done
        [[ -n "$document_id" ]] || fail "Reader document not found for document_raw_content/$internal_id"
    fi

    response=$(reader_api_get "$token" "https://readwise.io/api/v3/list/?id=$document_id&withRawSourceUrl=true") \
        || fail "Reader list API failed for document id $document_id"
    jq -e '.results[0] // empty' >/dev/null <<<"$response" \
        || fail "Reader document not found: $document_id"
    jq -c '.results[0]' <<<"$response"
}

sanitize_filename() {
    local value=$1
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=$(printf '%s' "$value" | sed -E 's#[/<>:"|?*\\]# #g; s/[[:cntrl:]]/ /g; s/[[:space:]]+/ /g; s/^[-. ]+//; s/[. ]+$//')
    [[ -n "$value" ]] || value="readwise-document"
    printf '%s' "$value"
}

extension_for_content_type() {
    case "${1,,}" in
        *application/pdf*) printf '.pdf' ;;
        *application/epub+zip*) printf '.epub' ;;
        *application/x-mobipocket-ebook*) printf '.mobi' ;;
        *) printf '' ;;
    esac
}

unique_path() {
    local requested=$1
    if [[ ! -e "$requested" ]]; then
        printf '%s' "$requested"
        return 0
    fi
    local dir base stem ext counter candidate
    dir=$(dirname "$requested")
    base=$(basename "$requested")
    if [[ "$base" == *.* && "$base" != .* ]]; then
        stem=${base%.*}
        ext=.${base##*.}
    else
        stem=$base
        ext=""
    fi
    counter=1
    while :; do
        candidate="$dir/${stem}_$counter$ext"
        if [[ ! -e "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
        ((counter += 1))
    done
}

validate_download() {
    local path=$1 expected_name=${2:-$1} content_type=${3:-}
    local kind=""
    [[ -s "$path" ]] || fail "downloaded file is empty"
    case "${expected_name,,}" in
        *.pdf) kind=pdf ;;
        *.epub) kind=epub ;;
    esac
    if [[ -z "$kind" ]]; then
        case "${content_type,,}" in
            *application/pdf*) kind=pdf ;;
            *application/epub+zip*) kind=epub ;;
        esac
    fi
    case "$kind" in
        pdf)
            [[ $(head -c 5 "$path" 2>/dev/null || true) == "%PDF-" ]] \
                || fail "download did not contain a valid PDF header"
            ;;
        epub)
            if command -v unzip >/dev/null 2>&1; then
                unzip -tqq "$path" >/dev/null || fail "downloaded EPUB failed ZIP validation"
            fi
            ;;
    esac
}

download_original() {
    local target=${1:-}
    [[ -n "$target" ]] || { command_help download >&2; exit 1; }
    shift

    local output_dir="$READWISE_BOOKS_DIR" output_file="" force=false json=false
    while (($#)); do
        case "$1" in
            --output-dir)
                [[ $# -ge 2 ]] || fail "--output-dir requires a value"
                output_dir=$2
                shift 2
                ;;
            --output)
                [[ $# -ge 2 ]] || fail "--output requires a value"
                output_file=$2
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            --json)
                json=true
                shift
                ;;
            -h|--help|help)
                command_help download
                return 0
                ;;
            *)
                fail "unknown download option: $1"
                ;;
        esac
    done

    local token document raw_url title author category tmp_body tmp_headers content_type disposition filename url_name ext destination
    token=$(load_readwise_token)
    document=$(resolve_reader_document_json "$target" "$token")
    raw_url=$(jq -r '.raw_source_url // empty' <<<"$document")
    [[ -n "$raw_url" ]] || fail "Reader has no temporary original-file URL for this document"
    title=$(jq -r '.title // "Readwise document"' <<<"$document")
    author=$(jq -r '.author // empty' <<<"$document")
    category=$(jq -r '.category // empty' <<<"$document")

    tmp_body=$(mktemp "${TMPDIR:-/tmp}/readwise-original.XXXXXX")
    tmp_headers=$(mktemp "${TMPDIR:-/tmp}/readwise-headers.XXXXXX")
    trap "rm -f $(printf '%q' "$tmp_body") $(printf '%q' "$tmp_headers")" EXIT

    curl -fsSL --connect-timeout 20 --max-time 300 -D "$tmp_headers" -o "$tmp_body" "$raw_url" \
        || fail "original-file download failed"

    content_type=$(awk -F': *' 'tolower($1) == "content-type" { value=$2 } END { gsub(/\r/, "", value); print value }' "$tmp_headers")
    disposition=$(awk -F': *' 'tolower($1) == "content-disposition" { value=$2 } END { gsub(/\r/, "", value); print value }' "$tmp_headers")
    filename=$(printf '%s' "$disposition" | sed -nE 's/.*filename\*?=(UTF-8'\''\'\''|)("?)([^";]+)\2.*/\3/ip' | head -n 1)

    if [[ -z "$filename" ]]; then
        url_name=${raw_url%%\?*}
        url_name=${url_name##*/}
        case "${url_name,,}" in
            *.epub|*.pdf|*.mobi|*.azw3) filename=$url_name ;;
        esac
    fi

    ext=$(extension_for_content_type "$content_type")
    if [[ -z "$filename" ]]; then
        filename=$(sanitize_filename "$title")
        if [[ -n "$author" ]]; then
            filename+=" - $(sanitize_filename "$author")"
        fi
        filename+="$ext"
    else
        filename=$(sanitize_filename "$filename")
        if [[ "$filename" != *.* && -n "$ext" ]]; then
            filename+="$ext"
        fi
    fi

    if [[ -z "$ext" && "$filename" != *.* ]]; then
        case "${category,,}" in
            epub) filename+=".epub" ;;
            pdf) filename+=".pdf" ;;
        esac
    fi

    if [[ -n "$output_file" ]]; then
        destination=$output_file
    else
        destination="$output_dir/$filename"
    fi

    mkdir -p "$(dirname "$destination")"
    if [[ -e "$destination" && "$force" != true ]]; then
        destination=$(unique_path "$destination")
    fi

    validate_download "$tmp_body" "$destination" "$content_type"
    mv -f "$tmp_body" "$destination"
    rm -f "$tmp_headers"
    trap - EXIT

    if [[ "$json" == true ]]; then
        printf '{"path":"%s","title":"%s","author":"%s"}\n' \
            "$(json_escape "$destination")" "$(json_escape "$title")" "$(json_escape "$author")"
    else
        printf 'Saved original: %s\n' "$destination"
    fi
}
