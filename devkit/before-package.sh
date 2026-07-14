#!/bin/bash

set -e

if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 /var/jb/usr/bin/trollvncserver' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardOutPath /var/jb/tmp/trollvnc-stdout.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardErrorPath /var/jb/tmp/trollvnc-stderr.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
fi

# Set version information for bootstrap (TrollVNC.app)
if [ -n "$THEBOOTSTRAP" ]; then
    GIT_COMMIT_COUNT=$(git rev-list --count HEAD)
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"

    # Collect executables
    cp -rp "$THEOS_STAGING_DIR/usr/bin/trollvncserver" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
    cp -rp "$THEOS_STAGING_DIR/usr/bin/trollvncmanager" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

    # Collect injection dylib. Rootless/iOS sealed system volume has no writable /usr/lib,
    # and the .tipa staging below does `rm -rf usr`, so the dylib MUST ship INSIDE the app
    # bundle to reach the device. The daemon (running inside the .app) resolves it via
    # [NSBundle mainBundle]. Handle both theos library naming variants.
    for _dyn in "$THEOS_STAGING_DIR/usr/lib/tvnc_inject.dylib" "$THEOS_STAGING_DIR/usr/lib/libtvnc_inject.dylib"; do
        if [ -f "$_dyn" ]; then
            cp -rp "$_dyn" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
            echo "Copied $(basename "$_dyn") into TrollVNC.app"
            break
        fi
    done

    # Collect bundle resources
    cp -rp "$THEOS_STAGING_DIR/Library/PreferenceBundles/TrollVNCPrefs.bundle" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
    rm -f "$THEOS_STAGING_DIR/Applications/TrollVNC.app/TrollVNCPrefs.bundle/TrollVNCPrefs"
    cp -rp "$THEOS_STAGING_DIR/usr/share/trollvnc/webclients" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

    # Remove unused files
    rm -rf "${THEOS_STAGING_DIR:?}/usr"
    rm -rf "${THEOS_STAGING_DIR:?}/Library"

    # Pseudo code signing
    ldid -Sapp/TrollVNC/TrollVNC/TrollVNC.entitlements "$THEOS_STAGING_DIR/Applications/TrollVNC.app"
else
    # Non-bootstrap (jailbreak): package MatisuXCS.app to /Applications
    GIT_COMMIT_COUNT=$(git rev-list --count HEAD)

    # Find MatisuXCS.app in staging dir (rootless/roothide use /var/jb/ prefix)
    MATISU_APP=""
    for candidate in \
        "$THEOS_STAGING_DIR/Applications/MatisuXCS.app" \
        "$THEOS_STAGING_DIR/var/jb/Applications/MatisuXCS.app"; do
        if [ -d "$candidate" ]; then
            MATISU_APP="$candidate"
            break
        fi
    done

    if [ -z "$MATISU_APP" ]; then
        echo "Error: MatisuXCS.app not found in staging dir"
        echo "Staging dir contents:"
        find "$THEOS_STAGING_DIR" -name "MatisuXCS.app" -type d 2>/dev/null
        exit 1
    fi

    echo "Found MatisuXCS.app at: $MATISU_APP"

    # Copy icon files to .app root (in case Theos didn't handle them)
    for icon in Icon-60@2x.png Icon-60@3x.png Icon-29@2x.png Icon-29@3x.png; do
        if [ -f "app/MatisuXCS/$icon" ]; then
            echo "Copying $icon to MatisuXCS.app"
            cp -p "app/MatisuXCS/$icon" "$MATISU_APP/$icon"
        fi
    done

    # Info.plist should exist in the .app bundle; if not, copy from source
    if [ ! -f "$MATISU_APP/Info.plist" ]; then
        echo "Warning: Info.plist missing in MatisuXCS.app, copying from source"
        cp -p app/MatisuXCS/Info.plist "$MATISU_APP/Info.plist"
    fi

    # Use PlistBuddy to set version (Delete+Add to handle both existing and missing keys)
    /usr/libexec/PlistBuddy -c "Delete :CFBundleVersion" -c "Add :CFBundleVersion string $GIT_COMMIT_COUNT" "$MATISU_APP/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$MATISU_APP/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleShortVersionString" -c "Add :CFBundleShortVersionString string $PACKAGE_VERSION" "$MATISU_APP/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$MATISU_APP/Info.plist"

    # Sign the app with entitlements (needed for SBSOpenSensitiveURLAndUnlockDevice)
    ldid -Sapp/MatisuXCS/MatisuXCS.entitlements "$MATISU_APP"

    # NOTE: Do NOT remove usr/Library in non-bootstrap mode!
    # Jailbreak debs need trollvncserver, TrollVNCPrefs.bundle, LaunchDaemons, etc.
fi
