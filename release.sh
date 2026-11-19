#!/bin/bash
# Publie une version de Nuit Blanche sur GitHub (celle qu'installe install.sh).
#   ./release.sh 1.1
#
# Vérifie que tout est commité, passe la version dans Info.plist, lance les tests, compile l'app universelle,
# l'archive (NuitBlanche.zip + somme SHA-256), vérifie l'archive comme le fera install.sh, puis pousse le tag
# et crée la release GitHub.
set -euo pipefail
cd "$(dirname "$0")"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }

VERSION=${1:-}
VERSION=${VERSION#v}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Usage : ./release.sh <version> (exemple : 1.1)"
TAG="v$VERSION"
PLIST=Resources/Info.plist
PB=/usr/libexec/PlistBuddy

command -v gh >/dev/null || die "gh (GitHub CLI) est requis."
gh auth status >/dev/null 2>&1 || die "gh n'est pas connecté : gh auth login"
[ "$(git branch --show-current)" = main ] || die "À lancer depuis la branche main."
[ -z "$(git status --porcelain)" ] || die "Des modifications ne sont pas commitées."
git fetch --quiet origin main
[ -z "$(git rev-list HEAD..origin/main)" ] || die "origin/main a des commits absents d'ici : git pull d'abord."
if gh release view "$TAG" >/dev/null 2>&1; then die "La release $TAG existe déjà."; fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "Le tag $TAG existe déjà."; fi

PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || true)

if [ "$($PB -c 'Print :CFBundleShortVersionString' "$PLIST")" != "$VERSION" ]; then
  BUILD=$(( $($PB -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
  $PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
  git commit --quiet -m "Version $VERSION" -- "$PLIST"
fi

swift test
./build.sh

APP="build/Nuit Blanche.app"
ZIP=build/NuitBlanche.zip
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 NuitBlanche.zip > NuitBlanche.zip.sha256)

# Contrôle de l'archive, comme install.sh : extraction, signature, identifiant, version, architectures.
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Nuit Blanche.app"
[ "$($PB -c 'Print :CFBundleShortVersionString' "$CHECK/Nuit Blanche.app/Contents/Info.plist")" = "$VERSION" ] \
  || die "La version de l'archive ne correspond pas."
lipo -info "$CHECK/Nuit Blanche.app/Contents/MacOS/NuitBlanche"

NOTES=$(mktemp)
{
  echo "## Installation"
  echo
  echo '```bash'
  echo "curl -fsSL https://raw.githubusercontent.com/jeremywtp/nuit-blanche/main/install.sh | bash"
  echo '```'
  echo
  echo "Relancer la même commande met à jour l'app. macOS 26 ou plus récent, Apple Silicon ou Intel."
  echo
  echo "## Changements"
  echo
  if [ -n "$PREVIOUS" ]; then
    git log --no-merges --pretty='- %s' "$PREVIOUS..HEAD"
  else
    echo "- Première version publique."
  fi
} > "$NOTES"

git tag -a "$TAG" -m "Nuit Blanche $VERSION"
git push --quiet origin main "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --verify-tag --title "Nuit Blanche $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
echo "✓ Nuit Blanche $VERSION publiée."
