# Changelog

## Unreleased

- Initial public release.
- Live dependency on [Agent Safehouse](https://github.com/eugene1g/agent-safehouse).
  This repo is a thin overlay, not a fork.
- `overlay/claude-narrow.sb`: append-profile loaded last by Safehouse. Re-denies
  the wholesale Keychain access that Safehouse's auto-included `keychain.sb`
  grants, and adds `(allow file-ioctl ...)` on tty/pty paths to fix the
  kitty-keyboard escape leak under sandbox-exec.
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
