#!/usr/bin/env bash
# mise description="Build, Developer ID sign, notarize, GitHub-release, and update the Homebrew cask"
#
# Usage: mise run release [build-date]
#   build-date defaults to today (YYYYMMDD). Produces version 1.1.16-tme.<build-date>.
#
# One-time setup required before the first run (see CLAUDE.md "Signed release"):
#   1. A "Developer ID Application" cert installed (EPCO Concepts team).
#   2. A shared App Store Connect API key (.p8) for the EPCO team, stored in 1Password as
#      item "EPCO-ASC-API" with fields: issuer, key-id, key (the .p8 contents).
set -euo pipefail

# ---- config ----
REPO="tmepple/Browserino"                 # fork (GitHub releases live here)
TAP_REPO="tmepple/homebrew-tap"           # cask lives here
TAP_BRANCH="master"
TAP_NAME="tmepple/tap"                    # brew-facing tap name
BUNDLE_ID="xyz.alexstrnik.Browserino"
SCHEME="Browserino"
PROJECT="Browserino.xcodeproj"
OP_ITEM="op://Private/EPCO-ASC-API"       # shared EPCO App Store Connect API key; adjust vault if needed
# The item lives in the personal 1Password account, not the work account that may also be
# signed in. op has no per-reference account syntax, so scope all op calls via OP_ACCOUNT.
export OP_ACCOUNT="${OP_ACCOUNT:-epples.1password.com}"

die() { echo "error: $*" >&2; exit 1; }

# repo root = two levels above .mise/tasks/
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# MARKETING_VERSION is the source of truth in project.pbxproj
MARKETING_VERSION="$(awk -F'= ' '/MARKETING_VERSION/{gsub(/[ ;]/,"",$2); print $2; exit}' "$PROJECT/project.pbxproj")"
[[ -n "$MARKETING_VERSION" ]] || die "could not read MARKETING_VERSION from $PROJECT/project.pbxproj"

BUILD_DATE="${1:-$(date +%Y%m%d)}"
VERSION="${MARKETING_VERSION}-tme.${BUILD_DATE}"
TAG="v${VERSION}"

# ---- temp workspace + cleanup ----
P8=""
WORK=""
TAP_CLONE=""
cleanup() {
  [[ -n "$P8"        && -f "$P8"        ]] && rm -f "$P8"
  [[ -n "$WORK"      && -d "$WORK"      ]] && rm -rf "$WORK"
  [[ -n "$TAP_CLONE" && -d "$TAP_CLONE" ]] && rm -rf "$TAP_CLONE"
}
trap cleanup EXIT

# ---- 1. preflight ----
[[ -z "$(git status --porcelain)" ]] || die "git tree not clean; commit or stash first"
git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists"

DEVID_LINE="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)"
if [[ -z "$DEVID_LINE" ]]; then
  cat >&2 <<'EOF'
No "Developer ID Application" certificate found. One-time setup:
  Xcode > Settings > Accounts > EPCO Concepts > Manage Certificates
        > + > Developer ID Application
Then re-run this task.
EOF
  exit 1
fi
TEAM_ID="$(echo "$DEVID_LINE" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')"
[[ -n "$TEAM_ID" ]] || die "could not parse team id from: $DEVID_LINE"
echo "Identity: $DEVID_LINE"
echo "Team:     $TEAM_ID"
echo "Version:  $VERSION"

command -v op >/dev/null || die "1Password CLI (op) not found"
op whoami >/dev/null 2>&1 || die "not signed into 1Password account '$OP_ACCOUNT'; run: op signin --account $OP_ACCOUNT"

# ---- 2. notary credentials from 1Password (rendered to temp, removed on exit) ----
P8="$(mktemp -t browserino-notary)"
op read "${OP_ITEM}/key" > "$P8" || die "could not read ${OP_ITEM}/key"
KEY_ID="$(op read "${OP_ITEM}/key-id")"
ISSUER_ID="$(op read "${OP_ITEM}/issuer")"
[[ -s "$P8" && -n "$KEY_ID" && -n "$ISSUER_ID" ]] || die "incomplete notary credentials in 1Password"

# ---- 3. build signed Release ----
echo "==> Building signed Release..."
rm -rf build
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  "CODE_SIGN_IDENTITY[sdk=macosx*]=Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  "DEVELOPMENT_TEAM[sdk=macosx*]=$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

APP="$ROOT/build/Build/Products/Release/Browserino.app"
[[ -d "$APP" ]] || die "build did not produce $APP"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP"

# ---- 4. notarize + staple ----
WORK="$(mktemp -d)"
echo "==> Notarizing (automated scan, typically 1-3 min)..."
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" \
  --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" \
  --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv "$APP" || true

# ---- 5. package the stapled app ----
ASSET="$WORK/Browserino-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ASSET"
SHA256="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
echo "Asset:  $(basename "$ASSET")"
echo "sha256: $SHA256"

# ---- 6. GitHub release on the fork ----
echo "==> Creating GitHub release $TAG..."
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ASSET" \
  --repo "$REPO" --latest \
  --title "$TAG" \
  --notes "tmepple fork of Browserino v${MARKETING_VERSION} (build ${BUILD_DATE}). Developer ID signed + notarized."

# ---- 7. update the cask in the tap ----
echo "==> Updating cask in $TAP_REPO..."
TAP_CLONE="$(mktemp -d)"
git clone --depth 1 --branch "$TAP_BRANCH" "git@github.com:${TAP_REPO}.git" "$TAP_CLONE"
mkdir -p "$TAP_CLONE/Casks"
cat > "$TAP_CLONE/Casks/browserino-tme.rb" <<EOF
cask "browserino-tme" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPO}/releases/download/v#{version}/Browserino-#{version}.zip"
  name "Browserino (tmepple fork)"
  desc "Browser picker — tmepple fork"
  homepage "https://github.com/${REPO}"

  depends_on macos: ">= :ventura"

  app "Browserino.app"

  zap trash: ["~/Library/Preferences/${BUNDLE_ID}.plist"]
end
EOF
git -C "$TAP_CLONE" add Casks/browserino-tme.rb
git -C "$TAP_CLONE" commit -m "browserino-tme ${VERSION}"
git -C "$TAP_CLONE" push origin "$TAP_BRANCH"

# ---- done ----
cat <<EOF

✓ Released ${TAG}
  Release: https://github.com/${REPO}/releases/tag/${TAG}
  Install: brew install --cask ${TAP_NAME}/browserino-tme
  Upgrade: brew upgrade --cask browserino-tme

  Brewfile:
    tap "${TAP_NAME}"
    cask "browserino-tme"
EOF
