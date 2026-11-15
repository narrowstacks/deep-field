#!/bin/zsh
# Rebuilds every README image and website asset from the app's own renderer:
#   docs/media/        README banner, logo, gallery, loops (GIF), customization montages, UI shots
#   docs/site-assets/  heroes, social cards, favicons, wordmark (PNG + SVG), gallery, MP4 loops, phone stills
# Renders start from the default settings; your saved settings are never read or written.
#   Design/Brand/make_media.sh            # build the app if needed, then everything
#   Design/Brand/make_media.sh --skip-ui  # skip the Customize window captures (they open a window)
set -euo pipefail
cd "${0:a:h}/../.."

[[ -x build/DeepField.app/Contents/MacOS/DeepField ]] || ./build.sh
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)"; exit 1; }

python3 Design/Brand/brand.py
python3 Design/Brand/media.py "$@"
du -sh docs/media docs/site-assets
