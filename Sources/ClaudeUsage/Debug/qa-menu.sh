#!/bin/bash
# Run only outside the sandbox with a built app bundle.
set -euo pipefail
qa_app=${1:?Pass the full path to Claude Usage.app/Contents/MacOS/ClaudeUsage}
qa_output=${2:-.build/compact-menu-qa}
mkdir -p "$qa_output"

for appearance in light dark; do
    if [ "$appearance" = dark ]; then
        "$qa_app" --preview-menu "$qa_output/preview-$appearance.png" --dark
    else
        "$qa_app" --preview-menu "$qa_output/preview-$appearance.png"
    fi
    for state in normal stale rejected single limits error signedout refreshing; do
        qa_log="$qa_output/$state-$appearance.log"
        "$qa_app" --qa --qa-state "$state" --qa-appearance "$appearance" \
            --qa-open menu --qa-defaults secondaryAccount=codex-pro --qa-quit-after 8 > "$qa_log" 2>&1 &
        qa_pid=$!
        qa_ready=false
        for ((attempt=0; attempt<60; attempt++)); do
            if grep -q "^QA-READY $qa_pid " "$qa_log"; then
                qa_ready=true
                break
            fi
            sleep 0.1
        done
        if [ "$qa_ready" = true ]; then
            /usr/sbin/screencapture -x "$qa_output/$state-$appearance.png"
        fi
        wait "$qa_pid"
        cat "$qa_log"
        if [ "$qa_ready" != true ]; then
            printf 'Missing QA-READY for %s %s\n' "$state" "$appearance" >&2
            exit 1
        fi
    done
done
