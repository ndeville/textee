#!/bin/zsh
# Build Textee.app.
#
#   ./build.sh            Release build into build.noindex/Textee.app, signed with your signing identity (see below)
#   ./build.sh --install  also copy it to /Applications/Textee.app (quits the running copy first)
#   ./build.sh --icon     redraw the app icon first
#
# Steps: app icon (NicAI generator, blue plate), XcodeGen project, xcodebuild, codesign.
#
# Signing identity: $TEXTEE_SIGN_IDENTITY, else TEXTEE_SIGN_IDENTITY in .private/signing.env (git-ignored), for example
#   TEXTEE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# Without one, the app is signed ad hoc: it runs, but the signature changes with every build, so macOS treats each
# build as a new app.

set -euo pipefail
cd "${0:A:h}"

INSTALL=false
ICON=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --icon) ICON=true ;;
  esac
done

start=$(date +%s)
RES=TexteeMac/Resources
if [[ -z "${TEXTEE_SIGN_IDENTITY:-}" && -f .private/signing.env ]]; then
  source .private/signing.env
fi
IDENTITY="${TEXTEE_SIGN_IDENTITY:--}"
mkdir -p "$RES" build.noindex

# 1. App icon: the NicAI layout on a blue gradient plate (Nic's choice for Textee, 12th October 2026).
if $ICON || [[ ! -f "$RES/AppIcon.icns" ]]; then
  echo "🎨 App icon"
  python3 ~/ai/_shared/nicai-design/app_icon.py --name Textee --plate "gradient:#4a86ff,#2259d6,#0f2f86" --out build.noindex/appicon
  cp -f build.noindex/appicon/AppIcon.icns "$RES/AppIcon.icns"
  mkdir -p assets/icon && cp -f build.noindex/appicon/AppIcon.svg build.noindex/appicon/AppIcon-1024.png assets/icon/
fi

# 2. Project and build (unsigned; signed below).
echo "🛠  xcodegen"
xcodegen generate --quiet
echo "🛠  xcodebuild (Release)"
if ! xcodebuild -project Textee.xcodeproj -scheme Textee -configuration Release -derivedDataPath build.noindex/DerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet build > build.noindex/xcodebuild.log 2>&1; then
  grep -E "error:" build.noindex/xcodebuild.log | sort -u | head -40 >&2
  echo "❌ build failed (build.noindex/xcodebuild.log)" >&2
  exit 1
fi
APP=build.noindex/DerivedData/Build/Products/Release/Textee.app
rm -rf build.noindex/Textee.app
cp -R "$APP" build.noindex/Textee.app

# 3. Sign. No timestamp: the build stays offline and fast, and Textee isn't notarised.
if [[ "$IDENTITY" == "-" ]]; then
  echo "⚠️  no signing identity: ad-hoc signature (set TEXTEE_SIGN_IDENTITY, see the top of this file)"
fi
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none build.noindex/Textee.app
codesign --verify --strict build.noindex/Textee.app

# Only /Applications/Textee.app opens files from Finder: the build copies leave the LaunchServices list.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREGISTER -u "$PWD/$APP" "$PWD/build.noindex/Textee.app" 2>/dev/null || true

if $INSTALL; then
  if pgrep -f /Applications/Textee.app/Contents/MacOS/Textee >/dev/null; then
    echo "⏹  quitting the running Textee (it saves every tab first)"
    osascript -e 'tell application id "com.nicolasdeville.textee" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -f /Applications/Textee.app/Contents/MacOS/Textee >/dev/null || break; sleep 0.1; done
  fi
  rm -rf /Applications/Textee.app
  cp -R build.noindex/Textee.app /Applications/Textee.app
  $LSREGISTER -f /Applications/Textee.app
  echo "✅ installed /Applications/Textee.app"
fi

size=$(du -sh build.noindex/Textee.app | cut -f1)
echo "✅ build.noindex/Textee.app ($size) in $(( $(date +%s) - start ))s"
