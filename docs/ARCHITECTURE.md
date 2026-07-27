# Architecture and safety model

## Safety model (read before touching the tap code)

The engine listens to keyboard events through macOS event taps. macOS **holds keyboard delivery for the entire system** while a tap callback runs, which imposes three hard rules, all enforced by tests:

1. **Taps run only while a supported host is frontmost.** An `hs.application.watcher` starts them when Excel, PowerPoint or Word activates and stops them the moment anything else takes focus. Outside those three the app touches no events at all. Which host is frontmost is cached in `ExcelAlt.activeApp`; a host the user has switched off in the manager keeps the taps stopped.
2. **No blocking calls inside tap callbacks.** No `frontmostApplication()`, no AppleScript, no file I/O. The frontmost state is cached by the watcher; resolving a sequence is a plain table index into that host's lookup table (`EXACT[activeApp]`). Actions triggered by a completed sequence run via `hs.timer.doAfter`, outside the callback. A source-level test fails CI if a `frontmostApplication` call reappears in a handler.
3. **Callbacks never throw.** Both handlers are wrapped so any internal error returns `false` (pass the event through) instead of stalling the event chain.

Version 10 violated rule 2 and froze typing machine-wide; the v11 architecture and test `[1]`/`[2]` groups exist so that can't regress.

## Hosts

Three applications are supported, each with its own shortcut set, its own slice of `shortcuts.json`, its own accent colour in the manager, and its own on/off switch. They are declared once in the `APPS` table at the top of `src/init.lua`:

| id | bundle | AppleScript name | accent |
|---|---|---|---|
| `excel` | `com.microsoft.Excel` | Microsoft Excel | `#0F6A3F` green |
| `powerpoint` | `com.microsoft.Powerpoint` | Microsoft PowerPoint | `#C43E1C` orange |
| `word` | `com.microsoft.Word` | Microsoft Word | `#185ABD` blue |

Bundle ids are matched through `BY_BUNDLE`, which is lowercased: PowerPoint has shipped as both `com.microsoft.Powerpoint` and `com.microsoft.PowerPoint` depending on the version, and both must resolve.

Adding a fourth host means adding a row to `APPS`, a `BUILTINS.<id>` table, and nothing else — the manager tabs, the store slices, the menu bar toggles, and the overlay all derive from `APPS`.

**Built-ins for PowerPoint and Word must not use menu paths.** Menu paths click the macOS menu bar and therefore have to match the host's *display language*; on a French system every English path silently misses. Excel keeps a few historical menu-path entries that the user verified by hand; everything added since is a keystroke or AppleScript. A test enforces this for the two newer hosts.

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

## Diagnosing a shortcut that does nothing

Every AppleScript failure is written to `debug.log` with its host and the offending line:

```
applescript FAILED [word] set strike through of font object of selection ...  -> ...
```

Menu paths that cannot be found log similarly. So the first question for any "shortcut X doesn't work" report is the log — it distinguishes *the sequence never fired* (no line at all: check the overlay, the host toggle, Accessibility) from *the action is wrong* (a FAILED line naming it).

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
