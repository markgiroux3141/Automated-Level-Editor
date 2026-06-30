#!/usr/bin/env bash
# Launch the Agentic Level Editor (windowed — NEVER --headless; the dummy
# renderer produces blank screenshots). Pass --once to render+dump and quit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="$HERE/engine/Godot_v4.7-stable_win64.exe"
exec "$GODOT" --path "$HERE/project" "$@"
