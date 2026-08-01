# Getting a Developer ID, and what it unblocks

Everything below is one-time setup except the annual renewal. Budget an
afternoon of forms plus 24–48 hours of waiting.

---

## 0. Decide this before you pay

Enrolment is **individual** or **organization**, and converting later means
contacting Apple Support, so pick deliberately.

| | Individual | Organization |
|---|---|---|
| Cost | 99 USD/year | 99 USD/year |
| Verification | usually 24–48 h | 1–2 weeks |
| Needs a D-U-N-S number | no | yes |
| Name users see | your legal name | the company name |

The name matters here. macOS shows the certificate holder on first launch of
a downloaded app, and the certificate is literally named
`Developer ID Application: <name> (TEAMID)`. On an individual account that is
**Vito's legal name**, not "Corgi Analyst". If the corgi branding is meant to
read as a company, enrol as an organization — but that needs a registered
legal entity and a D-U-N-S number, which takes longer.

For a solo product, individual is the normal choice. Just go in knowing your
name is on it.

---

## 1. Enrol

1. <https://developer.apple.com/programs/> → **Enroll**.
2. Sign in with an Apple Account that has **two-factor authentication on**.
   Consider a dedicated Apple Account for the project rather than a personal
   one — you cannot easily hand a personal account to a collaborator later.
3. Choose Individual or Organization per above.
4. Pay the 99 USD (charged in euros from France). **Use your own credit card**
   if enrolling as an individual — a mismatched name is the most common cause
   of a stalled enrolment and Apple may then ask for government photo ID.
5. Wait for the confirmation email. Individual enrolments are usually verified
   within a couple of days; if it sits longer than that, Apple Developer
   Support is the only route, and the developer forums are full of people
   waiting on exactly this.

Once verified, note your **Team ID** — a 10-character string at
<https://developer.apple.com/account> under Membership. You will need it.

---

## 2. Create the Developer ID Application certificate

We ship a `.app` inside a `.dmg`, so we need **Developer ID Application**.
(`Developer ID Installer` is only for `.pkg` installers — we don't use one.)

Easiest route, on your Mac:

1. Install Xcode if you haven't (App Store, large download).
2. Xcode → **Settings → Accounts** → add your Apple Account.
3. Select the team → **Manage Certificates…** → **+** → **Developer ID
   Application**.

Xcode generates the key pair, submits the signing request, and installs the
result into your login keychain. Confirm it exists:

```
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: <name> (TEAMID)`.

> The private key exists **only on this Mac**. If you lose it you must revoke
> and reissue. Export a backup now (next step) and keep it somewhere safe —
> not in the repo.

---

## 3. Export the certificate as a `.p12`

CI has no keychain, so it needs the certificate and private key as a file.

1. Open **Keychain Access** → *login* → *My Certificates*.
2. Right-click `Developer ID Application: …` → **Export…**.
3. Save as `developer-id.p12`, set a strong password. Remember it.

Then base64-encode it, because GitHub secrets hold text:

```
base64 -i developer-id.p12 | pbcopy
```

That is now on your clipboard, ready to paste into a secret.

---

## 4. Create an App Store Connect API key for notarization

Signing proves who built it. **Notarization** is Apple scanning the binary and
issuing a ticket — without it, macOS still refuses to open a downloaded app.

Two ways to authenticate. Use an **API key**, not an app-specific password: it
is scoped, revocable on its own, and does not sit on your Apple Account.

1. <https://appstoreconnect.apple.com> → **Users and Access → Integrations →
   Keys**.
2. Generate a key. Access level **Developer** is sufficient.
3. Download `AuthKey_XXXXXXXXXX.p8`. **It can only be downloaded once.**
4. Note the **Key ID** (the `XXXXXXXXXX` part) and the **Issuer ID** (a UUID
   shown above the key list).

```
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

---

## 5. Add seven secrets to the repo

**Settings → Secrets and variables → Actions → New repository secret.**

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | base64 from step 3 |
| `MACOS_CERT_PASSWORD` | the `.p12` password |
| `KEYCHAIN_PASSWORD` | any strong random string; CI uses it for a throwaway keychain |
| `APPLE_TEAM_ID` | your 10-character Team ID |
| `NOTARY_KEY_P8` | base64 from step 4 |
| `NOTARY_KEY_ID` | the Key ID |
| `NOTARY_ISSUER_ID` | the Issuer ID |

Tell me when they're in and I'll do the rest. **Don't paste any of these into
chat** — I only need to know they exist. The Sparkle key already lives there
the same way as `SPARKLE_PRIVATE_KEY`.

---

## 6. What I change once the secrets exist

In `build/build-app.sh`:

- Import the `.p12` into a temporary keychain, sign with
  `--options runtime --timestamp`, and delete the keychain afterwards.
- Sign **inside-out**: nested dylibs and `.so` modules, then
  `Sparkle.framework` and its `Updater.app` and XPC services, then
  `ExcelAltCore`, then the outer bundle last.
- **Drop the custom `-r` designated requirement.** It exists only because
  ad-hoc signing has no anchor. A real certificate produces a proper
  requirement automatically, and it is strictly better.
- Add an entitlements file (see the warning below).

In `.github/workflows/release.yml`:

- After signing: zip, `xcrun notarytool submit --wait`, then
  `xcrun stapler staple` the `.app`.
- Build the DMG from the **stapled** app, then sign, notarize and staple the
  DMG too.
- Assert `spctl -a -vvv -t install` reports
  `source=Notarized Developer ID`, and fail the release if not.

The existing CI checks stay: the cross-build requirement check still applies,
just against a real anchor instead of a synthesised one.

---

## 7. The thing that will bite: Apple Events

Notarization requires the **hardened runtime**, and the hardened runtime
blocks things this app depends on unless they are declared.

The critical one: **every Excel action goes through AppleScript**
(`hs.osascript`). Under the hardened runtime, sending Apple Events to another
application requires an entitlement. Without it, the app launches fine, the
shortcuts light up, and **nothing happens in Excel** — a failure that looks
like a broken app, not a signing problem.

So the entitlements file needs at minimum:

```xml
<key>com.apple.security.automation.apple-events</key><true/>
```

plus `NSAppleEventsUsageDescription` in `Info.plist`, or macOS won't even show
the permission prompt.

Likely also needed, because the runtime loads Lua C extension modules at
runtime:

```xml
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

I'd rather try without that one first and add it only if the modules fail to
load — it weakens the guarantee and I don't want it in there on spec.

**This is why the first signed build gets tested before release, not after.**

---

## 8. What this actually unblocks

Honest confidence levels, because two of these are being treated as settled
when they aren't:

| Item | Confidence | Notes |
|---|---|---|
| Gatekeeper warning on download | **certain** | This is exactly what notarization is for. |
| Accessibility grant surviving updates | **high** | TCC keys on the code requirement. Ad-hoc gives a per-build hash, so every update looks like a different app — which is why you re-grant every time. A stable certificate should end that. |
| Sparkle's nested `Updater.app` agent | **likely** | Your log showed `syspolicy` stalling for 19 s before `agent connection was never initiated`. A signed, notarized helper is the standard fix. Not proven until we try. |
| Mac App Store submission | enabled | Different certificate, sandboxing required — a separate project. |
| **Menu bar icon** | **doubtful** | See below. |

### About the menu bar icon

It's parked "until a Developer ID certificate", but I don't think that
rationale holds. The symptom is `frame=(0,956 69x0)` — a zero-height status
item. That's a layout problem, and code signing does not affect layout. My
guess is the notch plus boringNotch, not signing.

I'd rather re-diagnose it properly than let it ride on the certificate and
then find it still broken. Worth doing independently, before or after.

---

## 9. Order of operations

1. Secrets land in the repo.
2. I wire up signing and notarization, and cut a build **you install
   manually from the DMG** — not through the updater.
3. You verify the Excel actions still work. This is the real test: if the
   Apple Events entitlement is wrong, shortcuts fire and Excel ignores them.
4. Only then do we tag a release.

### One-time disruption for existing users

The signing identity changes, so macOS sees a different app:

- **Everyone re-grants Accessibility once.** Unavoidable, and it should be the
  last time.
- Anything installed **before v3.10** still can't update through Sparkle. That
  is unrelated to the certificate — those builds have a build-specific
  requirement baked in. The built-in updater handles them.

One piece of good news: v3.10–v3.12 carry the requirement
`identifier "com.corgianalyst.excel-alt-shortcuts"`, which has no anchor
clause. A Developer ID-signed build **satisfies it**, because the identifier
is unchanged. So the upgrade to the first signed version does not re-break
Sparkle's signature check.

---

## 10. Keeping the credentials safe

- Delete `developer-id.p12` and `AuthKey_*.p8` from Downloads once the secrets
  are set. Keep one backup of the `.p12` somewhere encrypted.
- Neither belongs in this repo, ever.
- If a key leaks: revoke the API key in App Store Connect, revoke the
  certificate at developer.apple.com, reissue. Anything signed with the old
  certificate keeps working until Apple revokes the ticket.
- The membership auto-renews. **If it lapses, the certificate stops being
  valid for new signatures** — already-shipped builds keep working, but you
  can't cut a release until you renew.
