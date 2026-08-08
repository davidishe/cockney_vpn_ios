#!/usr/bin/env bash
# Archive + export App Store IPA for TestFlight (manual Transporter / altool upload).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export EXPORT_METHOD="${EXPORT_METHOD:-app-store}"
export CONFIGURATION="${CONFIGURATION:-Release}"

exec "$ROOT_DIR/apple/Scripts/build-ios-ipa.sh" "$@"
