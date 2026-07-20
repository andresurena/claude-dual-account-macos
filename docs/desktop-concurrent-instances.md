# Running two Claude Desktop instances at the same time

> **Unsupported.** This ad-hoc re-signs a duplicated copy of Claude.app.
> It works, but it's not something Anthropic ships or supports, and it
> has real trade-offs — read this whole page before using it.

## Why the simple approach isn't enough

`scripts/build-desktop-launcher.sh` gives Claude Desktop an isolated
profile via Electron's `--user-data-dir` flag — separate cookies and
separate chat-UI login (plus, since both scripts now also export
`CLAUDE_CONFIG_DIR`, a separate Claude Code backend too — see the
gotcha in the main README if you're not familiar with why that second
env var matters). But it still launches the *same*
`/Applications/Claude.app` bundle, and macOS only allows one running
instance per app identity (bundle ID) at a time. Launch a second one and
macOS just re-activates the first — you don't get a second window.

To get true concurrency, the duplicate needs its **own bundle
identity**, not just its own data.

## What `build-desktop-concurrent.sh` actually does

1. **Copies** the entire `Claude.app` bundle (`ditto`, preserves
   permissions/signatures) to a location you choose.
2. **Renames the Helper apps.** Electron looks up its helper processes
   (GPU, renderer, plugin, network) by a name derived from
   `CFBundleName` — `"<CFBundleName> Helper.app"`, etc. If you rename the
   main app without renaming these to match, it fails at launch with
   *"Unable to find helper app"*. The script renames all four helper
   bundles (and their internal executables and each one's own
   `Info.plist`) to match the new name.
3. **Rebrands the main `Info.plist`** — `CFBundleName`,
   `CFBundleDisplayName`, and `CFBundleIdentifier`. The main executable's
   *filename* does not need to change — macOS launches it directly by
   whatever `CFBundleExecutable` says, regardless of the product name.
4. **Replaces the icon**, if you provide one. Modern app bundles often
   ship a compiled asset catalog (`Assets.car`) that silently overrides
   the legacy `CFBundleIconFile` `.icns` — and it isn't practically
   editable outside Xcode. The script moves it aside and removes the
   `CFBundleIconName` key so the system falls back to the `.icns` file,
   which it then overwrites with your icon.
5. **Re-signs the whole thing ad-hoc** (`codesign --force --deep -s -`).
   This is what actually breaks entitlements — see below.
6. **Builds a small launcher app** (same AppleScript-compile technique as
   the other scripts) that runs the duplicate with its own
   `--user-data-dir` and, optionally, routes its browser opens to a
   specific browser.

## The real trade-offs

- **Entitlements are gone.** Ad-hoc signing (`-s -`, no real Developer
  ID) can't carry the original entitlements (keychain access groups,
  camera/mic, and — notably — `com.apple.security.virtualization`).
  In practice, this means any feature that depends on those — for
  Claude Desktop specifically, the local VM / "computer use" sandbox
  feature — will report itself as unsupported
  (`virtualization_entitlement_missing`) in the duplicate. Regular
  chat and coding use is unaffected.
- **It won't auto-update.** The duplicate is a point-in-time copy.
  Re-run the script after every Claude Desktop update to refresh it —
  otherwise you're running a stale version indefinitely. `ditto`
  preserves the original files' modification times when it copies them,
  so don't rely on the duplicate's file timestamps to tell whether a
  refresh actually happened — check `CFBundleShortVersionString` in its
  `Info.plist` instead, or just compare against `/Applications/Claude.app`'s
  version.
  To make this a one-click habit instead of a remembered command, see
  `build-update-helper.sh` below — it builds a small app that re-runs
  this whole script with your saved parameters.
- **It's a full copy on disk.** Expect 700MB+ per duplicate.
- **Gatekeeper won't fully trust it.** `codesign -v` passes (the
  signature is internally consistent), but `spctl -a` will report it as
  rejected, same as any ad-hoc-signed app. This doesn't block normal
  launches (Gatekeeper's stricter policy check mainly applies to
  quarantined/downloaded files, not locally-built ones) — just don't
  expect it to pass a full Gatekeeper assessment.
- **Pinning the launcher app to the Dock shows two icons, not one — and
  you should leave it that way.** The launcher (what you drag to the
  Dock) and the actual running duplicate are two genuinely different
  bundle identities (see [What `build-desktop-concurrent.sh` actually
  does](#what-build-desktop-concurrentsh-actually-does) above — the
  launcher just execs the duplicate and exits). macOS's Dock only merges
  a pinned icon with a running process when they share the same bundle
  ID, so you'll see the static pinned launcher icon *and* a separate
  temporary icon for the running duplicate while it's open. This is
  cosmetic, not a bug.
  **Do not** right-click that second (running) icon and choose "Keep in
  Dock" to try to clean this up — that pins the duplicate's raw binary
  directly, bypassing the launcher's environment setup (`CLAUDE_CONFIG_DIR`,
  browser routing) entirely. Launching it that way silently reintroduces
  the isolation gap described in the main README's gotchas — the exact
  failure this whole setup exists to prevent. Keep using the launcher's
  icon; treat the extra temporary icon as noise.

## LaunchServices can accumulate stale registrations — clean up after
## deleting an old duplicate, don't just `rm -rf` it

If you ever manually delete a duplicate built by this script (or an
older experiment/app you're replacing), macOS's LaunchServices database
can keep a registration pointing at the now-missing path indefinitely —
`rm -rf` alone doesn't unregister it. These stale entries are dead
weight at best, but at worst they can genuinely resurface: hit this
directly, where ghost registrations from a deleted app (nested,
non-obviously, inside a name that fuzzy-matched a current app) coincided
with `claude://` deep links intermittently misbehaving again after they'd
already been fixed once.

Clean up properly instead of just deleting the folder:

```bash
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -u "/path/to/the/deleted/app.app"   # unregister the specific stale path
"$LSREGISTER" -gc                                  # garbage-collect + compact the database
```

Check for ghosts with `"$LSREGISTER" -dump 2>/dev/null | grep -B5 "path:.*your-search-term"` —
if a `path:` line points at something `ls` says doesn't exist, it's a
ghost worth unregistering.

**A sharper-edged finding from the same investigation**: `lsregister -f`
(force-refresh a specific app's registration) is not risk-free to run
speculatively. Re-registering the launcher and the duplicate right after
a `duti -s ... claude` pin (to "make sure everything's fresh") flipped
the deep-link handler back to the *wrong* app — the opposite of what was
intended, undoing a pin that had just been verified working. The
reliable sequence is: do any `lsregister` cleanup/refresh work *first*,
then apply the explicit `duti -s <real-bundle-id> <scheme>` pin as the
very last step, and verify behaviorally afterward (`open scheme://test`,
check what launched) — not the other way around, and don't re-run
`lsregister -f` "just to be safe" after the pin is already confirmed
correct.

## Usage

```
./scripts/build-desktop-concurrent.sh "My Second Claude" \
    ~/.claude-second/core \
    ~/.claude-second/desktop-profile \
    ~/.claude-second \
    "Microsoft Edge" \
    ~/my-icon.icns
```

The fourth argument (`CLAUDE_CONFIG_DIR`, e.g. `~/.claude-second`) is
required — it's what isolates the embedded Code backend, not just the
Electron profile; see the gotcha in the main README. Browser-app and icon
are optional — pass empty strings to skip either.

## Keeping it updated with one click

Since the duplicate needs re-running after every Claude Desktop update,
`build-update-helper.sh` builds a small "Update <App Name>.app" that does
that for you — double-click it, it opens Terminal, re-runs
`build-desktop-concurrent.sh` with the same parameters, and tells you
when it's done:

```
./scripts/build-update-helper.sh "My Second Claude" \
    ~/.claude-second/core \
    ~/.claude-second/desktop-profile \
    ~/.claude-second \
    "Microsoft Edge" \
    ~/my-icon.icns
```

By default the generated app is named "Update My Second Claude" — pass a
seventh argument to override that. You can also have it back up session
transcripts (via `backup-claude-sessions.sh`) immediately before every
rebuild, by adding a backup destination and one or more config
directories after that:

```
./scripts/build-update-helper.sh "My Second Claude" \
    ~/.claude-second/core \
    ~/.claude-second/desktop-profile \
    ~/.claude-second \
    "Microsoft Edge" \
    ~/my-icon.icns \
    "My Second Claude Updater" \
    ~/Claude-Session-Backups ~/.claude ~/.claude-second
```

Use the exact same arguments you used for `build-desktop-concurrent.sh`
originally. Quit the running duplicate before using the updater — the
rebuild will fail (or corrupt files) if the old copy still has files open.

## If you just want isolated data, not true concurrency

Use `build-desktop-launcher.sh` instead — it's simpler, doesn't touch
code signing at all, keeps every entitlement intact, and updates
automatically since it always launches the real `/Applications/Claude.app`.
The only cost is that you have to quit one profile before opening the
other.
