#!/usr/bin/env zsh
# PhD Research Orchestrator — zsh integration.
#
# Sourced from ~/.zshrc:
#   [ -f "$HOME/repos/research-orchestrator/shell/res.zsh" ] \
#       && source "$HOME/repos/research-orchestrator/shell/res.zsh"
#
# Provides:
#   - res <cmd> ...        : thin dispatcher, delegates to res.sh for most cmds
#   - res cd <id|name>     : cd into a project's root (needs to be a shell fn)
#   - res search on|off    : toggle TAVILY_ENABLED env var in current shell
#
# Anything that mutates the calling shell (cd, export) stays here; the heavy
# lifting lives in res.sh so it is version-controlled with the rest of the repo.

# Resolve which repo this file lives in so we can call res.sh next to it.
typeset -g _RES_REPO_DIR="${${(%):-%x}:A:h:h}"
typeset -g _RES_SCRIPT="$_RES_REPO_DIR/res.sh"
typeset -g _RES_WIKI_DEFAULT="/Users/john/Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki"

# Resolve the Readwise *API* token (NOT the account password) from, in order:
#   1. $READWISE_TOKEN env var.
#   2. chezmoi template ({{ .readwise_token }} or {{ .secrets.readwise_token }}).
#   3. Bitwarden, from a custom field named token / api_token / readwise_token /
#      api_key on any item matching "readwise". The item's login.password is
#      intentionally ignored — that's the account password, not the API token.
#   4. Bitwarden notes, only if they look like a token (single line, no spaces,
#      >= 20 chars). This handles users who stashed the token in the notes field.
#
# Prints the token on success; returns 1 on no match. When this returns 1,
# res.sh falls back to grepping the Obsidian Readwise plugin's data.json.
_res_get_readwise_token() {
    local token=""

    if [[ -n "$READWISE_TOKEN" ]]; then
        print -r -- "$READWISE_TOKEN"
        return 0
    fi

    if command -v chezmoi >/dev/null 2>&1; then
        for tmpl in '{{ .readwise_token }}' '{{ .secrets.readwise_token }}'; do
            token=$(chezmoi execute-template "$tmpl" 2>/dev/null | tr -d '\r')
            if [[ -n "$token" && "$token" != "<no value>" ]]; then
                print -r -- "$token"
                return 0
            fi
        done
    fi

    if command -v bw >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local bw_state
        bw_state=$(bw status --raw 2>/dev/null | jq -r '.status // empty')
        if [[ "$bw_state" == "unlocked" ]]; then
            # Custom field whose name looks like a token field.
            token=$(bw list items --search readwise 2>/dev/null \
                | jq -r '
                    [ .[] | .fields // [] | .[]
                        | select(.name | test("^(readwise[_-]?)?(api[_-]?)?(token|key)$"; "i"))
                        | .value
                    ] | map(select(. != null and . != "")) | .[0] // empty')
            if [[ -n "$token" ]]; then
                print -r -- "$token"
                return 0
            fi
            # Fall back to notes, but only if it's a single token-shaped line.
            token=$(bw list items --search readwise 2>/dev/null \
                | jq -r '.[0].notes // empty' \
                | head -n 1 | tr -d '[:space:]')
            if (( ${#token} >= 20 )) && [[ "$token" != *" "* ]]; then
                print -r -- "$token"
                return 0
            fi
        fi
    fi

    return 1
}

_res_run_script() {
    [[ -f "$_RES_SCRIPT" ]] || { echo "res.sh not found: $_RES_SCRIPT"; return 127; }
    local token
    token=$(_res_get_readwise_token 2>/dev/null || true)
    # If the resolver returns _nothing_, do not export READWISE_TOKEN at all
    # (empty string would block res.sh’s `${READWISE_TOKEN:-$(grep data.json)}` fallback).
    if [[ -n "$token" ]]; then
        WIKI_PATH="${WIKI_PATH:-$_RES_WIKI_DEFAULT}" READWISE_TOKEN="$token" "$_RES_SCRIPT" "$@"
    else
        WIKI_PATH="${WIKI_PATH:-$_RES_WIKI_DEFAULT}" "$_RES_SCRIPT" "$@"
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
            local ref="$2"
            local proj_path=""

            if [[ ! -f "$registry" ]]; then
                echo "Error: Registry not found: $registry"
                return 1
            fi

            if [[ "$ref" =~ ^[0-9]+$ ]]; then
                proj_path=$(awk -F: -v id="$ref" '$1 == id { print $3; exit }' "$registry")
            else
                local key
                key=$(echo "$ref" \
                    | tr '[:upper:]' '[:lower:]' \
                    | sed -E 's/[[:space:]-]+/_/g' \
                    | sed -E 's/[^a-z0-9_]//g' \
                    | sed -E 's/_+/_/g')
                proj_path=$(awk -F: -v name="$key" '$2 == name { print $3; exit }' "$registry")
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
        *)
            _res_run_script "$@"
            ;;
    esac
}
