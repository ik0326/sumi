#!/bin/sh
# Builds, signs and publishes a release.
#
#   scripts/release.sh <notes.md>
#
# The version comes from MARKETING_VERSION in project.yml; bump it (and CURRENT_PROJECT_VERSION)
# and commit before running. Needs xcodegen, the GitHub CLI (gh) and the Sparkle signing key in
# the login Keychain (account "sumi"; see generate_keys in the Sparkle package).
set -eu

cd "$(dirname "$0")/.."
NOTES="${1:?usage: scripts/release.sh <notes.md>}"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
TAG="v$VERSION"
REPO="ik0326/sumi"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }

xcodegen generate >/dev/null
xcodebuild -project Sumi.xcodeproj -scheme Sumi -configuration Release -derivedDataPath "$OUT/dd" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build | grep -E " error|BUILD " || true
APP="$OUT/dd/Build/Products/Release/Sumi.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ]
codesign --verify --deep --strict "$APP"
LEAKS=$(grep -rl "$HOME" "$APP" || true)
if [ -n "$LEAKS" ]; then
  echo "The build contains your home folder path in:"; echo "$LEAKS"
  echo "$LEAKS" | while read -r f; do LC_ALL=C grep -a -o ".\{0,50\}$HOME.\{0,90\}" "$f" | LC_ALL=C tr -c '[:print:]\n' '.' | sort -u | head -5; done
  exit 1
fi

mkdir "$OUT/feed"
ZIP="Sumi-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT/feed/$ZIP"

# The appcast lists this release with a signature made by the private key.
BIN="$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$BIN/generate_appcast" --account sumi \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" -o "$OUT/feed/appcast.xml" "$OUT/feed"
grep -q "edSignature" "$OUT/feed/appcast.xml"

{ cat "$NOTES"; printf '\nSHA-256 of `%s`: `%s`\n' "$ZIP" "$(shasum -a 256 "$OUT/feed/$ZIP" | cut -c1-64)"; } > "$OUT/notes.md"

git tag -a "$TAG" -m "Sumi $VERSION"
git push origin main "$TAG"
gh release create "$TAG" "$OUT/feed/$ZIP" "$OUT/feed/appcast.xml" --title "Sumi $VERSION" --notes-file "$OUT/notes.md"
echo "Released $TAG"
