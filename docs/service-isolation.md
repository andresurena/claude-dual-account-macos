# Isolating other CLI tools per profile

`CLAUDE_CONFIG_DIR` only isolates Claude Code's own auth. It does **nothing**
for other CLIs — `gh`, `git`, `wrangler`, whatever else you use — because
none of them read that variable. Each one needs its own override, and the
mechanism differs per tool:

| Tool | Mechanism | Notes |
|---|---|---|
| GitHub CLI (`gh`) | `GH_TOKEN` env var (a Personal Access Token), not `gh auth login` | See warning below — `gh auth login`'s Keychain storage on macOS is **not** actually scoped by `GH_CONFIG_DIR` |
| Cloudflare `wrangler` | `WRANGLER_HOME` env var | Isolates wrangler's own OAuth/API token storage |
| git commit identity | native `includeIf "gitdir:...”` in `~/.gitconfig` | Directory-scoped, works from any tool (terminal, editor, GUI client) — not just direnv-aware shells |
| SSH-based git auth | `GIT_SSH_COMMAND` env var pointing at a specific key | Only needed if you use SSH remotes; skip if you use the `GH_TOKEN` approach above |
| Anything with a plain API key (no CLI login flow) | store the key in a file under your profile's config dir, `export` it from a file check | See pattern below |

## Warning: `gh auth login` + `GH_CONFIG_DIR` does NOT isolate on macOS

This looks like it should work — `GH_CONFIG_DIR` does move `gh`'s config
file (and its `hosts.yml` metadata, including the displayed account
*label*) to a separate location. But on macOS, `gh auth login` stores the
actual OAuth token in the **Keychain**, under a service name that is
**not** scoped by `GH_CONFIG_DIR`. In practice this means:

- Every `GH_CONFIG_DIR` you've ever used ends up reading the *same*
  underlying Keychain secret.
- Whichever `gh auth login` ran most recently, on **any** config,
  anywhere on the machine, silently becomes the real credential for
  *every* config.
- `gh auth status` still shows each config's own cached label (e.g.
  "Logged in as workaccount") even after the real token has been
  silently swapped out from under it — the label lies. The only way to
  check what's actually active is `gh api user --jq '.login'`, which
  makes a live API call instead of reading cached metadata.

This was found by hitting it directly: two accounts, each `gh auth
login`'d into its own `GH_CONFIG_DIR`, and creating a repo under what
`gh auth status` confidently reported as the correct account put it
under the *other* one instead.

**The fix**: don't use `gh auth login` for a secondary profile at all.
Generate a Personal Access Token for that account instead (GitHub →
Settings → Developer settings → Personal access tokens) and export it as
`GH_TOKEN`. `GH_TOKEN` takes precedence over anything Keychain-stored and
completely bypasses this problem. Keep `GH_CONFIG_DIR` too if you want
`gh`'s *preferences* (aliases, prompts, etc.) separate as well — just
don't rely on it for the actual credential.

## The general pattern

Most of this lives in the `.envrc` for the project folder(s) where you want
the second identity active (see the main README for the direnv setup). Add
whichever of these you actually need:

```bash
# GitHub CLI — GH_CONFIG_DIR alone is NOT enough, see warning above.
# Generate a Personal Access Token for the second account and drop it here.
export GH_CONFIG_DIR="$HOME/.claude-work/gh-config"
if [ -f "$HOME/.claude-work/github-token" ]; then
  export GH_TOKEN="$(cat "$HOME/.claude-work/github-token")"
fi

# Cloudflare
export WRANGLER_HOME="$HOME/.claude-work/wrangler-home"

# Any API-key-only service — drop the key in a file once, never hardcode it
if [ -f "$HOME/.claude-work/some-service-token" ]; then
  export SOME_SERVICE_API_KEY="$(cat "$HOME/.claude-work/some-service-token")"
fi
```

Then, once per tool, authenticate **from inside that project folder** so the
env var is active when the login flow runs:

```bash
cd /path/to/work-project
gh api user --jq '.login'   # verify the PAT above resolves to the right account
wrangler login               # isolated to WRANGLER_HOME
wrangler whoami               # sanity-check it's the right account before doing anything else
```

## git commit identity

Env vars only apply inside shells that load them (direnv-aware terminals).
GUI git clients and editors often don't inherit them. For commit
name/email specifically, use git's own directory-scoped config instead —
it works everywhere, regardless of how the tool was launched:

In `~/.gitconfig`:
```ini
[includeIf "gitdir:/path/to/work-project/"]
    path = ~/.claude-work/gitconfig-work
```

In `~/.claude-work/gitconfig-work`:
```ini
[user]
    name = Your Work Name
    email = you@work-email.example
```

Git evaluates `includeIf` blocks by the repository's actual location on
disk, so this applies correctly across every repo under that path tree.

## Automating a repeated action across many projects

If you need to run the same one-off command (e.g. setting the same secret)
across several project folders, a small loop script is usually simpler and
more transparent than reaching for an MCP connector or another integration:

```bash
#!/bin/zsh
# example: set a wrangler secret across every project that needs it
TOKEN_FILE="$HOME/.claude-work/some-service-token"
PROJECTS=("project-a" "project-b" "project-c")

for p in "${PROJECTS[@]}"; do
  dir="$HOME/Developer/work-projects/$p"
  echo "=== $p ==="
  (cd "$dir" && cat "$TOKEN_FILE" | wrangler secret put SOME_SERVICE_API_KEY)
done
```

This keeps the secret value flowing directly from a file into the target
tool's stdin — it's never echoed, logged, or passed through anything else.
