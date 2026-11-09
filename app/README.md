# Offprint app (Flutter)

Linux, Windows and Android from one codebase. See the [main README](../README.md) for features.

```bash
flutter pub get
flutter test                    # protocol byte-compatibility, renderer, QR tests
flutter run -d linux            # or windows / an Android device
```

## Code map

- `lib/core/cpnp.dart`: Canon CPNP network protocol (discovery, status, session, spool, data pull)
- `lib/core/ipp.dart`: minimal IPP client (USB via ipp-usb, or network)
- `lib/core/render.dart`: one painter for the on-screen preview and the 300 dpi print image; overcoat mask packing
- `lib/core/direct_wifi.dart`: printer pairing QR codes and Android direct Wi-Fi join
- `lib/core/printer_service.dart`: connection settings, status, print pipeline, local history
- `lib/ui/`: home, editor (layout / photo / finish / text & QR), printer settings, print progress, QR scanner
- `android/app/src/main/kotlin/.../MainActivity.kt`: joins the printer's own Wi-Fi network (Android 10+)

Protocol details: [../docs/PROTOCOL.md](../docs/PROTOCOL.md).

## Icons

`python3 tools/icon/make_icons.py` (from the repository root) regenerates every platform icon.

## Android signing

Release APKs are signed with Flutter's debug key unless you configure your own. Debug-signed builds from
different machines can't update each other; uninstall first when switching.
