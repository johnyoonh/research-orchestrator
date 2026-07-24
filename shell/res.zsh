#!/usr/bin/env zsh
# PhD Research Orchestrator — zsh integration.
#
# Sourced from ~/.zshrc:
#   [ -f "$HOME/repos/research-orchestrator/shell/res.zsh" ] \
#       && source "$HOME/repos/research-orchestrator/shell/res.zsh"
#
# Provides:
#   - res <cmd> ...        : thin dispatcher, delegates to res.sh for most cmds
#   - res init <name>      : initialize a project, then cd into its root
#   - res cd <id|name>     : cd into a project's root (supports fuzzy names)
#   - res search on|off    : toggle TAVILY_ENABLED env var in current shell
#
# Anything that mutates the calling shell (cd, export) stays here; the heavy
# lifting lives in res.sh so it is version-controlled with the rest of the repo.

# Resolve which repo this file lives in so we can call res.sh next to it.
typeset -g _RES_REPO_DIR="${${(%):-%x}:A:h:h}"
typeset -g _RES_SCRIPT="$_RES_REPO_DIR/res.sh"
typeset -g _RES_WIKI_DEFAULT="/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki"
typeset -g _RES_BOOK_INBOX_EPUB_DIR="$_RES_REPO_DIR/inbox/epub"
typeset -g _RES_BOOK_INBOX_REVIEW_SCRIPT="$_RES_REPO_DIR/scripts/process_book_inbox.py"

_res_run_script() {
    [[ -f "$_RES_SCRIPT" ]] || { echo "res.sh not found: $_RES_SCRIPT"; return 127; }
    WIKI_PATH="${WIKI_PATH:-$_RES_WIKI_DEFAULT}" "$_RES_SCRIPT" "$@"
}

_res_book_inbox_review_on_cd() {
    [[ -o interactive && -t 0 && -t 1 ]] || return 0
    [[ "${PWD:A}" == "${_RES_BOOK_INBOX_EPUB_DIR:A}" ]] || return 0
    [[ -x "$_RES_BOOK_INBOX_REVIEW_SCRIPT" ]] || return 0

    "$_RES_BOOK_INBOX_REVIEW_SCRIPT" --review
}

typeset -ga chpwd_functions
if (( ${chpwd_functions[(Ie)_res_book_inbox_review_on_cd]} == 0 )); then
    chpwd_functions+=(_res_book_inbox_review_on_cd)
fi

_res_sanitize_project_name() {
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[[:space:]-]+/_/g' \
        | sed -E 's/[^a-z0-9_]//g' \
        | sed -E 's/_+/_/g'
}

_res_current_project_id() {
    local wiki="${WIKI_PATH:-$_RES_WIKI_DEFAULT}"
    local registry="$wiki/99_meta/.project_registry"
    local cwd_logical="$PWD"
    local cwd_physical="${PWD:A}"
    local best_id="" best_len=0 id name proj_path proj_physical len

    [[ -f "$registry" ]] || return 1
    while IFS=: read -r id name proj_path; do
        [[ -z "$id" || -z "$proj_path" ]] && continue
        proj_physical="${proj_path:A}"
        if [[ "$cwd_logical" == "$proj_path" || "$cwd_logical" == "$proj_path"/* \
            || "$cwd_physical" == "$proj_physical" || "$cwd_physical" == "$proj_physical"/* \
            || "$cwd_physical" == "$proj_path" || "$cwd_physical" == "$proj_path"/* ]]; then
            len=${#proj_path}
            if (( len > best_len )); then
                best_id="$id"
                best_len=$len
            fi
        fi
    done < "$registry"
    [[ -n "$best_id" ]] && print -r -- "$best_id"
}

_res_project_record_for_ref() {
    local ref="$1"
    local wiki="${WIKI_PATH:-$_RES_WIKI_DEFAULT}"
    local registry="$wiki/99_meta/.project_registry"
    local key record count

    [[ -f "$registry" ]] || return 1
    if [[ -z "$ref" ]]; then
        ref=$(_res_current_project_id)
    elif [[ ! "$ref" =~ ^[0-9]+$ ]]; then
        key=$(_res_sanitize_project_name "$ref")
        record=$(awk -F: -v name="$key" '$2 == name { print }' "$registry")
        [[ -n "$record" ]] || record=$(_res_project_record_for_fuzzy_ref "$ref")
        [[ -n "$record" ]] || return 1
        count=$(printf '%s\n' "$record" | sed '/^$/d' | wc -l | tr -d ' ')
        if (( count > 1 )); then
            echo "Error: Ambiguous project name: $ref" >&2
            printf '%s\n' "$record" | awk -F: '{ printf "  %s  %s  %s\n", $1, $2, $3 }' >&2
            echo "Use the numeric project id." >&2
            return 2
        fi
        print -r -- "$record"
        return 0
    fi
    [[ -n "$ref" ]] || return 1
    awk -F: -v id="$ref" '$1 == id { print; exit }' "$registry"
}

_res_project_fuzzy_matches() {
    local ref="$1"
    local wiki="${WIKI_PATH:-$_RES_WIKI_DEFAULT}"
    local registry="$wiki/99_meta/.project_registry"
    local key

    [[ -f "$registry" ]] || return 1
    key=$(_res_sanitize_project_name "$ref")
    [[ -n "$key" ]] || return 1

    awk -F: -v q="$key" '
        function sanitize(value) {
            value = tolower(value)
            gsub(/[^a-z0-9_]+/, "_", value)
            gsub(/_+/, "_", value)
            gsub(/^_+|_+$/, "", value)
            return value
        }
        function token_score(haystack, query, parts, i, score) {
            score = 0
            split(query, parts, "_")
            for (i in parts) {
                if (parts[i] == "") {
                    continue
                }
                if (index(haystack, parts[i]) == 0) {
                    return 0
                }
                score += length(parts[i])
            }
            return 500 + score
        }
        {
            name = $2
            path = sanitize($3)
            haystack = name " " path
            score = 0
            if (index(name, q) == 1) {
                score = 900 + length(q)
            } else if (index(name, q) > 0) {
                score = 800 + length(q)
            } else if (index(path, q) > 0) {
                score = 700 + length(q)
            } else {
                score = token_score(haystack, q)
            }
            if (score > 0) {
                printf "%d\t%s:%s:%s\n", score, $1, $2, $3
            }
        }
    ' "$registry" | sort -rn | cut -f2-
}

_res_project_record_for_fuzzy_ref() {
    local ref="$1"
    local matches count selected

    matches=$(_res_project_fuzzy_matches "$ref") || return 1
    [[ -n "$matches" ]] || return 1

    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    if (( count == 1 )); then
        print -r -- "$matches"
        return 0
    fi

    if [[ -o interactive && -t 0 && -t 1 ]] && command -v fzf >/dev/null 2>&1; then
        selected=$(printf '%s\n' "$matches" \
            | awk -F: '{ printf "%-5s %-28s %s\n", $1, $2, $3 }' \
            | fzf --prompt="res cd> " --query="$ref" --height=40% --layout=reverse --select-1)
        [[ -n "$selected" ]] || return 130
        local selected_id="${${selected%% *}//[[:space:]]/}"
        printf '%s\n' "$matches" | awk -F: -v id="$selected_id" '$1 == id { print; exit }'
        return 0
    fi

    print -r -- "$matches"
}

_res_preview_project_tree() {
    local command_name="$1"
    local ref="$2"
    local record id name proj_path

    record=$(_res_project_record_for_ref "$ref") || return 0
    [[ -n "$record" ]] || return 0

    id="${record%%:*}"
    name="${record#*:}"; name="${name%%:*}"
    proj_path="${record#*:*:}"
    [[ -d "$proj_path" ]] || return 0

    echo "Project review before \`res $command_name\`: $id $name"
    echo "$proj_path"
    if command -v tree >/dev/null 2>&1; then
        tree "$proj_path"
    elif command -v eza >/dev/null 2>&1; then
        eza -sold --tree --level=3 --icons "$proj_path"
    else
        ls -la "$proj_path"
    fi
}

res() {
    case "$1" in
        search)
            if [[ "$2" == "on" ]]; then
                export TAVILY_ENABLED=true
                echo "🌐 Deep Search ENABLED. (Restart Gemini CLI to apply)"
            else
                export TAVILY_ENABLED=false
                echo "🚫 Deep Search DISABLED."
            fi
            ;;
        cd)
            local wiki="${WIKI_PATH:-$_RES_WIKI_DEFAULT}"
            local registry="$wiki/99_meta/.project_registry"
            local ref="${*:2}"
            local proj_path=""

            if [[ ! -f "$registry" ]]; then
                echo "Error: Registry not found: $registry"
                return 1
            fi

            if [[ "$ref" =~ ^[0-9]+$ ]]; then
                proj_path=$(awk -F: -v id="$ref" '$1 == id { print $3; exit }' "$registry")
            else
                local record
                record=$(_res_project_record_for_ref "$ref") || return $?
                proj_path="${record#*:*:}"
            fi

            if [[ -d "$proj_path" ]]; then
                if cd "$proj_path"; then
                    echo "Jumped to: $proj_path"
                    if command -v tree >/dev/null 2>&1; then
                        tree -L 2
                    fi
                else
                    return 1
                fi
            else
                echo "Error: Project path not found for '$ref'."
                return 1
            fi
            ;;
        init|i)
            if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" || -z "$2" ]]; then
                _res_run_script "$@"
                return
            fi

            _res_run_script "$@"
            local exit_status=$?
            (( exit_status == 0 )) || return $exit_status

            local wiki="${WIKI_PATH:-$_RES_WIKI_DEFAULT}"
            local registry="$wiki/99_meta/.project_registry"
            local key proj_path
            key=$(_res_sanitize_project_name "$2")
            proj_path=$(awk -F: -v name="$key" '$2 == name { path=$3 } END { if (path) print path }' "$registry")

            if [[ -d "$proj_path" ]]; then
                if cd "$proj_path"; then
                    echo "Jumped to: $proj_path"
                    if command -v tree >/dev/null 2>&1; then
                        tree -L 2
                    fi
                else
                    return 1
                fi
            else
                echo "Error: Project initialized, but path not found for '$2'." >&2
                return 1
            fi
            ;;
        unregister|unreg|delete|del|rm)
            if [[ "$2" == "-h" || "$2" == "--help" || "$2" == "help" ]]; then
                _res_run_script "$@"
                return
            fi
            local ref="$2"
            [[ "$ref" == "-f" ]] && ref="$3"
            # Show the normal zsh tree preview before res.sh asks for confirmation.
            _res_preview_project_tree "$1" "$ref"
            _res_run_script "$@"
            ;;
        *)
            _res_run_script "$@"
            ;;
    esac
}
