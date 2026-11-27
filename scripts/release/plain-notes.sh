#!/bin/zsh
# Turns release notes Markdown on stdin into plain text for Sparkle's update window, which
# shows the appcast description as is. Links keep only their text (the GitHub release keeps
# the links), code spans become "quoted" so a command still stands apart from the sentence,
# and bold markers go. Single * and _ stay, since they also occur in plain text.
set -euo pipefail
sed -E \
  -e 's/!?\[([^]]*)\]\([^)]*\)/\1/g' \
  -e 's/`([^`]+)`/"\1"/g' \
  -e 's/`//g' \
  -e 's/\*\*//g'
