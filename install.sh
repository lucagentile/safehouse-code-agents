#!/usr/bin/env bash
# install.sh
#
# Install safehouse-code-agents on top of Agent Safehouse.
#
# What it does:
#   - Refuses to install if safehouse is not on PATH (it's a hard dependency)
#   - Copies the overlay .sb, wrapper, and entry-point to PREFIX
#   - Templates the tinyproxy config + LaunchAgent plist with your paths
#   - Symlinks the entry-points into BINDIR
#   - Optionally loads the tinyproxy LaunchAgent
#
# Override prefix and bin dir with env vars:
#   PREFIX=~/.local/share/safehouse-code-agents   (install destination)
#   BINDIR=~/.local/bin                            (symlink destination)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREFIX="${PREFIX:-$HOME/.local/share/safehouse-code-agents}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

USER_NAME="$(id -un)"
GROUP_NAME="$(id -gn)"
TINYPROXY_BIN="$(command -v tinyproxy 2>/dev/null || echo /opt/homebrew/bin/tinyproxy)"

echo "Installing safehouse-code-agents"
echo "  source:  $SRC_DIR"
echo "  prefix:  $PREFIX"
echo "  bindir:  $BINDIR"
echo

# Hard dependency check.
if ! command -v safehouse >/dev/null 2>&1; then
    cat >&2 <<EOF
Agent Safehouse is required but not on PATH.

Install it first:
  brew install eugene1g/safehouse/agent-safehouse

Or as a standalone script:
  mkdir -p ~/.local/bin
  curl -fsSL https://github.com/eugene1g/agent-safehouse/releases/latest/download/safehouse.sh \\
    -o ~/.local/bin/safehouse
  chmod +x ~/.local/bin/safehouse

Then re-run this installer.
EOF
    exit 1
fi
echo "Found safehouse: $(command -v safehouse)"
echo

mkdir -p "$PREFIX/overlay" "$PREFIX/bin" "$PREFIX/proxy" "$BINDIR" "$HOME/Library/Logs"

install -m 0644 "$SRC_DIR/overlay/claude-narrow.sb" "$PREFIX/overlay/claude-narrow.sb"
install -m 0644 "$SRC_DIR/proxy/allowlist.txt"     "$PREFIX/proxy/allowlist.txt"
install -m 0755 "$SRC_DIR/bin/run-sandboxed.sh"    "$PREFIX/bin/run-sandboxed.sh"
install -m 0755 "$SRC_DIR/bin/safehouse-claude"    "$PREFIX/bin/safehouse-claude"

# Template tinyproxy.conf
sed \
    -e "s|__USER__|$USER_NAME|g" \
    -e "s|__GROUP__|$GROUP_NAME|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__PREFIX__|$PREFIX|g" \
    "$SRC_DIR/proxy/tinyproxy.conf.template" > "$PREFIX/proxy/tinyproxy.conf"
chmod 0644 "$PREFIX/proxy/tinyproxy.conf"

# Template the LaunchAgent plist
mkdir -p "$HOME/Library/LaunchAgents"
PLIST_DEST="$HOME/Library/LaunchAgents/dev.safehouse.tinyproxy.plist"
sed \
    -e "s|__TINYPROXY__|$TINYPROXY_BIN|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__PREFIX__|$PREFIX|g" \
    "$SRC_DIR/proxy/dev.safehouse.tinyproxy.plist.template" > "$PLIST_DEST"
chmod 0644 "$PLIST_DEST"

# Symlinks into BINDIR
ln -sf "$PREFIX/bin/run-sandboxed.sh" "$BINDIR/run-sandboxed.sh"
ln -sf "$PREFIX/bin/safehouse-claude" "$BINDIR/safehouse-claude"

echo "Installed."
echo

if [ -x "$TINYPROXY_BIN" ]; then
    echo "tinyproxy found at $TINYPROXY_BIN."
    read -r -p "Load and start the tinyproxy LaunchAgent now? [y/N] " ans
    case "${ans:-}" in
        y|Y|yes|YES)
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
            launchctl load -w "$PLIST_DEST"
            echo "LaunchAgent loaded. Logs: $HOME/Library/Logs/safehouse-tinyproxy*.log"
            ;;
        *)
            echo "Skipped. Load later with:"
            echo "  launchctl load -w '$PLIST_DEST'"
            ;;
    esac
else
    echo "tinyproxy not found on PATH (looked at: $TINYPROXY_BIN)."
    echo "Install with: brew install tinyproxy"
    echo "Then load the LaunchAgent: launchctl load -w '$PLIST_DEST'"
fi

cat <<EOF

Next steps:

  1. Make sure $BINDIR is on your PATH.
  2. Try it:        safehouse-claude --help
  3. Optional: set SAFEHOUSE_NAMESPACE_ROOT in your shell rc to grant the
     whole namespace dir RW when cwd is under a project there:
        export SAFEHOUSE_NAMESPACE_ROOT="\$HOME/Workspace/coding"

  Uninstall: rm -rf "$PREFIX" and the symlinks under "$BINDIR".

EOF
