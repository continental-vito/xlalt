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

Runs the tests, builds the app with a dev version string, installs it to
`~/Applications/ExcelAlt-dev.app`, and launches it. The released build in
`/Applications` is left alone.

Details worth knowing:

- **Version string.** Dev builds are stamped
  `<lasttag>-dev.<branch>.<sha>` — a `+` suffix means uncommitted changes were
  in the tree. Feedback emails and the About window therefore never report a
  released version number for a build that isn't one.
- **Sparkle.** `CFBundleVersion` is forced to 90000+ locally, so the live
  appcast can never offer to "update" a dev build back down to the release.
- **Config backup.** `shortcuts.json` is snapshotted to `~/.xlalt-backups/`
  before every build, 20 snapshots retained. If a dev build migrates the
  schema and you then go back to the release, restore from there.
- **One at a time.** Both builds share the bundle id and both rewrite
  `~/.hammerspoon/init.lua` at launch, so they cannot run side by side. The
  script kills any running instance first. Switching back to the release just
  means quitting and opening `/Applications/ExcelAlt.app` — it restores its own
  `init.lua`.
- **Accessibility.** Ad-hoc signing changes the code hash on every build, so
  macOS may drop the grant. `bash build/build-local.sh --reset-tcc` clears the
  stale entry and forces a fresh prompt. This goes away with a Developer ID
  certificate.

Flags: `--no-launch`, `--reset-tcc`, `--package` (also builds the DMG, ~a
minute slower, only needed when testing the installer itself).

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
