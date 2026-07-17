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

Use the exact same arguments you used for `build-desktop-concurrent.sh`
originally. Quit the running duplicate before using the updater — the
rebuild will fail (or corrupt files) if the old copy still has files open.

## If you just want isolated data, not true concurrency

Use `build-desktop-launcher.sh` instead — it's simpler, doesn't touch
code signing at all, keeps every entitlement intact, and updates
automatically since it always launches the real `/Applications/Claude.app`.
The only cost is that you have to quit one profile before opening the
other.
