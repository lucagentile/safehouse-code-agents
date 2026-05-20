# safehouse-code-agents

A thin opinionated layer on top of [Agent Safehouse](https://github.com/eugene1g/agent-safehouse)
that runs Claude Code (and other macOS coding agents) under `sandbox-exec`
with one substantive divergence from Safehouse defaults:

- **Narrow OAuth credential bridge** instead of wholesale Keychain access.
  Safehouse's auto-included `keychain.sb` module gives the sandboxed agent
  access to your entire login Keychain. This wrapper lifts only the
  `Claude Code-credentials` Keychain item out before entering the sandbox,
  writes it to claude's plaintext-fallback path, and unlinks it on exit.

Plus a hostname-filtering loopback egress proxy and a couple of minor
conveniences (namespace-aware RW grant via `--add-dirs`, optional shell
function-style entry-point).

Requires **Agent Safehouse >= 0.10.0** (the version that includes the
`file-ioctl` allow for tty/pty paths — [PR #98](https://github.com/eugene1g/agent-safehouse/pull/98)).

## Architecture

```
+----------------------------------------------+
| safehouse-claude  (entry-point)              |
|   exec run-sandboxed.sh -- claude "$@"       |
+----------------------------------------------+
                       |
                       v
+----------------------------------------------+
| run-sandboxed.sh                             |
|   - extract Claude Keychain token            |
|   - write to ~/.claude/.credentials.json     |
|   - trap unlink on exit                      |
|   - set HTTP_PROXY for loopback tinyproxy    |
|   - exec safehouse                           |
|       --append-profile=overlay/...           |
|       --add-dirs=$NAMESPACE/$NS              |
|       -- claude "$@"                         |
+----------------------------------------------+
                       |
                       v
+----------------------------------------------+
| safehouse (Agent Safehouse)                  |
|   - assembles full sandbox-exec policy       |
|   - auto-includes claude-code + keychain     |
|   - last-loaded: our overlay re-DENIES       |
|     wholesale keychain access                 |
|   - execs sandbox-exec                       |
+----------------------------------------------+
```

The overlay file (`overlay/claude-narrow.sb`) is ~40 lines and is the entirety
of what this repo adds to Safehouse's policy. Everything else here is
plumbing for the credential bridge and the egress proxy.

## Why the keychain bridge

Safehouse ships `keychain.sb`, an opt-in module that grants the sandboxed
agent wholesale access to your login Keychain. The CLI auto-enables it when
it detects `claude` on the command line, because Claude Code stores its
OAuth token there.

If your threat model trusts the agent enough to read its own OAuth token
but not enough to read everything else in your Keychain (SSH passphrases,
browser passwords, AWS Vault items, signing keys), wholesale access is too
broad.

This wrapper lifts only the `Claude Code-credentials` Keychain item _before_
entering the sandbox, writes it to `~/.claude/.credentials.json` (claude's
plaintext fallback path), and unlinks it on exit. Inside the sandbox, only
the claude token is reachable.

The overlay then re-denies the mach-lookups and file paths that the
auto-included `keychain.sb` had allowed. Last-match-wins in SBPL.

## What's in the repo

```
overlay/claude-narrow.sb              The actual policy delta. ~50 lines.
bin/run-sandboxed.sh                  Wrapper that bridges creds + calls safehouse.
bin/safehouse-claude                  Thin entry-point: dispatches claude through the wrapper.
proxy/allowlist.txt                   Hostname allowlist for tinyproxy (POSIX ERE).
proxy/tinyproxy.conf.template
proxy/dev.safehouse.tinyproxy.plist.template
install.sh                            Verifies safehouse, drops files, templates configs.
```

## Install

Requirements:

- macOS with `sandbox-exec` (any modern macOS).
- [Agent Safehouse](https://github.com/eugene1g/agent-safehouse) on `PATH`:
  ```
  brew install eugene1g/safehouse/agent-safehouse
  ```
- `tinyproxy` for the egress filter (`brew install tinyproxy`).
- `~/.local/bin` on your `PATH`.

```
git clone https://github.com/lucagentile/safehouse-code-agents.git
cd safehouse-code-agents
./install.sh
```

The installer refuses to install without Safehouse present. Once it's there,
the installer copies the overlay + scripts to `~/.local/share/safehouse-code-agents/`,
templates the proxy configs for your user, symlinks the entry-points into
`~/.local/bin/`, and offers to load the proxy LaunchAgent.

## Use

```
safehouse-claude                              # Claude Code under the sandbox
safehouse-claude --resume <id>                # Same, with claude args
run-sandboxed.sh -- <any command>             # Generic dispatch through safehouse
run-sandboxed.sh --tight -- <cmd>             # Restrict RW grant to cwd only
```

### Namespace-aware RW grant

If you keep projects in a flat layout like
`~/Workspace/coding/<namespace>/<project>/...`, set `SAFEHOUSE_NAMESPACE_ROOT`
and the wrapper passes `--add-dirs=<root>/<ns>` to safehouse so the whole
namespace dir is RW (not just the project). Handy when an agent needs to
read sibling projects in the same org.

```
export SAFEHOUSE_NAMESPACE_ROOT="$HOME/Workspace/coding"
```

`--tight` overrides and always restricts to `cwd`.

### Env knobs

| Variable                    | Default                                | Effect                                              |
|-----------------------------|----------------------------------------|-----------------------------------------------------|
| `SAFEHOUSE_OVERLAY`         | `<install>/overlay/claude-narrow.sb`   | Path to the append-profile                          |
| `SAFEHOUSE_NAMESPACE_ROOT`  | unset                                  | If set, enable namespace-wide RW grant              |
| `SAFEHOUSE_PROXY_URL`       | `http://127.0.0.1:8118`                | Loopback proxy URL (empty string disables)          |
| `SAFEHOUSE_BRIDGE_CLAUDE`   | `1`                                    | Set to `0` to skip the Claude OAuth bridge          |
| `SAFEHOUSE_EXTRA_ARGS`      | unset                                  | Extra args passed verbatim to `safehouse`           |

### Git push over SSH

By default Safehouse denies the SSH agent socket, so `git@github.com:...`
remotes can't authenticate from inside the sandbox. To enable:

```
export SAFEHOUSE_EXTRA_ARGS="--enable=ssh"
```

That flips Safehouse's `ssh.sb` integration on, which re-opens the launchd
SSH socket. The wrapper preserves `SSH_AUTH_SOCK` so the sandboxed
process can find the agent. Keys stay denied (defense-in-depth); only
keys already loaded into the agent on the host can sign anything.

If you'd rather keep ssh denied, push over HTTPS instead - `gh auth token`
plus a stored credential helper works inside the sandbox without
relaxing the policy.

## How the credential bridge works

Claude Code stores its OAuth token in the macOS login Keychain as a generic
password item named `Claude Code-credentials`. The auto-included
`keychain.sb` Safehouse module grants wholesale Keychain access; our
overlay re-denies it. So we extract just the one item outside the sandbox:

```bash
security find-generic-password -s "Claude Code-credentials" -w \
    > "$HOME/.claude/.credentials.json"
trap 'rm -f "$HOME/.claude/.credentials.json"' EXIT INT TERM
```

Claude on macOS reads its Keychain backend first; when that fails (it will,
because we denied it), it falls back to `~/.claude/.credentials.json`,
which we just wrote.

The bridge owns this file end-to-end:

- **At launch**, it always overwrites with a fresh copy from the Keychain.
  This prevents a file leftover from a crashed previous session from
  shadowing the current Keychain entry with stale tokens (manifests as
  `API Error: 401 Invalid authentication credentials`).
- **On exit**, if the file's contents changed during the session (claude
  refreshed the access/refresh token), the new blob is written back into
  the Keychain via `security add-generic-password -U`, then the file is
  unlinked. The next launch picks up the refreshed tokens.

So token refresh keeps working across sandboxed sessions and stays in
sync with what unsandboxed claude would see in the Keychain. No
`/login` re-seed needed in the common case.

If you'd rather grant wholesale Keychain access (Safehouse's default),
use Safehouse directly and skip this wrapper.

## Diagnosing denials

When something fails under the sandbox:

```
log stream --style compact \
    --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "claude"'
```

Run `safehouse-claude` (or your command) in another window. Every deny
is printed with the syscall and path. Two paths to fix:

- If it's a missing allow in Safehouse's base: file an issue/PR against
  [eugene1g/agent-safehouse](https://github.com/eugene1g/agent-safehouse).
- If it's something our overlay should adjust: file an issue here.

## Relationship to Agent Safehouse

This is a downstream layer, not a fork. We don't ship a copy of Safehouse's
policy; we depend on the `safehouse` CLI at runtime via `--append-profile`.
When Safehouse updates, this repo benefits without any change here.

A previous version of this overlay also patched in a `file-ioctl` allow on
tty/pty paths to fix `tcsetattr` under the sandbox. That fix landed upstream
in Safehouse v0.10.0 ([PR #98](https://github.com/eugene1g/agent-safehouse/pull/98))
and was removed from the overlay.

## License

Apache-2.0. Matches Agent Safehouse.
