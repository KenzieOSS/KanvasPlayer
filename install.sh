#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 KenzieOSS
# SPDX-License-Identifier: GPL-3.0-only
#
# Installs kanvasd (backend) + KanvasPlayer (Plasma widget).
#
# What this script DOES do (all user-scoped, no sudo, safe to automate):
#   - Set up kanvasd's Python venv and install its dependencies
#   - Install Bun (official installer) if it's not already on PATH
#   - Install/enable the kanvasd systemd --user service
#   - Install/upgrade the KanvasPlayer plasmoid
#   - Detect native vs Flatpak Spotify and patch a user-local copy of its
#     .desktop launcher to add the remote-debugging flags the token
#     extractor needs
#
# What this script does NOT do, on purpose:
#   - Install Qt6/QtMultimedia or KF6/libplasma - these are system
#     packages whose names vary by distro (qt6-multimedia on Arch,
#     libqt6multimedia6 on Debian/Ubuntu, qt6-qtmultimedia on Fedora,
#     etc.). We check for them and fail with a clear message instead of
#     guessing your package manager and asking for sudo.
#   - Install Spotify itself, if it isn't found.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KANVASD_DIR="$HOME/.local/bin/kanvasd"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
APPLET_ID="io.github.KenzieOSS.kanvasplayer"

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn()  { echo -e "\033[1;33m!!\033[0m $*"; }
fail()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Check for things we refuse to auto-install
# ---------------------------------------------------------------------------

info "Checking for required system components..."

command -v python3 >/dev/null 2>&1 || fail "python3 not found. Install Python 3.11+ via your distro's package manager first."

python3 -m ensurepip --version >/dev/null 2>&1 || python3 -m pip --version >/dev/null 2>&1 || fail \
"python3 was found, but pip isn't available for it (checked 'python3 -m ensurepip' and 'python3 -m pip').
Some distros ship these separately from the base python3 package. Install it first, e.g.:
  Arch:          sudo pacman -S python-pip
  Fedora:        sudo dnf install python3-pip
  Debian/Ubuntu: sudo apt install python3-pip python3-venv"

command -v kpackagetool6 >/dev/null 2>&1 || fail \
"kpackagetool6 not found - this means KDE Plasma 6 (libplasma) isn't installed, or isn't on PATH.
Install your distro's Plasma 6 / libplasma package first, e.g.:
  Arch:          sudo pacman -S libplasma
  Fedora:        sudo dnf install libplasma6
  Debian/Ubuntu: sudo apt install libplasma-dev"

command -v systemctl >/dev/null 2>&1 || fail "systemctl not found - this installer assumes a systemd-based distro."

if command -v pkg-config >/dev/null 2>&1 && ! pkg-config --exists Qt6Multimedia 2>/dev/null; then
    warn "Qt6Multimedia doesn't seem to be installed (checked via pkg-config)."
    warn "The widget's video playback needs it. Install your distro's package, e.g.:"
    warn "  Arch:          sudo pacman -S qt6-multimedia"
    warn "  Fedora:        sudo dnf install qt6-qtmultimedia"
    warn "  Debian/Ubuntu: sudo apt install libqt6multimedia6"
    warn "Continuing anyway - the widget just won't be able to play video until this is installed."
fi

# ---------------------------------------------------------------------------
# 2. Bun - has an official user-scoped installer, safe to run automatically
# ---------------------------------------------------------------------------

if ! command -v bun >/dev/null 2>&1; then
    info "Bun not found on PATH - installing via the official installer (curl | bash, no sudo)..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    command -v bun >/dev/null 2>&1 || fail \
"Bun installation finished but 'bun' still isn't on PATH.
Add \$HOME/.bun/bin to PATH (the installer should have printed how) and re-run this script."
else
    info "Bun already installed: $(bun --version)"
fi

# ---------------------------------------------------------------------------
# 3. kanvasd - venv + deps, unconditionally (simplest, works everywhere)
# ---------------------------------------------------------------------------

info "Installing kanvasd to $KANVASD_DIR..."
mkdir -p "$KANVASD_DIR"
cp "$REPO_DIR/kanvasd/kanvasd.py" \
   "$REPO_DIR/kanvasd/spotify_token_extractor.py" \
   "$REPO_DIR/kanvasd/mrn4txt.ts" \
   "$REPO_DIR/kanvasd/requirements.txt" \
   "$KANVASD_DIR/"

info "Creating venv and installing Python dependencies..."
python3 -m venv "$KANVASD_DIR/.venv"

[ -x "$KANVASD_DIR/.venv/bin/pip" ] || fail \
"The venv was created but has no pip in it ($KANVASD_DIR/.venv/bin/pip missing).
This usually means pip needs to be installed separately for python3 on
this system - see the pip check earlier in this script's output for
the exact command for your distro, then re-run this installer."

"$KANVASD_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$KANVASD_DIR/.venv/bin/pip" install --quiet -r "$KANVASD_DIR/requirements.txt"

# ---------------------------------------------------------------------------
# 4. systemd --user service
# ---------------------------------------------------------------------------

info "Installing kanvasd systemd user service..."
mkdir -p "$SYSTEMD_USER_DIR"
cp "$REPO_DIR/kanvasd/kanvasd.service" "$SYSTEMD_USER_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now kanvasd

info "kanvasd is running (idling until Spotify appears on D-Bus)."

# ---------------------------------------------------------------------------
# 5. Plasmoid
# ---------------------------------------------------------------------------

info "Installing KanvasPlayer widget..."
if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -q "$APPLET_ID"; then
    kpackagetool6 -t Plasma/Applet -u "$REPO_DIR/plasmoid"
else
    kpackagetool6 -t Plasma/Applet -i "$REPO_DIR/plasmoid"
fi

# ---------------------------------------------------------------------------
# 6. Spotify --remote-debugging-port (needed by the token extractor)
#
# Patches a user-local COPY of Spotify's .desktop launcher (never the
# system one) so launching Spotify normally - app launcher, taskbar,
# whatever - includes the flags the token extractor needs. Detects native
# vs Flatpak and inserts the flags in the right place for each. Idempotent:
# safe to re-run, won't double-insert if already patched.
# ---------------------------------------------------------------------------

SPOTIFY_FLAGS="--remote-debugging-port=9222 --remote-allow-origins=*"

patch_spotify_desktop() {
    local src="$1" kind="$2"
    local dest="$HOME/.local/share/applications/$(basename "$src")"

    mkdir -p "$HOME/.local/share/applications"
    cp "$src" "$dest"

    if grep -q -- "--remote-debugging-port" "$dest"; then
        info "Spotify launcher already configured: $dest"
        return
    fi

    if [ "$kind" = "flatpak" ]; then
        # flatpak run passes extra args straight through to the app - insert
        # them right after the app id, before any @@ file-forwarding tokens.
        sed -i -E "s/(com\.spotify\.Client)/\1 $SPOTIFY_FLAGS/" "$dest"
    else
        # Native: insert before any %U/%u/%f/%F placeholder, else append.
        if grep -qE '%[UuFf]' "$dest"; then
            sed -i -E "s/^(Exec=.*)(%[UuFf])/\1$SPOTIFY_FLAGS \2/" "$dest"
        else
            sed -i -E "s/^(Exec=\S+)/\1 $SPOTIFY_FLAGS/" "$dest"
        fi
    fi

    if ! grep -q -- "--remote-debugging-port" "$dest"; then
        warn "Patch didn't take - $dest doesn't have the flags after editing."
        warn "This shouldn't happen; please report it with the output of:"
        warn "  grep ^Exec= \"$dest\""
        return
    fi

    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    # update-desktop-database only refreshes the generic XDG MIME/desktop
    # association cache (what e.g. xdg-open uses) - Plasma's own launcher
    # (Kickoff/KRunner/taskbar) reads from KSycoca instead, which needs
    # its own explicit rebuild or it'll keep serving the old cached entry
    # even though the file on disk is already correctly patched.
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental 2>/dev/null || true

    info "Patched Exec line:"
    grep ^Exec= "$dest"
    info "Spotify launcher configured: $dest"
}

info "Looking for Spotify (native and/or Flatpak)..."

found_spotify=false
patched_spotify=false

flatpak_desktop="$(find "$HOME/.local/share/flatpak" /var/lib/flatpak \
    -name "com.spotify.Client.desktop" 2>/dev/null | head -n1 || true)"
native_desktop=""
for candidate in /usr/share/applications/spotify.desktop /usr/local/share/applications/spotify.desktop; do
    [ -f "$candidate" ] && native_desktop="$candidate" && break
done

if [ -n "$flatpak_desktop" ] || [ -n "$native_desktop" ]; then
    found_spotify=true
    [ -n "$flatpak_desktop" ] && info "Detected Flatpak Spotify: $flatpak_desktop"
    [ -n "$native_desktop" ] && info "Detected native Spotify: $native_desktop"

    echo
    echo "  Spotify's launcher can be patched (a user-local copy - the system one"
    echo "  is never touched) to automatically start with:"
    echo "    $SPOTIFY_FLAGS"
    echo "  Recommended for most users. Skip this if you already launch Spotify via"
    echo "  a custom script/wrapper and would rather add the flags yourself."
    echo

    reply="n"
    if [ -t 0 ]; then
        read -r -p "  Patch Spotify's launcher automatically? [y/N] " reply
    else
        warn "Non-interactive shell - skipping the prompt, defaulting to N."
    fi

    if [[ "$reply" =~ ^[Yy]$ ]]; then
        [ -n "$flatpak_desktop" ] && patch_spotify_desktop "$flatpak_desktop" "flatpak"
        [ -n "$native_desktop" ] && patch_spotify_desktop "$native_desktop" "native"
        patched_spotify=true
    else
        info "Skipped. Add these flags however you normally launch Spotify: $SPOTIFY_FLAGS"
    fi
fi

if [ "$found_spotify" = false ]; then
    if command -v spotify >/dev/null 2>&1; then
        warn "Found a 'spotify' binary on PATH but no matching .desktop file."
        warn "However you normally launch it, add: $SPOTIFY_FLAGS"
    else
        warn "Spotify doesn't appear to be installed (checked Flatpak and native paths)."
        warn "Once it is, re-run this script and it'll offer to patch the launcher -"
        warn "or add these flags manually however you launch it: $SPOTIFY_FLAGS"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
info "Install complete."
if [ "$patched_spotify" = true ]; then
    echo "  Spotify's launcher was patched - just start it normally (app launcher/taskbar)."
    echo "  If Spotify is already running, quit and relaunch it once to pick up the new flags."
fi
echo
echo "  Restart Plasma so it notices the new widget, then add it to a panel:"
echo "    kquitapp6 plasmashell && kstart plasmashell"
echo "  Right-click panel -> Add Widgets -> search \"KanvasPlayer\""
