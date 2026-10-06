# TODO

Ideas and deferred work that is not planned yet.

## Distribution

- **Auto-update with Sparkle.** Sparkle (MIT, free) checks an appcast XML feed, downloads the new version, and replaces the app. Needs:
  - an EdDSA key pair for signing updates; the private key stays out of the repo;
  - Developer ID signing and notarization (Apple Developer Program, $99 per year);
  - appcast and archives hosted somewhere, for example GitHub Releases;
  - a check that the privileged helper and the status line path survive an update.

  It is a third-party dependency, so it needs agreement before it is added. Only worth doing once someone other than the author installs Workdeck.
