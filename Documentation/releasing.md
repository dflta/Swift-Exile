# Releasing SwiftExile

Releases are built by GitHub Actions ([`release.yml`](../.github/workflows/release.yml)) when a tag
like `v0.2.0` is pushed. The workflow tests, builds a universal app, signs it, packs a DMG, adds it to
the Sparkle appcast, and publishes a GitHub Release with both files. Installed copies find the update
through `https://github.com/dflta/Swift-Exile/releases/latest/download/appcast.xml`.

## Signing identity (one time)

```bash
Scripts/create-release-identity.sh
```

This creates, in `~/.swiftexile-release/` (outside the repository):

| File | Secret? | Used for |
|---|---|---|
| `SwiftExile-Release.p12`, `p12-password.txt` | yes | Self-signed code-signing certificate "SwiftExile Release" |
| `sparkle-ed25519-private.txt` | yes | Signs updates; installed copies accept only updates signed with it |
| `sparkle-ed25519-public.txt` | no | Already in `Resources/Info.plist` as `SUPublicEDKey` |
| `SwiftExile-Release-certificate.pem` | no | The certificate on its own |

**Back the folder up.** If the certificate is lost, the next release has a different designated
requirement, and macOS forgets every user's Accessibility permission. If the EdDSA key is lost,
installed copies can never auto-update again (users would have to download a new version by hand).

`Resources/designated-requirement.txt` records the requirement the certificate produces.
`Scripts/sign-app.sh` refuses to finish if a build's requirement differs.

## GitHub secrets (one time)

Add these to the repository (Settings ▸ Secrets and variables ▸ Actions), or with the GitHub CLI,
logged in as the repository owner:

```bash
base64 -i ~/.swiftexile-release/SwiftExile-Release.p12 | gh secret set SWIFTEXILE_P12_BASE64 --repo dflta/Swift-Exile
```

```bash
gh secret set SWIFTEXILE_P12_PASSWORD --repo dflta/Swift-Exile < ~/.swiftexile-release/p12-password.txt
```

```bash
gh secret set SPARKLE_ED25519_PRIVATE --repo dflta/Swift-Exile < ~/.swiftexile-release/sparkle-ed25519-private.txt
```

## Making a release

1. Make sure `main` is green (the Test workflow) and the manual checklist in
   [testing.md](testing.md) passes for the changes in this release.
2. In [CHANGELOG.md](../CHANGELOG.md), rename "Unreleased" to the version (`## 0.2.0`) and commit.
   Write it for players: what they can do now or what got fixed, in a few short lines, without
   implementation details. That section becomes the GitHub Release notes and the notes in the
   update dialog; the Release
   workflow stops if it's missing (`Scripts/release-notes.sh 0.2.0` shows what it will use).
3. Tag and push:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```

4. Watch the Release workflow. When it finishes, the release has `SwiftExile-0.2.0.dmg` and
   `appcast.xml`. Installed copies offer the update on their next check.

The version comes from the tag; the build number (what Sparkle compares) is the number of commits
on the tagged commit, so it always increases on `main`.

## Building a release locally

The same scripts work on your Mac, using `~/.swiftexile-release`:

```bash
SWIFTEXILE_VERSION=0.2.0 SWIFTEXILE_BUILD=$(git rev-list --count HEAD) Scripts/bundle-app.sh release
```

```bash
Scripts/make-dmg.sh
```

```bash
Scripts/make-appcast.sh build/SwiftExile-0.2.0.dmg v0.2.0
```

Local debug builds (`Scripts/bundle-app.sh`) stay signed ad hoc. Pass `SIGN=release` to sign one
with the release certificate, e.g. to test that Accessibility permission survives an update.
