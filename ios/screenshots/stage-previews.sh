#!/usr/bin/env bash
# Copy the recorded previews into the per-locale layout that
# `ascelerate apps media upload` expects.
#
# The destinations are byte-identical to `raw/video/`, so they are generated
# rather than committed: the same two files were previously tracked three times
# each, which is most of this repository's size and all of it duplication.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

for locale in en-US ko; do
  install -m 644 raw/video/iphone.mp4 "$locale/APP_IPHONE_67/preview.mp4"
  install -m 644 raw/video/ipad.mp4   "$locale/APP_IPAD_PRO_3GEN_129/preview.mp4"
done

echo "staged previews into en-US/ and ko/"
