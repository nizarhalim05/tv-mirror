#!/bin/bash
# TV Mirror installer: sets up everything needed and puts a "TV Mirror" launcher on your Desktop.
set -e

REPO_RAW="https://raw.githubusercontent.com/nizarhalim05/tv-mirror/main"
INSTALL_DIR="$HOME/tv-mirror"

echo "== TV Mirror installer =="

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This only works on a Mac."; exit 1
fi

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && eval "$("$b" shellenv)"
  done
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew (it will ask for your Mac password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && eval "$("$b" shellenv)"
  done
fi

# 2. ffmpeg
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Installing ffmpeg (a few minutes)..."
  # </dev/null: stop brew reading the rest of this script (when run as "curl ... | bash")
  if ! brew install ffmpeg </dev/null; then
    echo
    echo "Installing ffmpeg failed. On older macOS (13 or earlier) Homebrew has to build it"
    echo "from scratch, which needs up-to-date developer tools. Fix: update macOS in"
    echo "System Settings > General > Software Update, then run this installer again."
    exit 1
  fi
fi

# 3. Python 3 (comes with macOS developer tools)
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is missing. A window will pop up to install Apple's developer tools;"
  echo "click Install, wait for it to finish, then run this installer again."
  xcode-select --install || true
  exit 1
fi

# 4. Apple's developer tools (to build the extra-screen helper)
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's developer tools are needed. A window will pop up: click Install,"
  echo "wait for it to finish, then run this installer again."
  xcode-select --install </dev/null || true
  exit 1
fi

# 5. The program and the Desktop launcher
mkdir -p "$INSTALL_DIR"
echo "Downloading TV Mirror..."
curl -fsSL "$REPO_RAW/tvmirror.py" -o "$INSTALL_DIR/tvmirror.py"
curl -fsSL "$REPO_RAW/TV%20Mirror.command" -o "$HOME/Desktop/TV Mirror.command"
chmod +x "$HOME/Desktop/TV Mirror.command"

echo
echo "Done! Double-click 'TV Mirror' on your Desktop to start mirroring."
echo "(The first time, allow Screen Recording for Terminal in System Settings.)"
