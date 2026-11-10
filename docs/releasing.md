# Building the macOS app

The app bundles a universal (Apple Silicon and Intel) guard executable. Installation uses the same preflight, rollback and restricted permission as the command-line installer. No compiler or Terminal is required on the recipient's Mac.

## Local development build

```sh
bash scripts/build-app.sh --development
```

This builds `dist/DisplayLink Guard.app` and a DMG named `DisplayLink-Guard-<version>-development.dmg`. The development build is ad-hoc signed for local testing. It is **not notarized** and must not be presented as a normal public download. Do not advise users to disable Gatekeeper or remove quarantine attributes.

Test the window, fresh setup, administrator-authentication cancellation, update, and removal on a Mac with DisplayLink Manager. Unit tests simulate setup and cleanup failures; they cannot replace this interactive check.

## Signing prerequisites

Use an Apple Developer Program account with:

- A **Developer ID Application** certificate and its private key in the local keychain. An Apple Development certificate is not sufficient. This project uses a DMG, so no Developer ID Installer certificate is needed.
- A notarization credential profile stored in the keychain by `notarytool`. Do not put passwords, private keys or credentials in this repository.

Create the certificate in Xcode → Settings → Accounts → select the team → Manage Certificates. The account holder may need to create the Developer ID certificate. See [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

Create a notarization profile interactively:

```sh
xcrun notarytool store-credentials displaylink-guard
```

Enter credentials directly into Apple's prompt, not into a chat, issue, script or commit. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Signed release

After tests pass, choose the version and the exact Developer ID identity shown by `security find-identity -v -p codesigning`:

```sh
APP_VERSION=0.2.0 \
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE=displaylink-guard \
bash scripts/build-app.sh --release
```

The script builds both architectures, signs the nested executable and app with hardened runtime and a secure timestamp, notarizes and staples the app, creates the DMG, then signs, notarizes and staples the DMG. It checks signatures and Gatekeeper assessment and produces a SHA-256 checksum file. A missing identity, failed notarization or failed validation stops the release build.

Upload only the release DMG and its `.sha256` file to a versioned GitHub release after manually verifying that a quarantined download opens through the normal macOS flow. Do not upload the development DMG, a private key, or the staging directory. Update the README with a direct link to the signed download when that release exists.

CI builds a development package to catch packaging regressions. It does not receive signing credentials or publish downloads.
