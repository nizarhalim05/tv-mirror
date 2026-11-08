#!/bin/bash
# TellyBeam installer: sets up everything needed and puts a "TellyBeam" launcher on your Desktop.
set -e

REPO_RAW="https://raw.githubusercontent.com/nizarhalim05/tv-mirror/main"
INSTALL_DIR="$HOME/tv-mirror"
BIN_DIR="$INSTALL_DIR/bin"
# Ready-made ffmpeg (includes the x264 encoder), used when Homebrew can't provide one
FFMPEG_ZIP_ARM="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
FFMPEG_ZIP_INTEL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip"

echo "== TellyBeam installer =="

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This only works on a Mac."; exit 1
fi
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
export PATH="$BIN_DIR:$PATH"

# Downloads a ready-made ffmpeg into ~/tv-mirror/bin (no Homebrew needed)
download_ffmpeg() {
  echo "Downloading a ready-made ffmpeg..."
  mkdir -p "$BIN_DIR"
  local url="$FFMPEG_ZIP_ARM"
  [[ "$(uname -m)" == "x86_64" ]] && url="$FFMPEG_ZIP_INTEL"
  local tmp; tmp="$(mktemp -d)"
  curl -fL --progress-bar "$url" -o "$tmp/ffmpeg.zip"
  unzip -oq "$tmp/ffmpeg.zip" -d "$tmp"
  local found; found="$(find "$tmp" -type f -name ffmpeg | head -1)"
  if [[ -z "$found" ]]; then
    echo "The ffmpeg download didn't contain ffmpeg."; rm -rf "$tmp"; return 1
  fi
  mv -f "$found" "$BIN_DIR/ffmpeg"
  chmod +x "$BIN_DIR/ffmpeg"
  xattr -d com.apple.quarantine "$BIN_DIR/ffmpeg" 2>/dev/null || true
  rm -rf "$tmp"
  "$BIN_DIR/ffmpeg" -hide_banner -version >/dev/null
}

# 1. ffmpeg (does the screen recording and video encoding)
if ! command -v ffmpeg >/dev/null 2>&1; then
  if [[ "$MACOS_MAJOR" -lt 14 ]]; then
    # Homebrew has no ready-made ffmpeg for older macOS and building it often fails
    download_ffmpeg
  else
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [[ -x "$b" ]] && eval "$("$b" shellenv)"
    done
    if ! command -v brew >/dev/null 2>&1; then
      echo "Installing Homebrew (it will ask for your Mac password)..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
      for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$b" ]] && eval "$("$b" shellenv)"
      done
    fi
    echo "Installing ffmpeg (a few minutes)..."
    # </dev/null: stop brew reading the rest of this script (when run as "curl ... | bash")
    if ! brew install ffmpeg </dev/null; then
      echo "Homebrew couldn't install ffmpeg, so using a ready-made one instead."
      download_ffmpeg
    fi
  fi
fi
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  echo "Note: this ffmpeg has no x264 encoder, so TellyBeam will use the Mac's video chip."
fi

# 2. Python 3 and Apple's developer tools (to build the extra-screen helper)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "Apple's developer tools are needed. A window will pop up: click Install,"
  echo "wait for it to finish, then run this installer again."
  xcode-select --install </dev/null || true
  exit 1
fi

# 3. The program and the Desktop launcher
mkdir -p "$INSTALL_DIR"
echo "Downloading TellyBeam..."
curl -fsSL "$REPO_RAW/tvmirror.py" -o "$INSTALL_DIR/tvmirror.py"
curl -fsSL "$REPO_RAW/TV%20Mirror.command" -o "$HOME/Desktop/TellyBeam.command"
chmod +x "$HOME/Desktop/TellyBeam.command"

echo
echo "Done! Double-click 'TellyBeam' on your Desktop to start mirroring."
echo "(The first time, allow Screen Recording for Terminal in System Settings.)"
