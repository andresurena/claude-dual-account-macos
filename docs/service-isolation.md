# Isolating other CLI tools per profile

`CLAUDE_CONFIG_DIR` only isolates Claude Code's own auth. It does **nothing**
for other CLIs — `gh`, `git`, `wrangler`, whatever else you use — because
none of them read that variable. Each one needs its own override, and the
mechanism differs per tool:

| Tool | Mechanism | Notes |
|---|---|---|
| GitHub CLI (`gh`) | `GH_TOKEN` env var (a Personal Access Token), not `gh auth login` | See warning below — `gh auth login`'s Keychain storage on macOS is **not** actually scoped by `GH_CONFIG_DIR` |
| Cloudflare `wrangler` | `CLOUDFLARE_API_TOKEN` env var (an API Token), not `wrangler login` | See warning below — `WRANGLER_HOME` is **not a real wrangler variable at all** |
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

**Which token type**: prefer a **fine-grained token**, scoped to just the
repos you need (Contents: read/write, Pull requests: read/write if you
use PRs), over a classic token. Classic tokens with `repo` scope grant
access to *every* repo the account can touch, which is more than a
secondary-profile setup needs. Fine-grained tokens do require org-admin
approval on organization-owned repos with restrictive settings — not an
issue for a personal account's own repos.

**Verifying the token file without ever printing the secret**: once
you've saved it (e.g. `pbpaste | tr -d '\n' > ~/.claude-work/github-token`
— pipe directly from clipboard, don't retype it), check its *shape*
instead of its content:

```bash
stat -f "size: %z bytes" ~/.claude-work/github-token   # sanity-check length
head -c 11 ~/.claude-work/github-token; echo            # expect: github_pat_
tail -c 1 ~/.claude-work/github-token | xxd              # expect NOT 0a (no trailing newline)
wc -l ~/.claude-work/github-token                        # expect: 0 (single line, no newline)
```

Three real mistakes worth calling out, all hit directly while building this:

- **Clipboard contents can be stale.** If you copy something else (a
  command, a message) *after* copying the token but *before* running the
  `pbpaste` command, the file silently fills with the wrong text instead
  of erroring — the structural checks above catch this immediately
  (wrong prefix, wrong length), whereas trying to eyeball the actual
  token wouldn't.
- **Never `echo`/`cat` an env var holding a live secret to check it's
  set.** `${GH_TOKEN:-NO}` prints the literal value if set — use
  `${GH_TOKEN:+yes}${GH_TOKEN:-no}` (prints only `yes`/`no`) or a length
  check instead.
- **A terminal window's scrollback is a secret-storage location too,**
  not just the commands you type. Something as innocuous as reading back
  a Terminal window's full contents (e.g. to check on a long-running
  command, or via `osascript`/screen-reading automation) can resurface a
  secret that was displayed on-screen many commands ago and never
  scrolled out of the buffer — even if the *current* command has nothing
  to do with secrets. Long-lived terminal sessions that have handled
  tokens are worth closing once you're done with that task, not kept
  open indefinitely.

If a secret does end up printed anywhere — terminal output, a log, an
assistant's response — treat it as compromised and rotate it immediately.
Don't assume it's fine because "it was only visible to me"; the safe
default is to always rotate, since verifying no copy persisted anywhere
is harder than just generating a new one.

## Warning: `WRANGLER_HOME` is not a real wrangler variable

Earlier versions of this guide recommended `export
WRANGLER_HOME="$HOME/.claude-work/wrangler-home"` to isolate wrangler's
OAuth login the same way `GH_CONFIG_DIR` isolates `gh`'s. **This was
wrong — `WRANGLER_HOME` doesn't exist.** It never appeared in `wrangler
--help`, `wrangler login --help`, or Cloudflare's own [environment
variables documentation](https://developers.cloudflare.com/workers/wrangler/system-environment-variables/).
Setting it did nothing at all, silently — no error, no warning, wrangler
simply ignored it and kept using its one shared, default-location login
for every profile on the machine.

This surfaced days later as a runtime error: a Worker's KV write failed
with a 401 (`Save failed (401). Check the KV binding / network.`)
because `wrangler dev` had been authenticating as the wrong (default,
Personal) Cloudflare account the entire time — not because of a
misconfigured binding, which is what the error message pointed at.

**The fix**: same pattern as `GH_TOKEN`. Generate a Cloudflare API Token
(Cloudflare dashboard → profile icon → **API Tokens** → **Create Token**
→ **Create Custom Token**), scoped to exactly the permissions the
project needs (e.g. **Workers KV Storage: Edit**, **Workers Scripts:
Edit**) and restricted to the **specific account** you want, not "All
accounts" — restricting to one account is what actually prevents the
ambiguity that caused the 401 here. Export it as `CLOUDFLARE_API_TOKEN`;
wrangler reads it directly and it takes precedence over any OAuth login
state, bypassing the whole problem.

Verify which account is actually active with `wrangler whoami` — same
principle as `gh api user --jq '.login'` above: check the tool's live,
real answer, not an assumption about which env var should have worked.

**The broader lesson, not just about wrangler**: an env var that "should"
isolate a tool, based on the naming convention other tools use, is a
hypothesis until it's checked against that tool's own documentation or
`--help` output. Two different CLIs on this same project (`gh` and
`wrangler`) each turned out to need a *different* real mechanism than
what was first assumed — there's no way to guess this reliably. When in
doubt: verify with `--help`, official docs, or the vendor's environment-
variable reference, not by pattern-matching against a similar tool.

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

# Cloudflare — WRANGLER_HOME is NOT enough, see warning above.
# Generate an API Token for the second account and drop it here.
if [ -f "$HOME/.claude-work/cloudflare-token" ]; then
  export CLOUDFLARE_API_TOKEN="$(cat "$HOME/.claude-work/cloudflare-token")"
fi

# Any API-key-only service — drop the key in a file once, never hardcode it
if [ -f "$HOME/.claude-work/some-service-token" ]; then
  export SOME_SERVICE_API_KEY="$(cat "$HOME/.claude-work/some-service-token")"
fi
```

Then, from inside that project folder, verify each token actually
resolves to the right account **before doing anything else** — don't
trust that setting the env var alone was sufficient:

```bash
cd /path/to/work-project
gh api user --jq '.login'   # verify the GH_TOKEN above resolves to the right account
wrangler whoami               # verify the CLOUDFLARE_API_TOKEN above resolves to the right account
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
