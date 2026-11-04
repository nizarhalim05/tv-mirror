#!/bin/bash
# Double-click this file to mirror your Mac to your TV. Close the window (or press Ctrl+C) to stop.
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$b" ]] && eval "$("$b" shellenv)"
done

SCRIPT="$HOME/tv-mirror/tvmirror.py"
[[ -f "$SCRIPT" ]] || SCRIPT="$(cd "$(dirname "$0")" && pwd)/tvmirror.py"

if [[ ! -f "$SCRIPT" ]]; then
  echo "Can't find tvmirror.py. Run the installer again (see the README)."
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

python3 "$SCRIPT" "$@"
echo
read -n 1 -s -r -p "Press any key to close..."
