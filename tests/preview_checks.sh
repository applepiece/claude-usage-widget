#!/bin/bash
# Run outside the Codex sandbox on macOS with WindowServer access.
# Every command renders offscreen; none launches a visible window.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/previews
for tone in light dark; do
  set --
  if [ "$tone" = dark ]; then set -- --dark; fi
  "dist/Claude Usage.app/Contents/MacOS/ClaudeUsage" --preview-menu ".build/previews/menu-$tone.png" "$@"
  "dist/Claude Usage.app/Contents/MacOS/ClaudeUsage" --preview-menu ".build/previews/signed-out-$tone.png" "$@" --signed-out
  "dist/Claude Usage.app/Contents/MacOS/ClaudeUsage" --preview-statusbar ".build/previews/statusbar-$tone.png" "$@"
  "dist/Claude Usage.app/Contents/MacOS/ClaudeUsage" --preview-widget ".build/previews/widget-$tone.png" "$@"
  "dist/Claude Usage.app/Contents/MacOS/ClaudeUsage" --preview-widget ".build/previews/widget-two-$tone.png" "$@" --two
done
