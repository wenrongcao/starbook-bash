#!/bin/bash
# Install sb: link the command into ~/.local/bin and add bash tab completion.
#   ./install.sh              install (safe to run again)
#   ./install.sh --uninstall  remove the link and the completion
# Override the locations with BIN_DIR=... and COMP_DIR=...
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
COMP_DIR=${COMP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}

if [ "$1" = --uninstall ]; then
  rm -f "$BIN_DIR/sb" "$COMP_DIR/sb" "$COMP_DIR/sb.sh"
  echo "removed $BIN_DIR/sb and the bash completion"
  exit 0
fi

mkdir -p "$BIN_DIR" "$COMP_DIR"
chmod +x "$SRC/sb.sh"
ln -sfn "$SRC/sb.sh" "$BIN_DIR/sb"
cp "$SRC/completions/sb.bash" "$COMP_DIR/sb"
ln -sfn sb "$COMP_DIR/sb.sh"
echo "linked   $BIN_DIR/sb -> $SRC/sb.sh"
echo "copied   bash completion to $COMP_DIR/sb"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not in your PATH - add this to ~/.bashrc:"
     echo "      export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
if [ ! -r /usr/share/bash-completion/bash_completion ]; then
  echo "note: install the bash-completion package for tab completion (sudo apt install bash-completion),"
  echo "      or add to ~/.bashrc:  source \"$COMP_DIR/sb\""
fi
missing=""
for c in curl awk od base64 fold; do command -v "$c" >/dev/null || missing="$missing $c"; done
[ -z "$missing" ] || echo "note: missing required tools:$missing (sudo apt install curl gawk coreutils)"
echo "done - open a new terminal (or run: source $COMP_DIR/sb), then try:  sb status   sb goto Ve<Tab>"
