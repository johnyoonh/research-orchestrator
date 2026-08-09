stage_upload() {
    local source=${1:-}
    [[ -n "$source" ]] || { command_help upload >&2; exit 1; }
    shift

    local apply=false processor_args=()
    while (($#)); do
        case "$1" in
            --apply)
                apply=true
                shift
                ;;
            -h|--help|help)
                command_help upload
                return 0
                ;;
            *)
                processor_args+=("$1")
                shift
                ;;
        esac
    done

    [[ -f "$source" ]] || fail "book file not found: $source"
    local ext=${source##*.}
    ext=${ext,,}
    case "$ext" in
        epub|pdf|mobi|azw3) ;;
        *) fail "unsupported book extension: .$ext" ;;
    esac

    local stage_dir stage_path
    stage_dir="$READWISE_BOOK_INBOX/$ext"
    stage_path="$stage_dir/$(basename "$source")"
    if [[ -e "$stage_path" ]]; then
        stage_path=$(unique_path "$stage_path")
    fi

    if [[ "$apply" != true ]]; then
        echo "Dry run: no files changed."
        echo "Would stage: $source"
        echo "          -> $stage_path"
        print_command python3 "$READWISE_BOOK_PROCESSOR" --file "$stage_path" --apply "${processor_args[@]}"
        return 0
    fi

    mkdir -p "$stage_dir"
    cp -p "$source" "$stage_path"
    if ! run_processor --file "$stage_path" --apply "${processor_args[@]}"; then
        warn "processor failed; staged copy remains at $stage_path"
        return 1
    fi
}

path_within_inbox() {
    local candidate=$1
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    python3 - "$candidate" "$READWISE_BOOK_INBOX" <<'PY'
import pathlib
import sys
candidate = pathlib.Path(sys.argv[1]).expanduser().resolve()
root = pathlib.Path(sys.argv[2]).expanduser().resolve()
try:
    candidate.relative_to(root)
except ValueError:
    raise SystemExit(1)
PY
}

route_books() {
    local selected="" mode="" processor_args=()
    while (($#)); do
        case "$1" in
            --apply|--review)
                [[ -z "$mode" ]] || fail "choose only one of --apply or --review"
                mode=$1
                shift
                ;;
            -h|--help|help)
                command_help route
                return 0
                ;;
            --inbox|--wiki|--token-file|--sleep)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                processor_args+=("$1" "$2")
                shift 2
                ;;
            --no-upload)
                processor_args+=("$1")
                shift
                ;;
            -*)
                fail "unknown route option: $1"
                ;;
            *)
                [[ -z "$selected" ]] || fail "route accepts at most one staged file"
                selected=$1
                shift
                ;;
        esac
    done

    local args=()
    [[ -n "$mode" ]] && args+=("$mode")
    if [[ -n "$selected" ]]; then
        [[ -f "$selected" ]] || fail "staged file not found: $selected"
        path_within_inbox "$selected" || fail "route file must be under $READWISE_BOOK_INBOX; use upload first"
        args+=(--file "$selected")
    fi
    run_processor "${args[@]}" "${processor_args[@]}"
}
