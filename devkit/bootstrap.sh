#!/bin/bash

THEOS="$HOME/theos-roothide"
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos-roothide"
fi

export THEOS
export THEOS_PACKAGE_SCHEME=roothide
export THEOS_DEVICE_IP=127.0.0.1
export THEOS_DEVICE_PORT=58422
export THEOS_DEVICE_SIMULATOR=
export THEBOOTSTRAP=1

# v3.43 debug: replace xcbeautify with cat to see raw xcodebuild errors
if command -v xcbeautify &>/dev/null; then
  XCBP=$(command -v xcbeautify)
  echo "[debug] Replacing xcbeautify at $XCBP with cat for raw output"
  mv "$XCBP" "${XCBP}.bak"
  ln -s /bin/cat "$XCBP"
fi
