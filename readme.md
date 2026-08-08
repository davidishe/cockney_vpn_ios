# Cockney VPN iOS client

Fork of [Godwit](https://github.com/plumbicon/godwit) with Cockney subscription JSON support
(JWT + profile), `access_token` in CLIENT_HELLO via gomobile, Packet Tunnel, and remote diagnostic logs.

## Requirements

- macOS 13+, Xcode with iOS SDK, Go, `gomobile`, `xcodegen` (for regenerating the Xcode project)
- External olcRTC checkout with Cockney mobile JWT / vkcalls fixes
- Sideloadly for unsigned local-SOCKS IPA, **or** paid Apple Developer team for Packet Tunnel / TestFlight

Bundle IDs: `space.tokenova.cockney.ios` + `space.tokenova.cockney.ios.PacketTunnel`  
App Group: `group.space.tokenova.cockney.ios`

## Build unsigned local-SOCKS IPA

```bash
export OLCRTC_REPO_ROOT=/path/to/olcrtc
cd cockney_vpn_ios
./apple/Scripts/build-ios-unsigned-local-ipa.sh --olcrtc-root "$OLCRTC_REPO_ROOT"
```

Output: `apple/.build/ios-unsigned-local/Godwit-unsigned-local.ipa` (app display name: **Cockney**).

Install via Sideloadly → Trust developer profile → Developer Mode → paste **subscription URL** from the bot → Start → Happ SOCKS `127.0.0.1:18080`.

## Build signed IPA (Packet Tunnel / TestFlight)

1. Register App IDs + Network Extension (packet-tunnel) + App Group in Apple Developer.
2. Put Team ID in `CockneyVPN/secrets/apple_development_team` or export `DEVELOPMENT_TEAM=…`.
3. Build:

```bash
export OLCRTC_REPO_ROOT=/path/to/olcrtc
./apple/Scripts/build-ios-ipa.sh --olcrtc-root "$OLCRTC_REPO_ROOT"            # development
./apple/Scripts/build-ios-testflight.sh --olcrtc-root "$OLCRTC_REPO_ROOT"     # app-store IPA
```

Upload the app-store IPA with Transporter / `xcrun altool`. On device enable **VPN** toggle — Safari works without Happ.

## Diagnostics

- In-app **Журнал** (copy/share) with `checkpoint:` lines.
- **Журнал → На сервер** uploads redacted batches to  
  `POST /api/olcrtc/diagnostics/logs` (Bearer subscription JWT), then clears the local journal.
- Ops pull: see `cockney_vpn_backend/Docs/OlcRtc/CLIENT.md`.
