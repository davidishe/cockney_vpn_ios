# Cockney VPN iOS client

Fork of [Godwit](https://github.com/plumbicon/godwit) with Cockney subscription JSON support
(JWT + profile), `access_token` in CLIENT_HELLO via gomobile, and copyable diagnostic logs.

## Requirements

- macOS 13+, Xcode with iOS SDK, Go, `gomobile`, `xcodegen` (for regenerating the Xcode project)
- External olcRTC checkout with Cockney mobile JWT: `davidishe/olcrtc` tag/branch `cockney-v1` (`SetAccessToken`)
- Sideloadly for installing the unsigned local-SOCKS IPA

## Build unsigned local-SOCKS IPA

```bash
export OLCRTC_REPO_ROOT=/path/to/olcrtc   # davidishe/olcrtc@cockney-v1
cd cockney_vpn_ios
./apple/Scripts/build-ios-unsigned-local-ipa.sh --olcrtc-root "$OLCRTC_REPO_ROOT"
```

Output: `apple/.build/ios-unsigned-local/Godwit-unsigned-local.ipa` (app display name: **Cockney**).

Install via Sideloadly → Trust developer profile → Developer Mode → paste **subscription URL** from the bot → Start → Happ SOCKS `127.0.0.1:18080`.

Use **Журнал → Копировать / Поделиться** and look for `checkpoint:` lines when debugging.

## Note

Packet Tunnel / system VPN still needs a paid Apple Developer team and a signed build. This repo’s default path is local SOCKS only.
