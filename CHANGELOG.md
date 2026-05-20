# Changelog

## Unreleased

- Overlay now allows `~/.ssh/*.pub` reads. Without this, SSH-based git
  commit signing fails inside the sandbox with `Couldn't load public key
  /Users/.../.ssh/id_rsa.pub` because Safehouse's `ssh.sb` integration
  re-opens the agent socket but leaves the rest of `~/.ssh/` denied.
  Public keys are public by definition; private keys stay denied.
- Added gh CLI token bridge. `gh auth token` is read on the host before
  entering the sandbox and exported as `GH_TOKEN` so the sandboxed gh CLI
  authenticates without Keychain access. Disable with `SAFEHOUSE_BRIDGE_GH=0`.
  Fixes the misleading `gh auth status` "The token in default is invalid"
  error inside the sandbox.
- Wrapper no longer unsets `SSH_AUTH_SOCK`. Combined with
  `SAFEHOUSE_EXTRA_ARGS="--enable=ssh"`, this lets `git push` over
  `git@github.com:...` work from inside the sandbox. The base policy still
  default-denies the socket unless `--enable=ssh` is set, so the previous
  default-deny behavior is preserved for users who don't set the env.
- Credential bridge: always overwrite `~/.claude/.credentials.json` at launch.
  Previously the bridge refused to clobber a pre-existing file as a safety
  guard, but in practice the only file ever in that path is one we wrote
  ourselves; a leftover from a crashed session was hiding the current
  Keychain token and producing `401 Invalid authentication credentials`.
- Credential bridge: on exit, if the credentials file changed during the
  session (claude refreshed its tokens), sync the new blob back into the
  Keychain before unlinking. Token refresh now persists across sandboxed
  sessions.

## Initial release

- Initial public release.
- Live dependency on [Agent Safehouse](https://github.com/eugene1g/agent-safehouse) >= 0.10.0.
  This repo is a thin overlay, not a fork.
- `overlay/claude-narrow.sb`: append-profile loaded last by Safehouse. Re-denies
  the wholesale Keychain access that Safehouse's auto-included `keychain.sb`
  grants. The companion `file-ioctl` allow on tty/pty paths (needed to make
  `tcsetattr` work under the sandbox) landed upstream in Safehouse v0.10.0 via
  [eugene1g/agent-safehouse#98](https://github.com/eugene1g/agent-safehouse/pull/98)
  and is not in this overlay.
- `bin/run-sandboxed.sh`: bridges the `Claude Code-credentials` Keychain item
  to `~/.claude/.credentials.json` before invoking `safehouse`, then unlinks
  on exit. Sets `HTTP_PROXY` for the loopback `tinyproxy` egress filter.
  Forwards `--add-dirs` to safehouse when `SAFEHOUSE_NAMESPACE_ROOT` is set.
- `bin/safehouse-claude`: entry-point that dispatches Claude Code through
  the wrapper.
- `install.sh`: verifies safehouse is on PATH, copies overlay + scripts,
  templates `tinyproxy.conf` and the LaunchAgent plist.
- Loopback `tinyproxy` setup with a hostname allowlist for HTTPS egress
  (Anthropic API, OpenAI API, GitHub, common package registries).
