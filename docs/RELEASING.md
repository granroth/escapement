# Releasing Escapement

Push a tag, get a notarized universal `.dmg` on a draft GitHub release.

```sh
git tag v0.4.0
git push origin v0.4.0
```

The workflow refuses any tag that is not `vMAJOR.MINOR.PATCH`. The version is
taken from the tag and stamped into both `Info.plist` files at build time, so
the `0.1.0` in the tree never has to be kept in sync by hand.

The release is created as a **draft**. Download the image, install it on a Mac
that has never seen the app, confirm it opens without a Gatekeeper warning,
then publish.

## What the pipeline does

1. Builds a universal (arm64 + x86_64) binary.
2. Signs the nested agent bundle, then the app around it — inside out, both
   with the Hardened Runtime.
3. Notarizes the **app** and staples the ticket into the bundle, so it stays
   valid after a user drags it out of the image.
4. Builds a signed `.dmg` with the usual drag-to-Applications layout.
5. Notarizes and staples the **image** too.
6. Refuses to publish unless `spctl` reports `source=Notarized Developer ID` —
   the same assessment Gatekeeper makes on the user's machine.

Both the app and the image are notarized because they are checked
independently: stapling only the image leaves a copied-out app relying on an
online check, and stapling only the app leaves the download itself unverified.

## Required repository secrets

Set these under **Settings → Secrets and variables → Actions**. They use the
same names as the maintainer's other projects, so an organisation-level secret
will satisfy them without per-repository setup.

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | Developer ID Application certificate, exported as `.p12` and base64-encoded |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_SIGNING_IDENTITY` | the identity string, e.g. `Developer ID Application: NAME (TEAMID)` |
| `APPLE_API_ISSUER` | App Store Connect API **Issuer ID** (a UUID) |
| `APPLE_API_KEY` | App Store Connect API **Key ID** (10 characters) |
| `APPLE_API_KEY_CONTENT` | the full contents of the `AuthKey_<KeyID>.p8` file |

`APPLE_TEAM_ID` is not needed here — `notarytool` takes the team from the API
key — but it is harmless if it already exists for other projects.

### Getting the certificate

The certificate must be a **Developer ID Application** certificate, not "Apple
Development" or "Mac App Distribution". Those cannot notarize.

```sh
security find-identity -v -p codesigning     # copy the exact identity string
```

In Keychain Access, find that certificate, right-click → **Export**, choose
Personal Information Exchange (`.p12`), and set a password. Then:

```sh
base64 -i Escapement.p12 | pbcopy            # paste into APPLE_CERTIFICATE
```

Export the *certificate*, which carries its private key — exporting only the
key, or only the public certificate, produces a `.p12` that imports without
error and then fails at signing time.

### Getting the API key

App Store Connect → **Users and Access** → **Integrations** → **Keys**. Create
a key with at least the **Developer** role; anything less cannot submit for
notarization.

Downloading the `.p8` is a **one-time** offer — Apple will not let you download
it again. Copy its entire contents, `-----BEGIN PRIVATE KEY-----` line
included, into `APPLE_API_KEY_CONTENT`.

The Issuer ID is shown above the key list; the Key ID is in the row itself.

## Building locally

```sh
scripts/build-app.sh release                     # native arch, your Developer ID
ESCAPEMENT_UNIVERSAL=1 scripts/build-app.sh release
scripts/make-dmg.sh 0.4.0
```

`ESCAPEMENT_SIGN_IDENTITY` overrides the signing identity, and `-` forces
ad-hoc signing. If the configured identity is not in your keychain the build
falls back to ad-hoc with a warning rather than failing, so a clean checkout
always builds — but an ad-hoc app cannot register its background agent, since
`SMAppService` refuses one.

To notarize by hand:

```sh
xcrun notarytool store-credentials escapement \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>

ditto -c -k --keepParent .build/Escapement.app .build/Escapement.zip
xcrun notarytool submit .build/Escapement.zip --keychain-profile escapement --wait
xcrun stapler staple .build/Escapement.app
```

If a submission is rejected, the reason is in the log — the summary alone will
not tell you which binary was at fault:

```sh
xcrun notarytool log <submission-id> --keychain-profile escapement
```

The usual causes are a nested binary that was not signed, a signature without a
secure timestamp, a missing Hardened Runtime, or a `get-task-allow` entitlement
left over from a debug build.

## CI

`ci.yml` runs on every push and pull request: builds, runs the test suite, and
assembles the app bundle ad-hoc signed. That last step is deliberate — most of
what breaks a release lives in `scripts/build-app.sh` rather than in the Swift
sources, and the test suite would not notice a bundle-layout mistake. It also
asserts the agent's bundle identifier still differs from the app's, which is an
invariant with real consequences (see `AGENTS.md`).

CI holds no secrets, so it runs unchanged on forks and pull requests.
