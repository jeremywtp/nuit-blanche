#!/bin/bash
# Compile Nuit Blanche et assemble « build/Nuit Blanche.app ».
#   ./build.sh            compile seulement
#   ./build.sh --install  compile, installe dans ~/Applications et relance l’app
set -euo pipefail
cd "$(dirname "$0")"

# App universelle : Apple Silicon et Intel (macOS 26 tourne encore sur certains Mac Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/NuitBlanche"

# Icône Liquid Glass : document Icon Composer (Resources/AppIcon.icon) compilé par actool
# en Assets.car (rendu verre, variantes sombre / teintée / transparente) + AppIcon.icns de secours.
[ -d Resources/AppIcon.icon ] || swift tools/make-icon.swift Resources/AppIcon.icon
ICON_OUT=build/icon
if [ ! -f "$ICON_OUT/Assets.car" ] || [ -n "$(find Resources/AppIcon.icon -newer "$ICON_OUT/Assets.car" 2>/dev/null)" ]; then
  rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
  xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --platform macosx \
    --minimum-deployment-target 26.0 --target-device mac --app-icon AppIcon \
    --output-partial-info-plist "$ICON_OUT/partial.plist" --errors --warnings >/dev/null
  [ -f "$ICON_OUT/Assets.car" ] || { echo "actool n’a pas produit Assets.car" >&2; exit 1; }
fi

APP="build/Nuit Blanche.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NuitBlanche"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
cp Resources/scripts/* "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/nuitblanche" "$APP/Contents/Resources/nuitblanche-watchdog"
codesign --force --sign - --timestamp=none "$APP"
# La copie de build/ ne doit jamais répondre aux URL nuitblanche:// à la place de l'app installée
# (même identifiant) : on la retire de LaunchServices.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$APP" 2>/dev/null || true
echo "Application prête : $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/Nuit Blanche.app"
  if pgrep -xq NuitBlanche; then
    pkill -TERM -x NuitBlanche || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq NuitBlanche || break; sleep 0.3; done
  fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  touch "$DEST"
  open "$DEST"
  echo "Installée et lancée : $DEST"
fi
