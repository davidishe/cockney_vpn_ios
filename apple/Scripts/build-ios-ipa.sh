#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
SCHEME="OlcRTCClient iOS"
CONFIGURATION="${CONFIGURATION:-Release}"
EXPORT_METHOD="${EXPORT_METHOD:-development}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$APPLE_DIR/.build/ios-archive}"
EXPORT_DIR="${EXPORT_DIR:-$APPLE_DIR/.build/ios-ipa}"
ARCHIVE_PATH="$ARCHIVE_DIR/Godwit.xcarchive"
EXPORT_OPTIONS="$ARCHIVE_DIR/ExportOptions.plist"

usage() {
  cat <<'MSG'
Usage:
  DEVELOPMENT_TEAM=ABCDE12345 ./apple/Scripts/build-ios-ipa.sh --olcrtc-root /path/to/olcrtc

The OlcRTC repository path can also be provided with OLCRTC_REPO_ROOT.
MSG
}

OLCRTC_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --olcrtc-root)
      OLCRTC_ROOT_ARG="${2:-}"
      if [[ -z "$OLCRTC_ROOT_ARG" ]]; then
        echo "--olcrtc-root requires a path" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

source "$APPLE_DIR/Scripts/olcrtc-root.sh"
OLCRTC_DIR="$(require_olcrtc_root "$OLCRTC_ROOT_ARG" "Usage: DEVELOPMENT_TEAM=ABCDE12345 ./apple/Scripts/build-ios-ipa.sh --olcrtc-root /path/to/olcrtc")"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  cat <<'MSG'
Xcode is required for iOS IPA builds.

Run these once in Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

Then rerun:
  ./apple/Scripts/build-ios-ipa.sh
MSG
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  cat <<'MSG'
Xcode iOS SDK is not ready.

Run these once in Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

Then rerun:
  ./apple/Scripts/build-ios-ipa.sh
MSG
  exit 1
fi

# Prefer env; else CockneyVPN/secrets/apple_development_team (one line, Team ID).
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  SECRETS_TEAM_FILE="${COCKNEY_APPLE_TEAM_FILE:-}"
  if [[ -z "$SECRETS_TEAM_FILE" ]]; then
    SECRETS_TEAM_FILE="$(cd "$ROOT_DIR/.." && pwd)/secrets/apple_development_team"
  fi
  if [[ -f "$SECRETS_TEAM_FILE" ]]; then
    DEVELOPMENT_TEAM="$(tr -d '[:space:]' < "$SECRETS_TEAM_FILE" || true)"
  fi
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  cat <<'MSG'
DEVELOPMENT_TEAM is required for an installable IPA.

Example:
  DEVELOPMENT_TEAM=ABCDE12345 EXPORT_METHOD=development ./apple/Scripts/build-ios-ipa.sh

Or put the Team ID in:
  CockneyVPN/secrets/apple_development_team

The app and packet tunnel extension App IDs must include Network Extension
(packet-tunnel) and App Group group.space.tokenova.cockney.ios.
MSG
  exit 1
fi

export DEVELOPMENT_TEAM

case "$EXPORT_METHOD" in
  development|ad-hoc|app-store|enterprise)
    ;;
  *)
    echo "Unsupported EXPORT_METHOD=$EXPORT_METHOD"
    echo "Use one of: development, ad-hoc, app-store, enterprise"
    exit 1
    ;;
esac

if ! command -v gomobile >/dev/null 2>&1; then
  go install golang.org/x/mobile/cmd/gomobile@latest
fi

gomobile init
"$APPLE_DIR/Scripts/build-xcframework.sh" --olcrtc-root "$OLCRTC_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$APPLE_DIR" && xcodegen generate)
fi

rm -rf "$ARCHIVE_DIR" "$EXPORT_DIR"
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

xcodebuild \
  -project "$APPLE_DIR/Godwit.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  archive

# SPM sometimes embeds a ~50KB Mobile.framework stub (MinimumOSVersion 100).
# Mobile symbols are statically linked into the app/appex, but replace the stub
# with the real ios-arm64 slice so dyld never loads a placeholder.
REAL_MOBILE="$APPLE_DIR/Frameworks/Mobile.xcframework/ios-arm64/Mobile.framework/Mobile"
EMBEDDED_MOBILE="$ARCHIVE_PATH/Products/Applications/Cockney.app/Frameworks/Mobile.framework/Mobile"
if [[ -f "$REAL_MOBILE" && -f "$EMBEDDED_MOBILE" ]]; then
  EMBEDDED_SIZE="$(wc -c < "$EMBEDDED_MOBILE" | tr -d ' ')"
  REAL_SIZE="$(wc -c < "$REAL_MOBILE" | tr -d ' ')"
  if [[ "$EMBEDDED_SIZE" -lt 1000000 && "$REAL_SIZE" -gt 1000000 ]]; then
    echo "Replacing stub Mobile.framework ($EMBEDDED_SIZE bytes) with real ios-arm64 ($REAL_SIZE bytes)"
    cp "$REAL_MOBILE" "$EMBEDDED_MOBILE"
    # exportArchive re-signs the app bundle; do not ad-hoc sign here.
  fi
fi

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "$IPA_PATH" ]]; then
  echo "Archive export finished, but no IPA was found in $EXPORT_DIR."
  exit 1
fi

echo "Built IPA:"
echo "  $IPA_PATH"
