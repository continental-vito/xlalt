# Architecture and safety model

## Safety model (read before touching the tap code)

The engine listens to keyboard events through macOS event taps. macOS **holds keyboard delivery for the entire system** while a tap callback runs, which imposes three hard rules, all enforced by tests:

0. **Which host is frontmost is asked, never inferred.** `syncFrontmost()` queries `frontmostApplication()` and is the single writer of `ExcelAlt.activeApp`. Every app-watcher event calls it, plus a 0.2 s one-shot to let a switch settle. Deriving the state from the event type instead was a bug: a host that activated and then emitted any further event (`launched`, `unhidden`, a duplicate) had its state cleared while still in front, leaving the taps down until something unrelated forced an update. This is a window-server call, so it is allowed **only** here — on app switches, outside every tap callback.

1. **Taps run only while a supported host is frontmost.** An `hs.application.watcher` starts them when Excel, PowerPoint or Word activates and stops them the moment anything else takes focus. Outside those three the app touches no events at all. Which host is frontmost is cached in `ExcelAlt.activeApp`; a host the user has switched off in the manager keeps the taps stopped.
2. **No blocking calls inside tap callbacks.** No `frontmostApplication()`, no AppleScript, no file I/O. The frontmost state is cached by the watcher; resolving a sequence is a plain table index into that host's lookup table (`EXACT[activeApp]`). Actions triggered by a completed sequence run via `hs.timer.doAfter`, outside the callback. A source-level test fails CI if a `frontmostApplication` call reappears in a handler.
3. **Callbacks never throw.** Both handlers are wrapped so any internal error returns `false` (pass the event through) instead of stalling the event chain.

Version 10 violated rule 2 and froze typing machine-wide; the v11 architecture and test `[1]`/`[2]` groups exist so that can't regress.

## The menu bar item

Not solved. What is known, so nobody re-runs these experiments:

The item is created and sized correctly, and macOS never lays it out:

| content | frame |
|---|---|
| icon | `(0,956 34x0)` |
| text | `(0,956 61x0)` |

Width tracks the content; height is always zero; `x` is always 0. Reported on
macOS 26.5.1, single built-in display, `barHeight=33`.

**Ruled out by evidence, not by argument:**

- *A persisted "hidden" flag.* `launcher.c` already deletes every
  `NSStatusItem*` preference on every launch, and the log confirms
  `pref[startup] none present`. There is nothing to override.
- *The Tahoe-wide bug* where no third-party icon appears. Six other apps are
  listed and enabled under Control Center → Allow in the Menu Bar.
- *The launcher's `execv`.* `XL_NO_LAUNCHER=1` points `CFBundleExecutable`
  straight at the engine so no exec happens. No change.
- *Icon rendering.* Rungs using a plain text title failed identically, and the
  icon assets are valid 18/36pt templates with alpha.

**The one solid clue:** the app does not appear in Control Center → Allow in
the Menu Bar **at all** — absent, not switched off — while other third-party
apps are listed. macOS is not registering this process as an application that
owns a status item. Why is not yet known.

### What the ladder cost

Earlier versions climbed a ladder (re-layout, text fallback, dropping the
remembered identity) and retried it at 15s, 60s and 180s. Two findings ended
that:

- No rung ever produced a laid-out item on the machine that fails.
- Repeatedly adding and removing status items **damages the system menu bar**.
  On macOS 26.5.1 the bar stopped drawing until clicked, for as long as the
  ladder ran. Two ladders ran at once — one from the startup timer, one from
  the Accessibility path — because retaining a previously-collected timer made
  both fire.

So: one creation, one check, and if it is not laid out the item is **deleted**
rather than left registered, since a zero-height item still occupies a slot the
system has to lay out. A second call in the same launch is a no-op. Regression
tests cover the count, the deletion and the guard; against the old code the
guard test creates six items.

### What boringNotch does differently

boringNotch has no Apple Developer account, is ad-hoc signed, and calls exactly
the same API — `NSStatusBar.system.statusItem(withLength:)`. It appears in
Allow in the Menu Bar. We do not. So neither signing nor the API is the
difference. One thing is:

| | boringNotch | here |
|---|---|---|
| `LSUIElement` | `YES` | deleted by `build-app.sh`, to get a Dock icon |

The runtime ships `LSUIElement`; we remove it. `XL_AGENT=1` puts it back, as a
test. If the status item registers in agent mode, the Dock icon and the menu
bar item are a trade rather than a bug — and the manager window would become
the only way in, so it would need a reachable entry point first.

Their `Info.plist` also answered the Sparkle failure: they set
`SUEnableDownloaderService` and `SUEnableInstallerLauncherService`, which
switch on the XPC services Sparkle's installer connects back through. Ours had
neither, and the log said `agent connection was never initiated`. Both are now
set unconditionally.

## Naming

The app displays as **CobAlt**. Several older names are kept deliberately and should not be "tidied up":

| stays | why |
|---|---|
| `com.corgianalyst.excel-alt-shortcuts` | Accessibility grants and Sparkle updates are keyed to the bundle identifier. Changing it drops every existing user's permission and breaks their update path. |
| `ExcelAlt.app`, `ExcelAltCore` | Sparkle replaces the host bundle in place. Renaming the bundle inside an update archive, while the installed copy has the old name, risks the install. |
| `~/Library/Application Support/ExcelAlt/` | User data. Moving it needs a migration, not a rename. |
| `ExcelAlt-update.zip`, `XL.dmg` | `release.yml` uploads these names and the appcast points at them. Existing download links use them. |
| `ExcelAlt` (the Lua state table) | Internal only. |

Only `APPNAME` in `src/init.lua`, `CFBundleName` and `CFBundleDisplayName` carry the display name. Renaming the bundle on disk is a separate, deliberate change that should be shipped with a manual install rather than through an update.

## Hosts

Three applications are supported, each with its own shortcut set, its own slice of `shortcuts.json`, its own accent colour in the manager, and its own pair of switches (shortcuts on/off, KeyTips overlay on/off). Nothing about a host is global: someone fluent in Excel's sequences can silence its overlay while still learning Word's. They are declared once in the `APPS` table at the top of `src/init.lua`:

| id | bundle | AppleScript name | accent |
|---|---|---|---|
| `excel` | `com.microsoft.Excel` | Microsoft Excel | `#0F6A3F` green |
| `powerpoint` | `com.microsoft.Powerpoint` | Microsoft PowerPoint | `#C43E1C` orange |
| `word` | `com.microsoft.Word` | Microsoft Word | `#185ABD` blue |

Bundle ids are matched through `BY_BUNDLE`, which is lowercased: PowerPoint has shipped as both `com.microsoft.Powerpoint` and `com.microsoft.PowerPoint` depending on the version, and both must resolve.

Adding a fourth host means adding a row to `APPS`, a `BUILTINS.<id>` table, and nothing else — the manager tabs, the store slices, the menu bar toggles, and the overlay all derive from `APPS`.

**Built-ins for PowerPoint and Word must not use menu paths.** Menu paths click the macOS menu bar and therefore have to match the host's *display language*. The app is distributed publicly, so an English path that works on the developer's machine silently misses for every French, German or Spanish user who downloads it — and it fails invisibly, with no error to report. Excel keeps a few historical menu-path entries that were verified by hand and carry AppleScript fallbacks; everything added since is a keystroke or AppleScript. A test enforces this for the two newer hosts.

User-created menu-path shortcuts are unaffected: someone writing their own knows their own Office language.

## Layout

```
src/init.lua          The whole engine (state, sequences, overlay, manager, menubar)
tests/hs_mock.lua     Headless mock of the Hammerspoon `hs` API with recorders
tests/run_tests.lua   Lua suite: freeze regression, sequences, formats, store, hosts
tests/ui/check.js     jsdom suite: drives the manager webview markup from init.lua
assets/               Icon sources (SVG) + generated icns / PNGs + generator script
installer/            End-user installer script and README
build/build-app.sh    Reproducible macOS build → dist/XL.dmg + update archive
build/build-local.sh  Dev build: test, build, install to ~/Applications, launch
.github/workflows/    CI: Lua suite + manager UI suite on every push
```

## Manager tabs

Five tabs: one per host, then **How to use** and **Feedback**. The two that belong to no host are deliberately neutral grey, so a coloured tab always means "this is an app's shortcut list".

Host pages are generated from a single template (`pageHTML`), so the three stay identical by construction. The full guide to the three shortcut methods lives on How to use rather than being folded into each host page — it is the same three methods everywhere, and the AppleScript vocabularies are worth seeing side by side.

Tutorial videos come from the `TUTORIAL` table at the top of `init.lua`. An entry with an empty `url` renders a "coming soon" tile, so the layout is correct before the recordings exist. To add one: drop the file into a GitHub issue comment, then paste the resulting `user-attachments` URL into the table.

## Persistence

`~/Library/Application Support/ExcelAlt/shortcuts.json` is schema **v2**:

```jsonc
{
  "version": 2,
  "apps": {
    "excel":      { "custom": [], "disabled": {}, "renames": {} },
    "powerpoint": { "custom": [], "disabled": {}, "renames": {} },
    "word":       { "custom": [], "disabled": {}, "renames": {} }
  },
  "custom": [], "disabled": {}, "renames": {}   // mirror of apps.excel
}
```

v1 files were flat and Excel-only; they migrate into `apps.excel` on load. The top-level keys are written back on every save as a **mirror of the Excel slice**, purely so that downgrading to v3.1 or earlier still finds the user's Excel customs where the older code looks for them. Nothing reads them in v3.2+.

## Running the tests

Neither suite needs macOS.

```
lua5.4 tests/run_tests.lua      # engine
node tests/ui/check.js          # manager webview (npm install --prefix tests/ui first)
```

The mock (`tests/hs_mock.lua`) implements event taps, timers, the app watcher, JSON, canvas, and menubar with recorders, so tests can drive the engine with synthetic key events and assert on the AppleScript it emits, which host it was addressed to, which events it swallows, and when its taps are enabled.

The manager is ~400 lines of JavaScript embedded in `init.lua` as a string, generating three near-identical host pages. `tests/ui/check.js` extracts that exact markup, loads it in jsdom, and drives it: tab switching and theming, per-host filtering, the add/edit/remove forms, and the messages the engine would receive. It exists because a typo in one generated element id would otherwise only surface on the user's Mac.

## Development builds

`build/build-local.sh` produces a build with bundle id `…excel-alt-shortcuts.dev`. That single change cascades:

- macOS keys **preferences** and the **Accessibility grant** by bundle id, so the dev build gets its own of each and cannot disturb the released app's.
- `init.lua` checks for the `.dev` suffix and puts all state in `~/Library/Application Support/ExcelAlt-dev/` — its own `shortcuts.json`, `prefs.json` and `debug.log`.
- `launcher.c` checks the same suffix and uses `~/.hammerspoon-xldev` as its fallback config directory, so an ignored `MJConfigFile` cannot make one build load the other's engine (see mistake #5).
- `XL_NO_UPDATES=1` strips `SUFeedURL`, so Sparkle in a dev build has no feed to check.

Both apps can therefore be installed at once. They should not be *running* at once: two engines watching Excel would both fire on every sequence.

## Naming

Three names, deliberately separate:

| what | value | why |
|---|---|---|
| `CFBundleIdentifier` | `com.corgianalyst.excel-alt-shortcuts` | Accessibility grants, preferences and the update requirement key off it. Never change it. |
| bundle filename | `ExcelAlt.app` | An update replaces the host bundle in place. Renaming it underneath an installed copy risks the swap. |
| `CFBundleName` / `CFBundleDisplayName` / nib strings | **CobAlt** | Everything the user reads: Dock, ⌘-Tab, the application menu, About/Hide/Quit. |

The user-facing name lives in two places that must agree. `Info.plist` covers the Dock and ⌘-Tab. The application menu and the About/Hide/Quit items are compiled into the runtime's nibs, and nothing substitutes them at runtime — the nib is what the user reads. `APPNAME` in `init.lua` is the third and must match.

### Renaming the nibs

`build/rename-nib.py` parses the NIBArchive container and rewrites display strings. It replaced a length-preserving substitution:

```sh
perl -pi -e 's/Hammerspoon/ExcelAlt XL/g'    # what this used to be
```

which had two faults worth remembering:

- It forced the product name to be **exactly 11 characters**, since the byte length had to match. That is the only reason the menu read "ExcelAlt XL" while the Dock read "CobAlt" — nobody chose that name, the byte count did.
- Nib strings are all archived under the same key (`NS.bytes`), so selectors are stored exactly like display strings. The substitution rewrote `quitHammerspoon:` into `quitExcelAlt XL:`, a method no class implements. **That is why Quit did nothing**, and why the app had to be force-quit, from v1 to v3.10.

`rename-nib.py` tells them apart by shape: a selector is an identifier ending in a colon with no spaces. It refuses to write a file that does not round-trip byte-for-byte first — a corrupt `MainMenu.nib` is an app that will not launch. `build/verify-nib-rename.sh` runs the whole thing against the real nibs in CI, renaming to a deliberately different-length name, and asserts both that the display strings changed and that `quitHammerspoon:` did not. `build-app.sh` asserts the same on every build.

## Updates

**Check for updates** in the Shortcut Manager header downloads, installs and relaunches without Sparkle. It is the dependable path and the only one that can update a copy installed before v3.10.

### Why Sparkle failed, and what fixed it

Proven from Sparkle's own log, not inferred:

```
OK: EdDSA signature is correct
Code signature of the new version doesn't match the old version:
cdhash H"c26014e4aa2a650b1189b53e47701087ec13aa3e".
Please ensure that old and new app is signed using exactly the same certificate.
```

Note what this rules out. The message comes from `Sparkle.framework/Versions/B/Autoupdate`, so the installer helper *ran*; the "macOS refuses to launch a nested helper" theory that was written into `init.lua` for several releases was wrong. And the archive was never at fault — its EdDSA signature verified immediately before the refusal.

Sparkle's installer takes the **installed** app's designated requirement and checks the download against it. A plain ad-hoc signature carries no explicit requirement, so macOS synthesises one from the code hash: `cdhash H"…"`, pinned to one build and unsatisfiable by any other. The message's advice about certificates is misleading here — the requirement, not the certificate, is what breaks.

The build now signs the top level with an **explicit** requirement:

```sh
codesign --force --sign - --identifier "$BID" \
  -r="designated => identifier \"$BID\"" "$APP"
```

`identifier "…"` is stable across builds and satisfied by any build of this app. `--deep` is deliberately not used, or the requirement would be pushed onto the nested Sparkle framework, whose identifier differs. This is not a security boundary: ad-hoc code has no certificate to anchor to, and the appcast's EdDSA signature is what attests the archive. It exists so the requirement stops being build-specific. A Developer ID certificate replaces it with a real anchor.

**This only helps updates *from* a build that carries the requirement**, since it is the old app's requirement that is consulted. Anything installed before v3.10 still has a `cdhash` requirement and can only be updated by the built-in path below.

### How this is kept honest

The property is invisible to `codesign --verify` and shows up only as an update that will not install, months later — which is exactly how it went unnoticed from v3.2 to v3.9. So it is tested, not assumed:

- `build/drcheck.c` reproduces Autoupdate's check exactly: copy the old bundle's designated requirement, validate the new bundle against it.
- `build/verify-signing.sh` runs it over two deliberately different builds and **fails if plain ad-hoc signing passes** — a check that succeeds either way proves nothing. CI runs this on macOS on every push.
- `.github/workflows/verify-update.yml` does the same on two real builds of the product, with the nested framework and compiled launcher in place, including the same negative control. Manual dispatch; run it before tagging anything that touches signing.
- `build/build-app.sh` asserts the requirement landed and refuses to produce a build whose requirement contains `cdhash`.

Every assertion there is its own workflow step on purpose. GitHub serves job logs from a storage host that is not always reachable, and when it is not, the step name is the only diagnosis available.

Things eliminated along the way, so nobody repeats them: quarantine on the download, the v3.1→v3.2 build diff (identical), the update archive's transport, and the validity of either signature.

### What the app does instead

1. read `appcast.xml` for the version, archive URL and byte count
2. `curl` the archive — curl rather than the browser, so it carries no quarantine flag
3. check the byte count against the appcast and read `CFBundleShortVersionString` out of the unpacked bundle
4. write a shell script, launch it detached, quit
5. the script waits for the process to exit, swaps the bundle with a rollback if the move fails, clears quarantine and relaunches

**Known gap:** this verifies HTTPS transport, byte count and version, but not the archive's EdDSA signature — Sparkle did that, and doing it in Lua is not practical. `SUPublicEDKey` and the signed appcast are still published, so this can be tightened later, and the whole path becomes unnecessary once a certificate exists.

Sparkle's own **Check for Updates…** in the top-left app menu belongs to the runtime and cannot be changed from Lua. From v3.10 it can install, because the requirement it checks is now stable. It stays a manual entry point only: `SUEnableAutomaticChecks` is off, so Sparkle never prompts on its own and there is exactly one automatic path.

### Automatic checks

Reaching an update should not depend on finding a button. The engine checks 20s after launch and every six hours, through the built-in path.

- a version answered "Later" is recorded in `prefs.json` and not raised again on its own; a manual check still offers it
- nothing is raised while a shortcut sequence is in flight — the dialog takes focus and would swallow the rest of the sequence
- a failed check is silent; only a manual one reports problems
- development builds never check. The swap replaces whatever bundle is running, so an automatic update in a dev build would quietly install the release over `ExcelAlt-dev.app`

## The KeyTips panel

Redraws are coalesced onto the next runloop tick by `scheduleUI`, which **stops and replaces** any pending redraw. It must not use a boolean latch cleared by the timer's own callback: an unretained `hs.timer.doAfter` can be collected before it fires, and when that happened the latch stayed set and the panel never drew again for the rest of the session. Nothing else routes through `scheduleUI`, so sequences, actions and the confirmation alert all kept working — it presented as "shortcuts work but the list never appears" and took several rounds to find. The pending timer is retained on `ExcelAlt.uiTimer`.

Each host's overlay switch is obeyed literally: off draws nothing at all. A failed sequence still reports itself (`No shortcut: ⌥ HEL`), which is what tells someone an accidental ⌥ tap consumed a keystroke or two.

## Diagnosing a shortcut that does nothing

`debug.log` records every sequence that resolves, plus every AppleScript or menu-path failure:

```
fired [word] hfg — Grow font
applescript FAILED [word] set strike through of font object of selection ...  -> ...
```

That splits a "shortcut X doesn't work" report into three distinguishable cases:

| log | meaning |
|---|---|
| no line at all | the sequence never matched — check the overlay, the host toggle, Accessibility |
| `fired` + `FAILED` | the sequence works, the AppleScript behind it is wrong |
| `fired`, no failure, nothing visible | the sequence works, the keystroke behind it is wrong (keystrokes cannot report failure) |

## Building the app (macOS)

```
bash build/build-app.sh
```

Downloads the runtime, rebrands it (`com.corgianalyst.excel-alt-shortcuts`, display name ⌥XL, corgi icon, no dock icon, update feed removed), embeds `src/init.lua` and the assets, ad-hoc signs, and zips `dist/XL-App.zip` with the installer.

To regenerate icons after editing the SVGs: `pip install cairosvg && python3 assets/make_icons.py` (outputs land in `assets/out/`; copy `AppIcon.icns`, `menubar@2x.png` into `assets/`).

## Quick start (pull and run)

```
git pull
./start.sh          # or double-click "Start XL.command" in Finder
```

The first run builds the app from source (downloads the runtime, rebrands it, embeds `src/init.lua` and the assets), installs it to /Applications, resets any stale Accessibility grant, ad-hoc signs, and launches it. Later runs skip straight to installing and launching the current build; pass `./start.sh --rebuild` to force a fresh build after you change `src/`.

Grant Accessibility to "ExcelAlt" when macOS asks — shortcuts go live automatically a couple of seconds later. Then open Excel and tap ⌥.

Requirements: macOS, plus command-line tools for the one-time build (`git`, `curl`, `unzip`, `codesign`, all standard on a Mac with Xcode command-line tools). The built `dist/` bundle is gitignored, which is why the first pull builds it locally rather than shipping a binary in the repo.

## End-user install (prebuilt zip)

Alternatively, distribute `dist/XL-App.zip` (produced by `build/build-app.sh`). Recipients unzip and right-click `Install XL.command` → Open — same install/permission flow, no build step or command-line tools needed on their machine.

## Roadmap

Phase 2 is a native Swift rewrite (CGEventTap + NSPanel + WKWebView) sharing the same shortcuts JSON schema, for signed/notarized distribution. Note: Mac App Store sandboxing is incompatible with global keystroke interception, so distribution stays direct, like every app in this category.
