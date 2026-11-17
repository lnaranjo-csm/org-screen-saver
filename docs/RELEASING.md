# Releasing

Updates are delivered through GitHub Releases. The app's updater reads the latest release, downloads the `.zip`, checks it against the `.zip.sha256` file, and swaps the app in place.

## One-time setup

1. Create the **public** GitHub repo and push this folder to it. (The updater makes unauthenticated requests, so the repo must be public.)
2. The workflow sets the update repo automatically from `github.repository`. For local builds, set it yourself: `UPDATE_REPO=your-org/org-screen-saver make app`
3. Create the release signing certificate and store it as secrets (see "Signing" below). Do this **before the first release**.
4. Optional: in the repo settings, protect `main` and require the `CI` check.

## Cutting a release

1. Edit `VERSION` (for example `1.3.0`).
2. Add a `**1.3.0**` block with bullets under "What's new" in `README.md`. The workflow uses that block as the release notes (falls back to "Release 1.3.0" if missing).
3. Commit and push to `main`, wait for `CI` to pass.
4. Tag and push: `git tag v1.3.0 && git push origin v1.3.0`
5. The `Release` workflow runs the tests, imports the signing certificate, builds the app, creates `OrgScreenSaver-1.3.0.zip` and `OrgScreenSaver-1.3.0.zip.sha256`, and publishes the release. It fails if the tag and `VERSION` disagree.

Assets must be named so the zip ends in `.zip` and the checksum in `.zip.sha256`, which `scripts/package-release.sh` does.

`CI` (`.github/workflows/ci.yml`) builds and tests every push to `main` and every pull request.

## Signing (important)

macOS ties Accessibility, Screen Recording and Camera approvals to the app's code signature. An **ad-hoc** signature changes with every build, so users would have to re-grant permissions after every update. Release builds are therefore signed with one stable certificate that is used for every release.

### Create the release certificate (once)

```bash
scripts/make-release-cert.sh ~/Documents/org-screen-saver-release-cert   # any folder OUTSIDE the repo
base64 -i ~/Documents/org-screen-saver-release-cert/release.p12 | gh secret set RELEASE_CERT_P12_BASE64
gh secret set RELEASE_CERT_PASSWORD < ~/Documents/org-screen-saver-release-cert/release.p12.password
```

This makes a self-signed code-signing certificate valid for 10 years. **Back up `release.p12` and its password in a password manager.** Never commit them. If the certificate is lost or replaced, the next release has a different identity and every user has to re-grant permissions once. If the secrets are missing, the workflow still publishes but signs ad-hoc and prints a warning.

### What users see

- A self-signed certificate is not notarized, so a downloaded zip is blocked by Gatekeeper until the quarantine flag is removed: `xattr -dr com.apple.quarantine "$HOME/Applications/Org Screen Saver.app"` (or right-click > Open once). `install.sh` builds locally and the in-app updater removes the flag itself, so only the first manual download needs this.
- After the first signed release, permissions persist across updates. Users who were on an ad-hoc build re-grant them once.
- Local builds signed with your own Apple Development certificate are a different identity from release builds. To test the updater, install a release build, not a local one.

### Better option, if it is ever worth the money

An Apple Developer ID certificate ($99/year) plus notarization removes the Gatekeeper step entirely. It would replace the self-signed certificate in the same secrets and add a notarization step to the workflow.

### Local builds

`scripts/build-app-bundle.sh` signs with `CODESIGN_IDENTITY` if set, else the first "Apple Development" certificate in your keychain, else ad-hoc.

## Private repositories

The updater makes unauthenticated requests, so it only works with public repos or GitHub Enterprise instances reachable without a token. A private repo needs a token added to the updater, which this version does not have.
