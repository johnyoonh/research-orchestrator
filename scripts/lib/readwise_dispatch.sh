doctor() {
    local json=false online=false
    while (($#)); do
        case "$1" in
            --json) json=true ;;
            --online) online=true ;;
            -h|--help|help) command_help doctor; return 0 ;;
            *) fail "unknown doctor option: $1" ;;
        esac
        shift
    done

    local cli_path="" cli_ok=false cli_help_ok=false online_ok="not_run" triage_ok=false processor_ok=false
    local curl_ok=false jq_ok=false python_ok=false token_ok=false books_dir_ok=false
    cli_path=$(command -v readwise 2>/dev/null || true)
    if [[ -n "$READWISE_CLI_BIN" && -x "$READWISE_CLI_BIN" ]]; then
        cli_path=$READWISE_CLI_BIN
    fi
    [[ -n "$cli_path" ]] && cli_ok=true
    if [[ "$cli_ok" == true ]] && "$cli_path" --help >/dev/null 2>&1; then
        cli_help_ok=true
    fi
    [[ -f "$READWISE_PROJECT_BIN" ]] && triage_ok=true
    [[ -f "$READWISE_BOOK_PROCESSOR" ]] && processor_ok=true
    command -v curl >/dev/null 2>&1 && curl_ok=true
    command -v jq >/dev/null 2>&1 && jq_ok=true
    command -v python3 >/dev/null 2>&1 && python_ok=true
    if [[ -n "${READWISE_TOKEN:-}" || -s "$READWISE_TOKEN_FILE" ]]; then
        token_ok=true
    fi
    [[ -d "$READWISE_BOOKS_DIR" ]] && books_dir_ok=true

    if [[ "$online" == true ]]; then
        online_ok=false
        if [[ "$cli_ok" == true ]] && "$cli_path" reader-list-documents --location new --limit 1 >/dev/null 2>&1; then
            online_ok=true
        fi
    fi

    if [[ "$json" == true ]]; then
        printf '{'
        printf '"official_cli":{"found":%s,"help_ok":%s,"path":"%s"},' "$cli_ok" "$cli_help_ok" "$(json_escape "$cli_path")"
        printf '"local":{"triage":%s,"book_processor":%s,"books_directory":%s},' "$triage_ok" "$processor_ok" "$books_dir_ok"
        printf '"dependencies":{"curl":%s,"jq":%s,"python3":%s},' "$curl_ok" "$jq_ok" "$python_ok"
        printf '"api_token_available":%s,' "$token_ok"
        if [[ "$online_ok" == "not_run" ]]; then
            printf '"online_auth_probe":null'
        else
            printf '"online_auth_probe":%s' "$online_ok"
        fi
        printf '}\n'
    else
        printf '%-28s %s\n' "Official CLI" "$([[ "$cli_ok" == true ]] && echo "found: $cli_path" || echo missing)"
        printf '%-28s %s\n' "Official CLI help" "$cli_help_ok"
        printf '%-28s %s\n' "Vault triage helper" "$triage_ok"
        printf '%-28s %s\n' "Book processor" "$processor_ok"
        printf '%-28s %s\n' "curl / jq / python3" "$curl_ok / $jq_ok / $python_ok"
        printf '%-28s %s\n' "API token available" "$token_ok"
        printf '%-28s %s\n' "Books directory exists" "$books_dir_ok"
        printf '%-28s %s\n' "Online CLI auth probe" "$online_ok"
    fi

    [[ "$cli_ok" == true && "$cli_help_ok" == true && "$triage_ok" == true && "$processor_ok" == true ]] || return 1
    [[ "$online_ok" != false ]] || return 1
}

move_documents() {
    local ids=${1:-} location=${2:-}
    [[ -n "$ids" && -n "$location" ]] || { command_help move >&2; exit 1; }
    shift 2

    case "$location" in
        new|later|shortlist|archive) ;;
        *) fail "unsupported Reader location: $location" ;;
    esac

    local apply=false extras=()
    while (($#)); do
        case "$1" in
            --apply) apply=true ;;
            *) extras+=("$1") ;;
        esac
        shift
    done

    local cli
    cli=$(resolve_readwise_cli)
    local command=("$cli" reader-move-documents --document-ids "$ids" --location "$location" "${extras[@]}")
    if [[ "$apply" != true ]]; then
        echo "Preview only; no Reader documents changed."
        print_command "${command[@]}"
        echo "Rerun with --apply to execute."
        return 0
    fi
    "${command[@]}"
}

main() {
    local command=${1:-}
    if [[ -z "$command" ]]; then
        usage
        return 0
    fi
    shift

    if [[ "$command" == -* ]]; then
        warn "legacy flag-only Readwise call; treating it as 'res readwise triage'."
        run_triage "$command" "$@"
        return
    fi

    case "$command" in
        search)
            local query=${1:-}
            [[ -n "$query" ]] || { command_help search >&2; exit 1; }
            shift
            run_official reader-search-documents --query "$query" "$@"
            ;;
        highlights)
            local query=${1:-}
            [[ -n "$query" ]] || { command_help highlights >&2; exit 1; }
            shift
            run_official readwise-search-highlights --vector-search-term "$query" "$@"
            ;;
        inbox)
            if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
                local limit=$1
                shift
                run_official reader-list-documents --location new --limit "$limit" "$@"
            else
                run_official reader-list-documents --location new "$@"
            fi
            ;;
        read)
            local document_id=${1:-}
            [[ -n "$document_id" ]] || { command_help read >&2; exit 1; }
            shift
            run_official reader-get-document-details --document-id "$document_id" "$@"
            ;;
        save)
            local url=${1:-}
            [[ -n "$url" ]] || { command_help save >&2; exit 1; }
            shift
            run_official reader-create-document --url "$url" "$@"
            ;;
        move)
            move_documents "$@"
            ;;
        review)
            run_official readwise-get-daily-review "$@"
            ;;
        triage|project)
            run_triage "$@"
            ;;
        download)
            download_original "$@"
            ;;
        upload)
            stage_upload "$@"
            ;;
        route)
            route_books "$@"
            ;;
        commands)
            local cli term=${1:-}
            cli=$(resolve_readwise_cli)
            if [[ -z "$term" ]]; then
                "$cli" --help
            else
                "$cli" --help | grep -i -- "$term" || {
                    echo "No official Readwise commands matched: $term" >&2
                    return 1
                }
            fi
            ;;
        capabilities)
            case "${1:-}" in
                "") capabilities_human ;;
                --json) capabilities_json ;;
                -h|--help|help) command_help capabilities ;;
                *) fail "unknown capabilities option: $1" ;;
            esac
            ;;
        doctor)
            doctor "$@"
            ;;
        help|-h|--help)
            command_help "${1:-}"
            ;;
        *)
            echo "Unknown Readwise command: $command" >&2
            usage >&2
            return 1
            ;;
    esac
}
