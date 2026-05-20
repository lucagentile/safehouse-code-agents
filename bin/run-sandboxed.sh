#!/usr/bin/env bash
# run-sandboxed.sh
#
# Run a command under Safehouse with the safehouse-code-agents overlay:
#   - Claude OAuth credential bridge (extract from Keychain, write to plaintext
#     fallback path, unlink on exit)
#   - --append-profile=<overlay> to re-deny keychain and add file-ioctl allow
#   - Optional namespace-aware RW grant via SAFEHOUSE_NAMESPACE_ROOT
#   - HTTP/HTTPS routed through a loopback hostname-filtering proxy
#
# Usage:
#   run-sandboxed.sh -- <command> [args...]
#   run-sandboxed.sh --tight -- <command> [args...]
#
# Optional env knobs:
#   SAFEHOUSE_OVERLAY         absolute path to the append-profile .sb
#                             (default: ../overlay/claude-narrow.sb)
#   SAFEHOUSE_NAMESPACE_ROOT  absolute path. If set and cwd is at or under
#                             $ROOT/<ns>/<project>/..., grant RW to all of
#                             $ROOT/<ns>/ instead of just cwd.
#   SAFEHOUSE_PROXY_URL       loopback proxy URL (default 127.0.0.1:8118)
#                             empty string disables the proxy
#   SAFEHOUSE_BRIDGE_CLAUDE   set to "0" to skip the Claude OAuth bridge
#   SAFEHOUSE_BRIDGE_GH       set to "0" to skip the gh CLI token bridge
#   SAFEHOUSE_EXTRA_ARGS      additional safehouse args appended verbatim

set -euo pipefail

# Strip env vars that could be used to bypass the sandbox.
# DYLD_*: dyld-injection class (CVE-2024-23253, CVE-2024-40831 lineage).
# SSH_AUTH_SOCK is kept so users who opt in to ssh via
#   SAFEHOUSE_EXTRA_ARGS="--enable=ssh"
# can push over git@github.com. Safehouse's base still default-denies the
# socket unless --enable=ssh is set.
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
      DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH \
      DYLD_VERSIONED_LIBRARY_PATH DYLD_VERSIONED_FRAMEWORK_PATH

# Resolve own path through symlinks (script may be invoked via a BINDIR link).
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
    _target="$(readlink "$_self")"
    case "$_target" in
        /*) _self="$_target" ;;
        *)  _self="$(dirname "$_self")/$_target" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
unset _self _target

PREFIX="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OVERLAY="${SAFEHOUSE_OVERLAY:-$PREFIX/overlay/claude-narrow.sb}"
PROXY_URL="${SAFEHOUSE_PROXY_URL-http://127.0.0.1:8118}"
NAMESPACE_ROOT="${SAFEHOUSE_NAMESPACE_ROOT:-}"

# Argument parsing
TIGHT_MODE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --tight)     TIGHT_MODE=1; shift ;;
        --)          shift; break ;;
        --help|-h)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --*)         echo "run-sandboxed: unknown flag: $1" >&2; exit 64 ;;
        *)           break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "usage: $(basename "$0") [--tight] -- <command> [args...]" >&2
    exit 64
fi

command -v safehouse >/dev/null 2>&1 || {
    echo "run-sandboxed: 'safehouse' not on PATH." >&2
    echo "                Install Agent Safehouse first:" >&2
    echo "                  brew install eugene1g/safehouse/agent-safehouse" >&2
    exit 127
}

if [ ! -f "$OVERLAY" ]; then
    echo "run-sandboxed: overlay not found: $OVERLAY" >&2
    echo "                (set SAFEHOUSE_OVERLAY to override)" >&2
    exit 66
fi

# Credential bridge for Claude Code.
# The overlay re-denies wholesale Keychain access. To keep claude logged in
# we extract just its OAuth token outside the sandbox and write it to
# ~/.claude/.credentials.json (claude's plaintext fallback). The bridge owns
# this file's lifecycle entirely: it always overwrites at startup (so a file
# leftover from a crashed previous session can't shadow a fresh token), and
# on exit it syncs the file back to the Keychain if claude refreshed the
# token during the session, then unlinks the file.
CRED_FILE=""
CRED_PRE_HASH=""
if [ "${SAFEHOUSE_BRIDGE_CLAUDE:-1}" != "0" ]; then
    CMD="$1"
    if [ "$CMD" = "claude" ] || [ "$(basename "$CMD" 2>/dev/null)" = "claude" ]; then
        if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
            CRED_FILE="$HOME/.claude/.credentials.json"
            mkdir -p "$HOME/.claude"
            umask 077
            if security find-generic-password -s "Claude Code-credentials" -w \
                > "$CRED_FILE" 2>/dev/null; then
                CRED_PRE_HASH="$(shasum < "$CRED_FILE" 2>/dev/null | awk '{print $1}')"
            else
                rm -f "$CRED_FILE"; CRED_FILE=""
            fi
        fi
    fi
fi

# gh CLI token bridge.
# gh stores its token in the macOS Keychain by default. Safehouse's auto-included
# keychain.sb integration grants the agent wholesale Keychain access, but our
# overlay re-denies that, so gh inside the sandbox reports "The token in
# default is invalid". Extract the token outside the sandbox and export
# GH_TOKEN, which gh respects over any Keychain/hosts.yml lookup. No
# on-disk artifact, no cleanup needed; the env var dies with the wrapper.
if [ "${SAFEHOUSE_BRIDGE_GH:-1}" != "0" ] && command -v gh >/dev/null 2>&1; then
    if _gh_token="$(gh auth token 2>/dev/null)" && [ -n "$_gh_token" ]; then
        export GH_TOKEN="$_gh_token"
    fi
    unset _gh_token
fi

cleanup() {
    if [ -n "$CRED_FILE" ] && [ -f "$CRED_FILE" ]; then
        POST_HASH="$(shasum < "$CRED_FILE" 2>/dev/null | awk '{print $1}')"
        if [ -n "$POST_HASH" ] && [ "$POST_HASH" != "$CRED_PRE_HASH" ]; then
            security add-generic-password -U \
                -a "$(id -un)" \
                -s "Claude Code-credentials" \
                -w "$(cat "$CRED_FILE")" 2>/dev/null || true
        fi
        rm -f "$CRED_FILE"
    fi
}
trap cleanup EXIT INT TERM

# Build the safehouse argv.
sh_args=(--append-profile="$OVERLAY")

# Namespace-aware RW grant.
if [ "$TIGHT_MODE" -eq 0 ] && [ -n "$NAMESPACE_ROOT" ]; then
    NS_ROOT="${NAMESPACE_ROOT%/}/"
    CWD="$(pwd -P)"
    case "$CWD/" in
        "$NS_ROOT"*/*/*)
            rest="${CWD#"$NS_ROOT"}"
            ns="${rest%%/*}"
            sh_args+=(--add-dirs="${NS_ROOT%/}/$ns")
            ;;
    esac
fi

# Optional pass-through args
if [ -n "${SAFEHOUSE_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    extra=($SAFEHOUSE_EXTRA_ARGS)
    sh_args+=("${extra[@]}")
fi

# Loopback egress proxy.
if [ -n "$PROXY_URL" ]; then
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="$NO_PROXY"
fi

exec safehouse "${sh_args[@]}" -- "$@"
