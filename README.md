# Learn From Scratch OpenHost Wrapper

OpenHost wrapper for `https://github.com/NayanaBannur/learn-from-scratch`.

This app runs one container with two owner-authenticated surfaces:

- `/` — the Learn From Scratch Vite frontend served from a live writable checkout.
- `/terminal/` — a `ttyd` terminal that starts Claude Code directly in that checkout for running the bundled `.claude/skills/learn-from-scratch` workflow.

The payload repo is cloned into `OPENHOST_APP_DATA_DIR/workspace/learn-from-scratch`, so generated topics and local content survive restarts/redeploys. The app requests `ANTHROPIC_API_KEY` from the OpenHost secrets service and exports it to the terminal/Vite process environment at startup; the key is not written to disk.

At startup, the wrapper seeds the persistent home under `OPENHOST_APP_DATA_DIR/workspace/home` with Claude Code config:

- `~/.claude/settings.json` sets dark theme and skips the dangerous-mode permission prompt.
- `~/.claude.json` is updated so the payload checkout is trusted and first-run onboarding is marked complete. If `CLAUDE_APPROVED_API_KEY_FINGERPRINT` is set, that Anthropic API key fingerprint is also pre-approved.
- `~/.bashrc` aliases `claude` to `claude --dangerously-skip-permissions` and enters the payload checkout.
- `~/.bash_profile` sources `~/.bashrc` for login shells.
- `~/start-claude.sh` starts Claude with `--dangerously-skip-permissions --continue` when a prior project transcript exists; otherwise it starts a fresh `claude --dangerously-skip-permissions` session.

Note: `ttyd` still appears to spawn one terminal process per browser/websocket connection. Reusing one server-side PTY across reconnects would likely require replacing/wrapping `ttyd` with a custom PTY websocket server.
