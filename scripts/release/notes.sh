#!/bin/zsh
# Prints the CHANGELOG.md section for a version: scripts/release/notes.sh 0.1.0
set -euo pipefail
cd "${0:a:h}/../.."
awk -v v="$1" '
  /^## / { if (found) exit; if (index($0, "[" v "]") || $2 == v) { found = 1; next } }
  found && (seen || NF) { seen = 1; print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
