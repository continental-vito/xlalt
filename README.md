# ⌥XL — Windows Alt shortcuts for Excel on Mac

Tap the Option key in Excel for Mac, then type the Windows sequence you already know: `H O I` autofits, `H V V` pastes values, `H B A` draws all borders, `H 0` / `H 9` adjust decimals, `=` AutoSums, `W F F` freezes panes. A KeyTips panel shows what's available as you type. Around 40 sequences ship built in, and a Shortcut Manager lets you add your own (keystrokes, Excel menu paths, or AppleScript).

The app is a menu bar utility: no dock icon, corgi app icon, an ⌥-chart glyph in the menu bar. It is built on the Hammerspoon runtime, fully rebranded and self-contained.

## Download (no build needed)

**[⬇ Download XL-App.zip](https://github.com/vitodelcambio/xl/raw/main/download/XL-App.zip)** — then install like any Mac app:

1. Unzip, drag `ExcelAlt.app` into **Applications**, double-click it.
2. First open only: macOS blocks non-notarized downloads. Go to **System Settings → Privacy & Security**, scroll to the "ExcelAlt was blocked" notice, click **Open Anyway**. (One time; this is Apple's gate for apps without a paid Developer ID. The bundled `Install XL.command` does the equivalent for you if you prefer.)
3. Grant **Accessibility** to ExcelAlt when asked — shortcuts go live automatically seconds later. Open Excel, tap ⌥.

The app is fully self-configuring (v1.3): its launcher writes its own settings on every start, so no installer, no Terminal, works from any folder. Custom shortcuts of kind "menu path" address the Mac **menu bar** (Edit, Format, Window…) in Excel's display language — not the Windows ribbon; prefer the AppleScript kind for language-independent actions.

## Safety model (read before touching the tap code)

The engine listens to keyboard events through macOS event taps. macOS **holds keyboard delivery for the entire system** while a tap callback runs, which imposes three hard rules, all enforced by tests:

1. **Taps run only while Excel is frontmost.** An `hs.application.watcher` starts them when Excel activates and stops them the moment anything else takes focus. Outside Excel the app touches no events at all.
2. **No blocking calls inside tap callbacks.** No `frontmostApplication()`, no AppleScript, no file I/O. The frontmost state is cached by the watcher. Actions triggered by a completed sequence run via `hs.timer.doAfter`, outside the callback. A source-level test fails CI if a `frontmostApplication` call reappears in a handler.
3. **Callbacks never throw.** Both handlers are wrapped so any internal error returns `false` (pass the event through) instead of stalling the event chain.

Version 10 violated rule 2 and froze typing machine-wide; the v11 architecture and test `[1]`/`[2]` groups exist so that can't regress.

## Layout

```
src/init.lua          The whole engine (state, sequences, overlay, manager, menubar)
tests/hs_mock.lua     Headless mock of the Hammerspoon `hs` API with recorders
tests/run_tests.lua   38-test suite: freeze regression, sequences, formats, store
assets/               Icon sources (SVG) + generated icns / PNGs + generator script
installer/            End-user installer script and README
build/build-app.sh    Reproducible macOS build → dist/XL-App.zip
.github/workflows/    CI: syntax check + full test suite on every push
```

## Running the tests

Needs only Lua 5.4 — no macOS required:

```
lua5.4 tests/run_tests.lua
```

The mock (`tests/hs_mock.lua`) implements event taps, timers, the app watcher, JSON, canvas, and menubar with recorders, so tests can drive the engine with synthetic key events and assert on the AppleScript it emits, which events it swallows, and when its taps are enabled.

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
