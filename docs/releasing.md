# Releasing Workdeck

Workdeck updates itself through [Sparkle](https://sparkle-project.org): the app reads `appcast.xml` from the newest GitHub release, and a release is built, signed and published by GitHub Actions (`.github/workflows/release.yml`) when a version tag is pushed. Design: [`specs/2026-11-04-in-app-updates-design.md`](../specs/2026-11-04-in-app-updates-design.md).

## Cutting a Release

1. Make sure `CHANGELOG.md` has lines under `## Unreleased` (every feature and fix adds one; see CLAUDE.md).
2. `make release-prep VERSION=1.3.0` — moves Unreleased under `## 1.3.0 — <today>`, sets `MARKETING_VERSION` to 1.3.0, increments the build number, and commits `chore: release 1.3.0`. It refuses a dirty tree, a version not above the current one, and an empty Unreleased.
3. `git push origin main`, then `git tag v1.3.0 && git push origin v1.3.0`.
4. Watch the Release workflow in the repository's Actions tab. It checks the tag against the project and the changelog, builds and signs the app, zips it, signs the zip for Sparkle, writes `appcast.xml`, and creates the release `v1.3.0` with the zip, the appcast and the version's notes.

Installed copies find the version at their next daily check, or at once with Settings → About → Check for Updates.

If a run fails before publishing because of the setup (a secret, the runner, the Xcode image), fix that and rerun the job from the Actions tab: it builds the same tagged commit. If the code needs a fix, the `v*` ruleset keeps the tag where it is: commit the fix, add a changelog line, and release the next patch version (`make release-prep VERSION=1.3.1`). A failed run publishes nothing, so the unused tag only needs cleaning up if you want to: deleting a `v*` tag (or a published release's tag) takes the owner's bypass in the ruleset. Never reuse a version number that was published: installed copies may already have it.

## One-Time Setup

### Signing secrets

In the repository: **Settings → Environments → New environment** `release`.

- **Deployment branches and tags:** Selected branches and tags → add the tag rule `v*`. Nothing else can deploy to it, so no other workflow or branch can read its secrets.
- **Environment secrets:**
  - `CERTIFICATE_P12_BASE64` — the Apple Development certificate with its private key. In Keychain Access, find "Apple Development: …" (team `J55BY69CVU`) under My Certificates, right-click → Export → `.p12` with a password; then `base64 -i Workdeck-signing.p12 | pbcopy` and paste. Delete the `.p12` file afterwards.
  - `CERTIFICATE_PASSWORD` — that password.
  - `SPARKLE_PRIVATE_KEY` — the Sparkle signing key. It was generated into the login Keychain with Sparkle's `generate_keys` (its public half is `SUPublicEDKey` in `Config/Workdeck-Info.plist`). Export it with `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt` (after `make build`), paste the file's contents, then delete the file. Keep the Keychain copy: losing the key means installed copies can no longer be updated.

### Tags

**Settings → Rules → Rulesets → New tag ruleset** for `v*`: restrict creations to the repository owner (bypass list: you), and block updates and deletions.

### Account

Two-factor authentication is on; a passkey or a security key is the strongest second factor.

## Renewing the Certificate

An Apple Development certificate lasts a year. After renewing it in Xcode (Settings → Accounts → Manage Certificates), export the new one as above and replace `CERTIFICATE_P12_BASE64` and `CERTIFICATE_PASSWORD`. The team stays `J55BY69CVU`, so installed copies and the privileged helper accept builds signed with the new certificate.

## Accepted Risk

Because the signing secrets live in GitHub, whoever took over the GitHub account could publish an update that installed copies accept, including a new privileged helper. This was chosen over signing on the author's Mac (spec §1, Accepted Risk); the environment, the tag ruleset and two-factor authentication narrow who can reach the secrets but do not remove the risk.

## Notes From the First Runs

- The first run (2026-11-04) failed before building: `macos-26` has only Xcode 26.x. Releases run on the `xcode-27` image (public preview, macOS 27) with its default Xcode; move to a GA label once GitHub has one with Xcode 27.
- Signing on the runner uses `CODE_SIGN_STYLE=Manual` with the Apple Development identity from the temporary keychain, and the app is taken from the archive (no `-exportArchive`). The 1.1.0 run on `xcode-27` (2026-11-04) proved it: no provisioning profile or Apple account session is needed, every piece of code in the zip is signed by `J55BY69CVU`, and the zip's Sparkle signature verifies with the release key.
- Xcode's "Code Sign on Copy" signs `Sparkle.framework` but leaves its helpers (`Autoupdate`, `Updater.app`, `Installer.xpc`, `Downloader.xpc`) ad-hoc signed; `scripts/release/resign-sparkle.sh` signs them with the release identity, innermost first, and reseals the app, and `scripts/release/check-signatures.sh` fails the run if any code in the app is ad-hoc or another team's. Both can be run locally on a copy of a built app (pass the identity's SHA-1 from `security find-identity -v -p codesigning` when the Keychain holds more than one Apple Development identity).
