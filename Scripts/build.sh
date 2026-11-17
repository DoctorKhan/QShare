#!/bin/bash
# Builds QShare.app into ./build. Pass --install to also copy it to /Applications,
# --run to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

# Restarting the app drops any transfer in progress, so refuse while one is running.
if [[ " $* " == *" --install "* || " $* " == *" --run "* ]] && \
   lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -q "^QShare"; then
  echo "QShare is receiving a transfer right now; try again when it finishes." >&2
  exit 1
fi

xcodegen generate --quiet
xcodebuild -project QShare.xcodeproj -scheme QShare -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -quiet build

APP="build/QShare.app"
rm -rf "$APP"
cp -R "build/DerivedData/Build/Products/Release/QShare.app" "$APP"

# Sign with a stable identity when one exists so macOS remembers the Local Network and
# Bluetooth permissions across rebuilds; otherwise fall back to an ad-hoc signature.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && /\)/ {print $2}')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      killall QShare 2>/dev/null && sleep 1 || true
      rm -rf /Applications/QShare.app
      cp -R "$APP" /Applications/QShare.app
      APP="/Applications/QShare.app"
      echo "Installed $APP"
      ;;
  esac
done
for arg in "$@"; do
  if [ "$arg" = "--run" ]; then
    killall QShare 2>/dev/null && sleep 1 || true
    open "$APP"
  fi
done
