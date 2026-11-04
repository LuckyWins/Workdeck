#!/bin/bash
# Fails when any code in the app is ad-hoc signed or signed by another team (in-app updates spec §5).
# Usage: check-signatures.sh Workdeck.app TEAM_ID
set -euo pipefail
APP="$1"
TEAM="$2"
status=0
while IFS= read -r -d '' item; do
  info="$(codesign -dv "$item" 2>&1 || true)"
  if grep -q "Signature=adhoc" <<<"$info" || ! grep -q "TeamIdentifier=$TEAM" <<<"$info"; then
    echo "not signed by $TEAM: ${item#"$APP"/}"
    status=1
  fi
done < <(find "$APP" \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" -o -name "*.dylib" \) -print0; \
         find "$APP" -type f -perm -u+x -not -path "*/_CodeSignature/*" -print0)
codesign --verify --deep --strict "$APP"
if [ "$status" -eq 0 ]; then echo "all code signed by $TEAM"; fi
exit "$status"
