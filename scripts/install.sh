#!/bin/zsh
#
# Sets up an isolated "Work" (or any second) Claude Code profile alongside
# your existing default one, without ever touching ~/.claude.
#
# Safe to re-run — every step is idempotent.
#
# Usage:
#   ./install.sh
#
# Optional environment overrides (see README for details):
#   PROFILE_NAME     defaults to "work"      -> ~/.claude-<name>, claude-<name> command
#   BROWSER_APP       defaults to unset       -> e.g. "Microsoft Edge", "Google Chrome"
#                                                 (routes this profile's OAuth/browser opens
#                                                 to a specific browser, leaving your system
#                                                 default untouched for your main profile)

set -euo pipefail

PROFILE_NAME="${PROFILE_NAME:-work}"
CONFIG_DIR="$HOME/.claude-${PROFILE_NAME}"
WRAPPER_NAME="claude-${PROFILE_NAME}"
BROWSER_APP="${BROWSER_APP:-}"

echo "== Preflight checks =="

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found on PATH — install Claude Code first: https://claude.com/download"
  exit 1
fi
claude --version

for f in ~/.zshrc ~/.zprofile ~/.zshenv; do
  if [ -f "$f" ] && grep -qE "ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN" "$f"; then
    echo "WARNING: $f exports ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN."
    echo "         This silently overrides subscription logins for every profile,"
    echo "         including the one this script creates. Consider removing it."
  fi
done

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — install it first: https://brew.sh"
  exit 1
fi

echo
echo "== Creating $CONFIG_DIR and ~/bin =="
mkdir -p "$HOME/bin"
mkdir -p "$CONFIG_DIR"

echo
echo "== Writing wrapper: ~/bin/$WRAPPER_NAME =="
cat > "$HOME/bin/$WRAPPER_NAME" <<WRAPPER
#!/bin/zsh
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
if [ -f "$CONFIG_DIR/token" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="\$(cat "$CONFIG_DIR/token")"
fi
WRAPPER

if [ -n "$BROWSER_APP" ]; then
  mkdir -p "$CONFIG_DIR/bin"
  cat > "$CONFIG_DIR/bin/open" <<SHIM
#!/bin/zsh
# Routes this profile's browser opens (OAuth logins, links) to a specific
# browser instead of the system default, so its cookies/session stay out
# of your everyday browsing profile.
exec /usr/bin/open -a "$BROWSER_APP" "\$@"
SHIM
  chmod +x "$CONFIG_DIR/bin/open"
  cat >> "$HOME/bin/$WRAPPER_NAME" <<WRAPPER
export PATH="$CONFIG_DIR/bin:\$PATH"
WRAPPER
fi

cat >> "$HOME/bin/$WRAPPER_NAME" <<WRAPPER
exec claude "\$@"
WRAPPER
chmod +x "$HOME/bin/$WRAPPER_NAME"

echo
echo "== Installing direnv =="
if ! command -v direnv >/dev/null 2>&1; then
  brew install direnv
else
  echo "direnv already installed"
fi

echo
echo "== Updating ~/.zshrc (idempotent marker block) =="
MARKER_START="# >>> claude-dual-${PROFILE_NAME} >>>"
MARKER_END="# <<< claude-dual-${PROFILE_NAME} <<<"

if [ -f ~/.zshrc ] && grep -qF "$MARKER_START" ~/.zshrc; then
  echo "marker block already present, skipping"
else
  if [ -f ~/.zshrc ]; then
    cp ~/.zshrc ~/.zshrc.bak-"$(date +%Y%m%d)"
    echo "backed up ~/.zshrc"
  fi
  {
    echo ""
    echo "$MARKER_START"
    echo 'export PATH="$HOME/bin:$PATH"'
    echo 'eval "$(direnv hook zsh)"'
    echo "$MARKER_END"
  } >> ~/.zshrc
  echo "added marker block to ~/.zshrc"
fi

echo
echo "== Writing reusable direnv template =="
cat > "$CONFIG_DIR/envrc-template" <<ENVRC
# ${PROFILE_NAME} profile — direnv template
#
# Usage:
#   1. Copy into a project as .envrc:
#        cp $CONFIG_DIR/envrc-template /path/to/project/.envrc
#   2. Run \`direnv allow\` inside that project directory.
#   3. Add .envrc to that project's .gitignore (it may end up holding a token).
#
# Once allowed, running \`claude\` inside this directory (or any subdirectory)
# automatically uses this profile — no need for the $WRAPPER_NAME command.

export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
if [ -f "$CONFIG_DIR/token" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="\$(cat "$CONFIG_DIR/token")"
fi
ENVRC

if [ -n "$BROWSER_APP" ]; then
  cat >> "$CONFIG_DIR/envrc-template" <<ENVRC

# Routes browser opens (OAuth, etc.) to $BROWSER_APP instead of the system default.
export PATH="$CONFIG_DIR/bin:\$PATH"
ENVRC
fi

cat >> "$CONFIG_DIR/envrc-template" <<'ENVRC'

# --- Optional: isolate other CLI tools the same way ---
# Most CLIs that support multiple machines/accounts read their config
# location from an env var. A few common ones:
#
#   GitHub CLI:  DO NOT rely on `gh auth login` + GH_CONFIG_DIR for this —
#                on macOS, gh's Keychain-stored token is NOT scoped by
#                GH_CONFIG_DIR, so logging into ANY gh config anywhere on
#                the machine silently overwrites the credential every
#                other "isolated" config resolves to (see docs/service-
#                isolation.md for how this was discovered). Use a
#                Personal Access Token instead:
#                  export GH_CONFIG_DIR="$CONFIG_DIR/gh-config"
#                  if [ -f "$CONFIG_DIR/github-token" ]; then
#                    export GH_TOKEN="$(cat "$CONFIG_DIR/github-token")"
#                  fi
#   Cloudflare:  DO NOT rely on WRANGLER_HOME — it is not a real
#                wrangler config variable at all (confirmed against
#                wrangler --help and Cloudflare's own docs; it silently
#                does nothing). Use an API Token instead:
#                  if [ -f "$CONFIG_DIR/cloudflare-token" ]; then
#                    export CLOUDFLARE_API_TOKEN="$(cat "$CONFIG_DIR/cloudflare-token")"
#                  fi
#   Anything else with just an API key (no CLI login flow): store the key
#   in a file under $CONFIG_DIR and export it here, e.g.:
#     if [ -f "$CONFIG_DIR/some-service-token" ]; then
#       export SOME_SERVICE_API_KEY="$(cat "$CONFIG_DIR/some-service-token")"
#     fi
#
# For a separate git commit identity in this folder, add to ~/.gitconfig:
#   [includeIf "gitdir:/path/to/this/project/"]
#       path = $CONFIG_DIR/gitconfig-work
ENVRC

echo
echo "Done."
echo
echo "Remaining manual steps:"
echo "  1. Log into the second account in a browser, then run:"
echo "       $WRAPPER_NAME setup-token"
echo "     (or just launch $WRAPPER_NAME and complete OAuth when prompted)"
echo "  2. Save the resulting token to $CONFIG_DIR/token and chmod 600 it,"
echo "     OR just stay logged in via the OAuth session $WRAPPER_NAME creates."
echo "  3. Run /status inside $WRAPPER_NAME to confirm the right account."
echo "  4. Desktop app: quit your main Claude Desktop before authenticating"
echo "     a second one under the same install (see docs/desktop-app.md)."
