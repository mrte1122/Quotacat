#!/bin/bash
# Publishes a signed release: ./scripts/release.sh 1.2.0 ["Release notes"]
# Bumps VERSION, builds the universal app, signs the zip, tags, pushes, and creates the
# GitHub release with Quotacat.zip and Quotacat.zip.sig. Without notes, GitHub generates them.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
die() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z [notes]"
[[ "$(git branch --show-current)" == "main" ]] || die "release from main"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first"
git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION already exists"

# The app only accepts updates signed by the key whose public half is compiled in.
PUB="$(swift scripts/sign-update.swift public)"
grep -q "$PUB" Sources/Quotacat/Updater.swift || die "signing key doesn't match Updater.publicKey"

echo "$VERSION" > VERSION
git add VERSION
git diff --cached --quiet || git commit -q -m "Release v$VERSION"

./scripts/build-app.sh --zip
build/Quotacat.app/Contents/MacOS/Quotacat --selftest >/dev/null || die "self-tests failed"
swift scripts/sign-update.swift sign build/Quotacat.zip > build/Quotacat.zip.sig

git tag "v$VERSION"
git push -q origin main "v$VERSION"

if [[ -n "$NOTES" ]]; then
    gh release create "v$VERSION" build/Quotacat.zip build/Quotacat.zip.sig --title "Quotacat $VERSION" --notes "$NOTES"
else
    gh release create "v$VERSION" build/Quotacat.zip build/Quotacat.zip.sig --title "Quotacat $VERSION" --generate-notes
fi
echo "Released v$VERSION"
