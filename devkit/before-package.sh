#!/bin/bash

set -e

if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 /var/jb/usr/bin/MatisuVNCserver' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.Matisu.MatisuVNC.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardOutPath /var/jb/tmp/MatisuVNC-stdout.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.Matisu.MatisuVNC.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardErrorPath /var/jb/tmp/MatisuVNC-stderr.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.Matisu.MatisuVNC.plist"
fi

if [ -z "$THEBOOTSTRAP" ]; then
    exit 0
fi

# Set version information
GIT_COMMIT_COUNT=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/Info.plist"

# Collect executables
cp -rp "$THEOS_STAGING_DIR/usr/bin/MatisuVNCserver" "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/"
cp -rp "$THEOS_STAGING_DIR/usr/bin/MatisuVNCmanager" "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/"

# Collect bundle resources
cp -rp "$THEOS_STAGING_DIR/Library/PreferenceBundles/MatisuVNCPrefs.bundle" "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/"
rm -f "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/MatisuVNCPrefs.bundle/MatisuVNCPrefs"
cp -rp "$THEOS_STAGING_DIR/usr/share/MatisuVNC/webclients" "$THEOS_STAGING_DIR/Applications/MatisuVNC.app/"

# Remove unused files
rm -rf "${THEOS_STAGING_DIR:?}/usr"
rm -rf "${THEOS_STAGING_DIR:?}/Library"

# Pseudo code signing
ldid -Sapp/MatisuVNC/MatisuVNC/MatisuVNC.entitlements "$THEOS_STAGING_DIR/Applications/MatisuVNC.app"
