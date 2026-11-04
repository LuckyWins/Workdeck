#!/bin/bash
# Installs the newest Workdeck: https://luckywins.github.io/Workdeck/
#
#   curl -fsSL https://luckywins.github.io/Workdeck/install.sh | bash
#
# What it does, in order:
#   1. checks this is macOS 26 or later;
#   2. reads the release feed Workdeck's own updates use (appcast.xml on GitHub) for the newest version;
#   3. downloads that zip into a temporary folder and checks it is signed by Workdeck's team (J55BY69CVU);
#   4. quits a running Workdeck like a restart, so Closed-Lid Mode carries over;
#   5. puts the app in /Applications (the old one stays until the new one is fully copied) and opens it.
# It never uses sudo and touches nothing but /Applications/Workdeck.app and its temporary folder.
#
# For testing: WORKDECK_APPCAST_URL reads another feed, WORKDECK_INSTALL_DIR installs elsewhere; with another
# install folder the running Workdeck is neither quit nor opened.
#
# Everything runs from `main` on the last line, so a download cut short runs nothing.

set -euo pipefail

APPCAST_URL="${WORKDECK_APPCAST_URL:-https://github.com/LuckyWins/Workdeck/releases/latest/download/appcast.xml}"
INSTALL_DIR="${WORKDECK_INSTALL_DIR:-/Applications}"
TEAM_ID="J55BY69CVU"
# Workdeck itself (its bundle id), signed by a certificate of Workdeck's team.
REQUIREMENT="anchor apple generic and identifier \"com.appcreators.workdeck\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
# The floor before the feed says more: the feed's sparkle:minimumSystemVersion decides (check_release_fits).
MINIMUM_MACOS=26
SYSTEM_INSTALL_DIR="/Applications"

say() {
  if [ -t 1 ]; then
    printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"
  else
    printf '==> %s\n' "$1"
  fi
}

fail() {
  if [ -t 2 ]; then
    printf '\033[1;31mError:\033[0m %s\n' "$1" >&2
  else
    printf 'Error: %s\n' "$1" >&2
  fi
  exit 1
}

check_mac() {
  [ "$(uname -s)" = "Darwin" ] || fail "Workdeck runs on macOS only."
  local version major
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  [ "$major" -ge "$MINIMUM_MACOS" ] || fail "Workdeck needs macOS $MINIMUM_MACOS or later (this Mac has $version)."
}

# Sets VERSION and ZIP_URL from the feed's newest item.
read_appcast() {
  local feed="$1/appcast.xml"
  curl -fsSL "$APPCAST_URL" -o "$feed" 2>/dev/null \
    || fail "Could not download the release information. Check the connection and try again."
  VERSION="$(xmllint --xpath 'string(//item[1]/*[local-name()="shortVersionString"])' "$feed" 2>/dev/null || true)"
  ZIP_URL="$(xmllint --xpath 'string(//item[1]/enclosure/@url)' "$feed" 2>/dev/null || true)"
  [ -n "$ZIP_URL" ] && [ -n "$VERSION" ] || fail "The release information has no download."
  MINIMUM_SYSTEM="$(xmllint --xpath 'string(//item[1]/*[local-name()="minimumSystemVersion"])' "$feed" 2>/dev/null || true)"
}

# True when version $1 is at least $2 (numbers separated by dots).
version_at_least() {
  awk -v have="$1" -v need="$2" 'BEGIN {
    split(have, h, "."); split(need, n, ".")
    for (i = 1; i <= 3; i++) { a = h[i] + 0; b = n[i] + 0; if (a > b) exit 0; if (a < b) exit 1 }
    exit 0
  }'
}

# A release that needs a newer macOS than this Mac has would install and then not open.
check_release_fits() {
  [ -n "${MINIMUM_SYSTEM:-}" ] || return 0
  local this_mac
  this_mac="$(sw_vers -productVersion)"
  version_at_least "$this_mac" "$MINIMUM_SYSTEM" \
    || fail "Workdeck $VERSION needs macOS $MINIMUM_SYSTEM or later (this Mac has $this_mac)."
}

download() {
  local folder="$1"
  say "Downloading Workdeck ${VERSION}…"
  curl -fsSL "$ZIP_URL" -o "$folder/Workdeck.zip" \
    || fail "Could not download Workdeck $VERSION. Check the connection and try again."
  ditto -x -k "$folder/Workdeck.zip" "$folder/unzipped" 2>/dev/null \
    || fail "The download is damaged; nothing was installed."
  [ -d "$folder/unzipped/Workdeck.app" ] || fail "The download has no Workdeck.app; nothing was installed."
}

verify() {
  say "Checking the signature (team ${TEAM_ID})…"
  codesign --verify --deep --strict -R="$REQUIREMENT" "$1" 2>/dev/null \
    || fail "The download is not signed by Workdeck's team; nothing was installed."
}

# Quits Workdeck with SIGTERM, Workdeck's restart signal (as `make install` does): the helper keeps sleep off while
# the new version starts, so Closed-Lid Mode carries over, and no Apple event asks for Automation access.
quit_running() {
  local expected="$SYSTEM_INSTALL_DIR/Workdeck.app/Contents/MacOS/Workdeck" pid path me
  # This user's Workdeck only: another user's (fast user switching) cannot be quit from here.
  me="$(id -u)"
  pgrep -U "$me" -x Workdeck > /dev/null || return 0
  for pid in $(pgrep -U "$me" -x Workdeck); do
    path="$(ps -o comm= -p "$pid" || true)"
    if [ -n "$path" ] && [ "$path" != "$expected" ]; then
      fail "Workdeck is running from $path; quit it and run the command again."
    fi
  done
  say "Quitting the running Workdeck…"
  pkill -U "$me" -x Workdeck || true
  for _ in $(seq 50); do
    pgrep -U "$me" -x Workdeck > /dev/null || return 0
    sleep 0.2
  done
  fail "Quit Workdeck from its menu and run the command again."
}

warn() {
  if [ -t 2 ]; then
    printf '\033[1;33mWarning:\033[0m %s\n' "$1" >&2
  else
    printf 'Warning: %s\n' "$1" >&2
  fi
}

# Copies the new app next to the old one before anything else changes, so a folder that cannot be written or a full
# disk stops the script while Workdeck still runs untouched.
stage_app() {
  local app="$1"
  [ -w "$INSTALL_DIR" ] || fail "Cannot write to $INSTALL_DIR. Sign in as an administrator and run the command again."
  STAGED="$INSTALL_DIR/.Workdeck.app.new"
  rm -rf "$STAGED" 2>/dev/null || true
  ditto "$app" "$STAGED" 2>/dev/null || fail "Could not copy Workdeck to $INSTALL_DIR; nothing was changed."
}

# Swaps the staged app in by renaming: the old app is set aside whole, never left half deleted in place, and comes
# back if the new one cannot be put there.
swap_app() {
  local target="$INSTALL_DIR/Workdeck.app" previous="$INSTALL_DIR/.Workdeck.app.old"
  say "Installing to ${target}…"
  rm -rf "$previous" 2>/dev/null || true
  if [ -e "$target" ] && ! mv "$target" "$previous" 2>/dev/null; then
    reopen_previous
    fail "Could not replace $target; the previous version was kept."
  fi
  if ! mv "$STAGED" "$target" 2>/dev/null; then
    [ -e "$previous" ] && mv "$previous" "$target" 2>/dev/null
    reopen_previous
    fail "Could not put Workdeck in $INSTALL_DIR; the previous version was kept."
  fi
  rm -rf "$previous" 2>/dev/null || warn "Could not remove the previous version at $previous; you can delete it."
}

# After the running Workdeck was quit, a failure must not leave it closed (Closed-Lid Mode would end).
reopen_previous() {
  if [ "${QUIT_DONE:-false}" = true ] && [ -e "$INSTALL_DIR/Workdeck.app" ]; then
    open "$INSTALL_DIR/Workdeck.app" 2>/dev/null || true
  fi
}

main() {
  check_mac
  # Global: the EXIT trap runs after main has returned.
  TMP_DIR="$(mktemp -d)"
  # The staged copy goes too when the script stops before the swap.
  trap 'rm -rf "${TMP_DIR:-}" "${STAGED:-}"' EXIT
  read_appcast "$TMP_DIR"
  check_release_fits
  download "$TMP_DIR"
  verify "$TMP_DIR/unzipped/Workdeck.app"
  local system_install=false
  [ "$INSTALL_DIR" = "$SYSTEM_INSTALL_DIR" ] && system_install=true
  stage_app "$TMP_DIR/unzipped/Workdeck.app"
  if $system_install; then
    quit_running
    QUIT_DONE=true
  fi
  swap_app
  if $system_install; then
    say "Opening Workdeck"
    open "$INSTALL_DIR/Workdeck.app"
  fi
  echo "Workdeck $VERSION is installed."
  echo "Next: click the Workdeck icon in the menu bar → gear → Settings → Connect."
  echo "Updates install themselves from now on."
}

main "$@"
