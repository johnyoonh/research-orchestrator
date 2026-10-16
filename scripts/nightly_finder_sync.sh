#!/usr/bin/env bash
# Nightly Finder Sidebar Sync
# Runs after midnight when the user is away/idle (HIDIdleTime >= threshold).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RES_SH="$REPO_DIR/res.sh"

START_HOUR="${FINDER_SYNC_WINDOW_START:-0}"
END_HOUR="${FINDER_SYNC_WINDOW_END:-6}"
IDLE_THRESHOLD_SECONDS="${FINDER_SYNC_IDLE_SECONDS:-300}"

STATE_DIR="${FINDER_SYNC_STATE_DIR:-$HOME/.local/state/res}"
STATE_FILE="$STATE_DIR/last_nightly_finder_sync"
LOG_DIR="${FINDER_SYNC_LOG_DIR:-$HOME/Library/Logs/res-finder-sync}"
LOG_FILE="$LOG_DIR/activity.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

get_idle_seconds() {
    if [[ -n "${FINDER_SYNC_IDLE_SECONDS_OVERRIDE:-}" ]]; then
        printf '%s\n' "$FINDER_SYNC_IDLE_SECONDS_OVERRIDE"
        return
    fi
    /usr/sbin/ioreg -c IOHIDSystem 2>/dev/null |
        /usr/bin/awk '
            /HIDIdleTime/ {idle = int($NF / 1000000000)}
            END {
                if (idle == "") idle = 0
                print idle
            }
        '
}

in_window() {
    local hour
    hour="${FINDER_SYNC_HOUR_OVERRIDE:-$(date +%H)}"
    hour=$((10#$hour))
    if (( START_HOUR == END_HOUR )); then
        return 0
    fi
    if (( START_HOUR < END_HOUR )); then
        (( hour >= START_HOUR && hour < END_HOUR ))
    else
        (( hour >= START_HOUR || hour < END_HOUR ))
    fi
}

already_ran_today() {
    [[ -f "$STATE_FILE" ]] || return 1
    local last_date today
    last_date="$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
    today="$(date '+%Y-%m-%d')"
    [[ "$last_date" == "$today" ]]
}

print_status() {
    local idle in_win ran_today
    idle="$(get_idle_seconds)"
    in_win="$(in_window && echo yes || echo no)"
    ran_today="$(already_ran_today && echo yes || echo no)"

    echo "Nightly Finder Sync Status"
    echo "=========================="
    echo "Active window       : ${START_HOUR}:00 - ${END_HOUR}:00"
    echo "Currently in window : $in_win"
    echo "User idle seconds   : $idle (threshold: ${IDLE_THRESHOLD_SECONDS}s)"
    echo "Already ran today   : $ran_today"
    echo "State file          : $STATE_FILE"
    echo "Log file            : $LOG_FILE"
}

run_sync() {
    local force="${1:-false}"
    local dry_run="${2:-false}"
    local idle

    if [[ "$force" != "true" ]]; then
        if ! in_window; then
            log "Outside nightly window (${START_HOUR}:00-${END_HOUR}:00); skipping sync."
            return 0
        fi

        if already_ran_today; then
            log "Nightly sync already completed today ($(date '+%Y-%m-%d')); skipping."
            return 0
        fi

        idle="$(get_idle_seconds)"
        if (( idle < IDLE_THRESHOLD_SECONDS )); then
            log "User is active (idle ${idle}s < ${IDLE_THRESHOLD_SECONDS}s threshold); deferring until away."
            return 0
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        log "Dry run requested: previewing dynamic pins."
        "$RES_SH" finder preview
        return 0
    fi

    log "Starting nightly Finder sidebar sync (idle: $(get_idle_seconds)s)..."
    if "$RES_SH" finder sync >> "$LOG_FILE" 2>&1; then
        date '+%Y-%m-%d' > "$STATE_FILE"
        log "Nightly Finder sidebar sync succeeded."
    else
        local status=$?
        log "Nightly Finder sidebar sync failed with exit code $status."
        return "$status"
    fi
}

case "${1:-}" in
    --status|status)
        print_status
        ;;
    --force|force)
        run_sync true false
        ;;
    --dry-run|dry-run|preview)
        run_sync false true
        ;;
    -h|--help|help)
        echo "Usage: $(basename "$0") [--status | --force | --dry-run]"
        ;;
    "")
        run_sync false false
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: $(basename "$0") [--status | --force | --dry-run]" >&2
        exit 1
        ;;
esac
