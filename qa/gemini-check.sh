#!/bin/bash
# Run outside the sandbox with a freshly built 3.3.0 / 330 app.
set -euo pipefail
qa_app=${1:?Pass the full path to Claude Usage.app/Contents/MacOS/ClaudeUsage}
qa_output=${2:-.build/gemini-330/screenshots}
mkdir -p "$qa_output"

capture() {
    local name=$1
    shift
    local log="$qa_output/$name.log"
    "$qa_app" --qa --qa-quit-after 8 "$@" > "$log" 2>&1 &
    local app_pid=$!
    local ready=false
    for ((attempt=0; attempt<60; attempt++)); do
        if grep -q "^QA-READY $app_pid " "$log"; then
            ready=true
            break
        fi
        sleep 0.1
    done
    if [ "$ready" = true ]; then
        /usr/sbin/screencapture -x "$qa_output/$name.png"
    fi
    wait "$app_pid"
    cat "$log"
    if [ "$ready" != true ]; then
        printf 'Missing QA-READY: %s\n' "$name" >&2
        return 1
    fi
}

for appearance in light dark; do
    capture "menu-$appearance" --qa-appearance "$appearance" --qa-open menu
    capture "gemini-primary-$appearance" --qa-appearance "$appearance" --qa-open menu \
        --qa-defaults primaryAccount=gemini-pho --qa-defaults secondaryAccount=gemini-apple
    capture "gemini-weekly-models-$appearance" --qa-appearance "$appearance" --qa-open menu \
        --qa-defaults primaryAccount=gemini-pho \
        --qa-defaults 'barSlots=session,weekly,weekly:Claude and GPT models'
    capture "settings-accounts-$appearance" --qa-appearance "$appearance" --qa-open settings-accounts
done

printf 'Review Claude, Codex, Gemini order; both Gemini rows; blue accents; Plan ends 2026-12-19; apple login hint; model weekly 0%%.\n'
