# claude-dual-account-macos

Run two fully-isolated Claude Code / Claude Desktop identities on the same
Mac — e.g. a Personal account and a Work account — with separate logins,
separate config, and (optionally) separate browser sessions and CLI tool
auth (GitHub, Cloudflare, etc.), without ever touching your existing
`~/.claude` install.

**Unofficial.** Not affiliated with or endorsed by Anthropic. Built by
hitting real edge cases while setting this up by hand; sharing it so
others don't have to rediscover the same gotchas.

## Why

Claude Code and Claude Desktop are built around a single logged-in
identity per machine. If you need two — say, a personal subscription and
a company one — the built-in answer is "log out, log back in" every time
you switch. This repo automates the alternative: two coexisting,
independently-authenticated profiles, switchable by which terminal/app
you use or which project folder you're in.

## What's here

| Script | What it does |
|---|---|
| `scripts/install.sh` | Core setup: isolated `CLAUDE_CONFIG_DIR`, a `claude-<profile>` wrapper command, direnv per-project auto-switching, optional browser routing |
| `scripts/build-cli-launcher.sh` | Builds a double-clickable app that opens Terminal into a project folder and launches your wrapper command |
| `scripts/build-desktop-launcher.sh` | Builds a double-clickable app that launches Claude Desktop with an isolated profile (simple, fully supported — see caveats below) |
| `scripts/build-desktop-concurrent.sh` | **Advanced/unsupported**: duplicates Claude Desktop so two instances can run *at the same time*. Real trade-offs — read [`docs/desktop-concurrent-instances.md`](docs/desktop-concurrent-instances.md) first |
| `scripts/build-icns-from-image.sh` | Builds a proper multi-resolution `.icns` from a single source image, for custom app icons |
| `scripts/pin-deep-link.sh` | Pins the `claude://` URL scheme to a specific app, once you have more than one Claude-branded `.app` installed |
| `docs/service-isolation.md` | Extending the same pattern to `gh`, `wrangler`, git commit identity, and plain API-key services |

## Quick start

```bash
git clone <this-repo>
cd claude-dual-account-macos
chmod +x scripts/*.sh

# Basic: creates ~/.claude-work + a `claude-work` command
./scripts/install.sh

# With browser routing (recommended if you use a different browser for
# each identity — keeps OAuth/session cookies separate too):
PROFILE_NAME=work BROWSER_APP="Microsoft Edge" ./scripts/install.sh
```

Then, per the script's own output:

1. Log into the second account: run `claude-work setup-token` (or just
   launch `claude-work` and complete OAuth when prompted — it'll open in
   whatever browser you set via `BROWSER_APP`, separate from your system
   default).
2. Run `/status` inside `claude-work` to confirm the right account.
3. For any project folder you want to always use this profile in:
   ```bash
   cp ~/.claude-work/envrc-template /path/to/project/.envrc
   cd /path/to/project && direnv allow
   echo .envrc >> .gitignore   # it can end up holding a token
   ```
   Now `claude` run from inside that folder (or any subfolder) uses the
   second profile automatically — no need for the wrapper command there.

## Building the launcher apps (optional)

If you'd rather double-click an app than remember a command:

```bash
# Terminal-based launcher — opens Terminal, cd's into a project, runs claude-work
./scripts/build-cli-launcher.sh "Claude Work" "claude-work" \
    "$HOME/Developer/work-projects" "$HOME/my-icon.icns"

# Desktop launcher — isolated profile, same Claude.app identity
# (can't run at the same time as your main Claude Desktop — see below)
./scripts/build-desktop-launcher.sh "Claude Work Desktop" \
    "$HOME/.claude-work/desktop-profile" "Microsoft Edge" "$HOME/my-icon.icns"
```

Both take an optional `.icns` path as the last argument. If you only have
a single high-res image (not a pre-made `.icns`), build one first:

```bash
./scripts/build-icns-from-image.sh my-logo.png my-icon.icns
```

### Wanting both Desktop apps open at once?

`build-desktop-launcher.sh` isolates data but shares Claude Desktop's app
identity — macOS only runs one instance per identity, so you still have
to quit one before opening the other. If you actually need both windows
open simultaneously, see
[`docs/desktop-concurrent-instances.md`](docs/desktop-concurrent-instances.md)
for `build-desktop-concurrent.sh` and its trade-offs (ad-hoc code signing,
lost entitlements, manual updates) before using it.

## Isolating other CLI tools (GitHub, Cloudflare, etc.)

`CLAUDE_CONFIG_DIR` only isolates Claude's own auth. Extending the same
idea to `gh`, `wrangler`, git commit identity, or any API-key-based
service is covered in
[`docs/service-isolation.md`](docs/service-isolation.md).

## Deep link pinning

If you end up with more than one Claude-branded `.app` on the same Mac,
`claude://` links can open whichever one macOS feels like. Pin it
explicitly:

```bash
./scripts/pin-deep-link.sh /Applications/Claude.app
```

## Known gotchas (already handled by these scripts, documented here so you understand *why*)

- **A shell-script `.app` executable can trigger a false "Intel app /
  requires Rosetta" notification on Apple Silicon.** macOS's
  LaunchServices identifies an app's architecture from its
  `CFBundleExecutable`; a raw shell script isn't a Mach-O binary and can
  get misidentified. `osacompile` (AppleScript) produces a genuine
  universal arm64/x86_64 binary, which avoids this — that's why every
  launcher script here uses it instead of a plain shell wrapper.
- **Renaming an Electron app's `CFBundleName` breaks it** with "Unable to
  find helper app" unless you also rename its Helper `.app` bundles to
  match — Electron looks them up by a name derived from `CFBundleName`,
  not by a fixed path. Handled in `build-desktop-concurrent.sh`.
- **A compiled asset catalog (`Assets.car`) silently overrides a legacy
  `.icns` icon file.** If your icon change doesn't seem to take effect on
  a duplicated/re-signed app, check for this — see
  `build-desktop-concurrent.sh` for how it's neutralized.
- **Editing a direnv `.envrc` after the last `direnv allow` blocks it**
  until you run `direnv allow` again — direnv re-checksums the file on
  every change as a security measure.
- **`gh auth login` + `GH_CONFIG_DIR` does not actually isolate GitHub CLI
  auth on macOS.** The Keychain-stored token isn't scoped by
  `GH_CONFIG_DIR` — logging into any `gh` config anywhere on the machine
  silently overwrites the real credential every other "isolated" config
  resolves to, while `gh auth status` keeps showing each config's own
  (now-stale) cached label. Found by hitting it directly — see
  [`docs/service-isolation.md`](docs/service-isolation.md) for the fix
  (a Personal Access Token via `GH_TOKEN`, which bypasses the Keychain
  entirely).

## Safety notes

- Nothing here touches your existing `~/.claude` install or its
  credentials.
- `install.sh` backs up `~/.zshrc` (as `~/.zshrc.bak-<date>`) before its
  first edit, and every change it makes lives inside an idempotent marker
  block — safe to re-run any time.
- Ad-hoc code signing (used by the app-builder scripts) is fine for local
  use but isn't equivalent to a real Developer ID signature — see the
  concurrent-instances doc for what that trades away.

## License

MIT — see [LICENSE](LICENSE).
