#!/bin/sh
# Install Intent OS on an Apple silicon Mac (M1, M2). Run from macOS Terminal:
#   curl -fsSL https://github.com/intent-hq/intent-os/releases/latest/download/install-apple-silicon.sh | sh
# It runs the Asahi Linux installer (the build Asahi ALARM uses) with the
# Intent OS image. macOS stays installed; the installer makes room for Intent OS.
# Based on asahi-alarm's installer-bootstrap.sh (MIT).

# Truncation guard
if true; then
    set -e

    if [ ! -e /System ]; then
        echo "Run this from macOS (or recoveryOS) on an Apple silicon Mac."
        exit 1
    fi

    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

    if ! curl --no-progress-meter file:/// >/dev/null 2>&1; then
        echo "This macOS is too old. Installing Intent OS needs macOS 13.5 or later."
        exit 1
    fi

    export VERSION_FLAG="https://asahi-alarm.org/latest"
    export INSTALLER_BASE="https://asahi-alarm.org/"
    export INSTALLER_DATA="https://github.com/intent-hq/intent-os/releases/latest/download/installer_data.json"
    export REPO_BASE="https://asahi-alarm.org/"

    TMP=/tmp/intent-os-install
    echo
    echo "Getting the installer:"
    if [ -e "$TMP" ]; then
        mv "$TMP" "$TMP-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$TMP"
    cd "$TMP"

    PKG_VER="$(curl --no-progress-meter -L "$VERSION_FLAG")"
    echo "  Version: $PKG_VER"
    PKG="installer-$PKG_VER.tar.gz"
    curl --no-progress-meter -L -o "$PKG" "$INSTALLER_BASE/$PKG"
    if ! curl --no-progress-meter -L -o installer_data.json "$INSTALLER_DATA"; then
        echo "  Could not download the Intent OS image list. Check the network."
        exit 1
    fi
    tar xf "$PKG"

    echo
    echo "The installer asks for your macOS password, then how much space to give"
    echo "Intent OS (at least 20 GB). Choose \"Intent OS\" when it lists systems."
    echo
    if [ "$USER" != "root" ]; then
        exec caffeinate -dis sudo -E ./install.sh "$@"
    else
        exec caffeinate -dis ./install.sh "$@"
    fi
fi
