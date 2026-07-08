#!/bin/bash

THEOS="$HOME/theos"
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos"
fi
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos-roothide"
fi

export THEOS
export THEOS_PACKAGE_SCHEME=
# v3.31: Enable fishhook runtime rebind for iOS < 13.4 ___darwin_check_fd_set_overflow
export TVNC_FISHHOOK=1
export THEOS_DEVICE_IP=127.0.0.1
export THEOS_DEVICE_PORT=58422
export THEOS_DEVICE_SIMULATOR=
export THEBOOTSTRAP=
