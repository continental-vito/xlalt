# Development workflow

Users update through the Sparkle appcast on `main`. Nothing reaches them until
a `v*` tag is pushed. That single fact is what makes it safe to develop in the
open here.

## Branches

| Branch | Purpose |
|---|---|
| `main` | Released code. Also where CI commits `appcast.xml` after a tagged build. |
| `dev` | Everything in flight. Push as often as you like. |
| `dev-<feature>` | Optional. One per feature when several are in flight and some may be abandoned. Merges into `dev`. |

`release.yml` triggers on `push: tags: ['v*']` and manual dispatch only — never
on a branch push. `ci.yml` runs the Lua test suite on every push to every
branch, which is what you want: broken tests are visible on `dev` immediately
but ship nothing.

```bash
git checkout dev
# ...work...
git commit -am "overlay: per-tab colour themes"
git push
```

## Local test loop

```bash
bash build/build-local.sh
```


Runs the tests, builds, installs to `~/Applications/ExcelAlt-dev.app`, and
launches it.

**The dev build is a different app.** It carries the bundle id
`com.corgianalyst.excel-alt-shortcuts.dev`, and macOS keys almost everything
that matters off that:

| | released ⌥XL | ⌥XL (dev) |
|---|---|---|
| location | `/Applications/ExcelAlt.app` | `~/Applications/ExcelAlt-dev.app` |
| data, prefs, log | `…/Application Support/ExcelAlt/` | `…/Application Support/ExcelAlt-dev/` |
| preferences domain | `…excel-alt-shortcuts` | `…excel-alt-shortcuts.dev` |
| Accessibility grant | its own | its own |
| fallback config dir | `~/.hammerspoon` | `~/.hammerspoon-xldev` |
| update feed | live appcast | none (`SUFeedURL` stripped) |

So the released app's shortcuts, preferences and permission survive anything
the dev build does, including a `shortcuts.json` schema change. On first run
the dev build is *seeded* with a copy of your current shortcuts so the lists
look familiar; after that the two files are independent.

**Don't run both at once.** They can coexist on disk, but two engines watching
Excel would both fire on every sequence. Quit the released ⌥XL while testing;
the script only stops previous *dev* builds.

Other details:

- **Version string.** Dev builds are stamped `<lasttag>-dev.<branch>.<sha>` —
  a `+` suffix means uncommitted changes were in the tree. Feedback emails and
  the About window therefore never report a released version number for a
  build that isn't one.
- **Accessibility.** Ad-hoc signing changes the code hash on every build, so
  macOS may drop the grant. `--reset-tcc` clears the dev entry and forces a
  fresh prompt. This goes away with a Developer ID certificate.
- **Backups.** The released `shortcuts.json` is still snapshotted to
  `~/.xlalt-backups/` before every build (20 kept). The dev build should never
  touch it; this is how you would find out if that ever stopped being true.

Flags: `--no-launch`, `--reset-tcc`, `--package` (also builds the DMG, ~a
minute slower, only needed when testing the installer itself).

Removing the dev build completely:

```bash
rm -rf ~/Applications/ExcelAlt-dev.app \
       ~/Library/Application\ Support/ExcelAlt-dev \
       ~/.hammerspoon-xldev
```

Then remove "⌥XL (dev)" from System Settings → Privacy & Security →
Accessibility.

## Adding a tutorial video

Record it, drag the file into a comment box on any issue in this repo, wait for the upload, then paste the `https://github.com/user-attachments/…` URL into the matching entry of the `TUTORIAL` table near the top of `src/init.lua`. Empty `url` = placeholder tile. No other change is needed; the How to use tab renders whatever is in the table.

## Shipping

Once the feature is validated on the laptop:

```bash
git checkout main
git merge dev
git push
git tag v3.2 && git push origin v3.2
```

CI builds on a macOS runner, uploads `XL.dmg` / `XL-App.zip` /
`ExcelAlt-update.zip` to the release, signs the update archive with
`SPARKLE_PRIVATE_KEY`, and commits the new `appcast.xml` to `main`. Existing
users see it under **ExcelAlt → Check for Updates**.

Then bring `dev` back in line:

```bash
git checkout dev && git merge main && git push
```

## If a release goes wrong

The appcast has a single `<item>`, so rolling back is a matter of pointing it
at the previous release: re-run the release workflow via **Actions → release →
Run workflow** with the older tag. It rebuilds that tag and rewrites
`appcast.xml` to match, and clients stop being offered the bad version. The
older DMG stays downloadable from its release page throughout.
