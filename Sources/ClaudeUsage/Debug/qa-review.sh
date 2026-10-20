#!/bin/bash
# Run outside the sandbox, after building the app. Never run this during a Codex sandbox session.
set -euo pipefail
qa_app=${1:?Pass the full path to Claude Usage.app/Contents/MacOS/ClaudeUsage}
qa_output=${2:-.build/qa-screenshots}
mkdir -p "$qa_output"

capture() {
    local name=$1
    shift
    local log="$qa_output/$name.log"
    "$qa_app" --qa --qa-quit-after 6 "$@" > "$log" 2>&1 &
    local app_pid=$!
    local ready=false
    for ((attempt=0; attempt<50; attempt++)); do
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
    for state in normal stale rejected signedout single error limits refreshing; do
        capture "menu-$state-$appearance" --qa-state "$state" --qa-appearance "$appearance" --qa-open menu --qa-defaults secondaryAccount=codex-pro
    done
    for tab in general menubar accounts about; do
        capture "settings-$tab-$appearance" --qa-appearance "$appearance" --qa-open "settings-$tab" --qa-defaults secondaryAccount=codex-pro
    done
    capture "accounts-renewal-$appearance" --qa-state rejected --qa-appearance "$appearance" --qa-open settings-accounts
    capture "menubar-both-$appearance" --qa-appearance "$appearance" --qa-open settings-menubar --qa-defaults barMetric=both --qa-defaults barAccounts=primarySecondary --qa-defaults secondaryAccount=codex-pro --qa-defaults 'accountShortNames={"pho":"pho","codex-pro":"›PRO"}'
    capture "accounts-short-names-$appearance" --qa-appearance "$appearance" --qa-open settings-accounts --qa-defaults 'accountShortNames={"pho":"pho","kkpk":"pho","codex-pro":"›PRO","mahidol":"กิขีคุฆูง่จ้"}'
    capture "menubar-icon-only-$appearance" --qa-appearance "$appearance" --qa-open settings-menubar --qa-defaults barNumbers=false
    capture "menu-codex-$appearance" --qa-appearance "$appearance" --qa-open menu --qa-defaults primaryAccount=codex-pro --qa-defaults secondaryAccount=pho
    capture "accounts-signedout-$appearance" --qa-state signedout --qa-appearance "$appearance" --qa-open settings-accounts
 done
