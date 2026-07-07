#!/usr/bin/env bash
set -euo pipefail

APP_DATA_DIR="${OPENHOST_APP_DATA_DIR:-/workspace}"
WORKSPACE_DIR="$APP_DATA_DIR/workspace"
APP_DIR="$WORKSPACE_DIR/learn-from-scratch"
HOME_DIR="$WORKSPACE_DIR/home"
SECRETS_URL="${OPENHOST_ROUTER_URL:-}/api/services/v2/call/secrets/get"

mkdir -p "$WORKSPACE_DIR" "$HOME_DIR"
export HOME="$HOME_DIR"

clone_or_update_payload() {
    if [ ! -d "$APP_DIR/.git" ]; then
        rm -rf "$APP_DIR"
        git clone --branch "$PAYLOAD_REF" "$PAYLOAD_REPO" "$APP_DIR"
        return
    fi

    git -C "$APP_DIR" fetch origin "$PAYLOAD_REF"
    if git -C "$APP_DIR" diff --quiet && git -C "$APP_DIR" diff --cached --quiet; then
        git -C "$APP_DIR" merge --ff-only "origin/$PAYLOAD_REF" || true
    else
        echo "payload checkout has local tracked changes; skipping update"
    fi
}

install_dependencies() {
    cd "$APP_DIR"
    local stamp="$WORKSPACE_DIR/package-lock.sha256"
    local current
    current="$(sha256sum package-lock.json | awk '{print $1}')"
    if [ ! -d node_modules ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$current" ]; then
        npm ci
        echo "$current" > "$stamp"
    fi
}

fetch_anthropic_key() {
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        return
    fi
    if [ -z "${OPENHOST_ROUTER_URL:-}" ] || [ -z "${OPENHOST_APP_TOKEN:-}" ]; then
        echo "OpenHost service env missing; ANTHROPIC_API_KEY not fetched"
        return
    fi

    local key
    key="$(curl -fsS \
        -H "Authorization: Bearer $OPENHOST_APP_TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"keys":["ANTHROPIC_API_KEY"]}' \
        "$SECRETS_URL" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("secrets", {}).get("ANTHROPIC_API_KEY", ""))')" || true
    if [ -n "$key" ]; then
        export ANTHROPIC_API_KEY="$key"
    else
        echo "ANTHROPIC_API_KEY not available from OpenHost secrets"
    fi
}

write_shell_profile() {
    mkdir -p "$HOME/.claude"

    cat > "$HOME/.claude/settings.json" <<EOF
{
  "skipDangerousModePermissionPrompt": true,
  "theme": "dark"
}
EOF

    python3 - <<PY
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

claude_json_path = Path("$HOME/.claude.json")
if claude_json_path.exists():
    data = json.loads(claude_json_path.read_text())
else:
    data = {}

version_output = subprocess.run(
    ["claude", "--version"],
    check=False,
    capture_output=True,
    text=True,
).stdout
version_match = re.search(r"\d+\.\d+\.\d+", version_output)
claude_version = version_match.group(0) if version_match else "2.1.202"

# Claude stores API-key prompt acceptance as a key fingerprint, not the raw key.
# The default below is the observed fingerprint for the OpenHost ANTHROPIC_API_KEY
# secret used by this deployment. Override CLAUDE_APPROVED_API_KEY_FINGERPRINT
# if the secret changes.
api_key_approval = "${CLAUDE_APPROVED_API_KEY_FINGERPRINT:-6GXslczdmtA-K6gnywAA}"
if api_key_approval:
    data["customApiKeyResponses"] = {
        "approved": [api_key_approval],
        "rejected": [],
    }

data.setdefault("firstStartTime", datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
data["hasCompletedOnboarding"] = True
data["lastOnboardingVersion"] = claude_version
data["lastReleaseNotesSeen"] = claude_version
data["numStartups"] = data.get("numStartups", 0)

projects = data.setdefault("projects", {})
project = projects.setdefault("$APP_DIR", {})
project.update({
    "allowedTools": project.get("allowedTools", []),
    "mcpContextUris": project.get("mcpContextUris", []),
    "mcpServers": project.get("mcpServers", {}),
    "enabledMcpjsonServers": project.get("enabledMcpjsonServers", []),
    "disabledMcpjsonServers": project.get("disabledMcpjsonServers", []),
    "hasTrustDialogAccepted": True,
    "projectOnboardingSeenCount": project.get("projectOnboardingSeenCount", 1),
    "hasClaudeMdExternalIncludesApproved": project.get("hasClaudeMdExternalIncludesApproved", False),
    "hasClaudeMdExternalIncludesWarningShown": project.get("hasClaudeMdExternalIncludesWarningShown", False),
})

claude_json_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

    cat > "$HOME/.bashrc" <<EOF
export HOME="$HOME"
export IS_SANDBOX=1
alias claude="claude --dangerously-skip-permissions"
cd "$APP_DIR"
echo "Learn From Scratch workspace: $APP_DIR"
echo "Run the bundled skill from Claude Code with: /learn-from-scratch <topic>"
EOF

    cat > "$HOME/.bash_profile" <<'EOF'
# Source interactive shell setup for ttyd login shells.
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOF
}

write_claude_startup() {
    cat > "$HOME/start-claude.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export HOME="$HOME"
export IS_SANDBOX=1
cd "$APP_DIR"

if find "$HOME/.claude/projects" -name '*.jsonl' -type f -print -quit 2>/dev/null | grep -q .; then
    exec claude --dangerously-skip-permissions --continue
fi

exec claude --dangerously-skip-permissions
EOF
    chmod +x "$HOME/start-claude.sh"
}

clone_or_update_payload
install_dependencies
fetch_anthropic_key
write_shell_profile
write_claude_startup

cd "$APP_DIR"

npm run dev -- --host 0.0.0.0 --port "$VITE_PORT" --base /app/ &
vite_pid=$!

ttyd --writable --port "$TTYD_PORT" --base-path /terminal "$HOME/start-claude.sh" &
ttyd_pid=$!

caddy run --config /app/Caddyfile --adapter caddyfile &
caddy_pid=$!

trap 'kill "$vite_pid" "$ttyd_pid" "$caddy_pid" 2>/dev/null || true' EXIT
wait -n "$vite_pid" "$ttyd_pid" "$caddy_pid"
