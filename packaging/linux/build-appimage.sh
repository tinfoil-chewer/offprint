#!/usr/bin/env bash
# Packages the Flutter Linux release bundle as an AppImage.
#   cd app && flutter build linux --release && ../packaging/linux/build-appimage.sh
# Output: dist/Offprint-<version>-x86_64.AppImage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/packaging/linux"
ID="io.github.tinfoilchewer.offprint"
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
VERSION="${VERSION:-$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/app/pubspec.yaml")}"
APPDIR="$HERE/AppDir"
TOOL="${APPIMAGETOOL:-$ROOT/tools/appimagetool-x86_64.AppImage}"

[ -x "$BUNDLE/offprint" ] || { echo "Build first: (cd app && flutter build linux --release)" >&2; exit 1; }

if [ ! -x "$TOOL" ]; then
  echo "Downloading appimagetool…"
  curl -fsSL -o "$TOOL" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOL"
fi

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"
cp "$HERE/$ID.desktop" "$APPDIR/$ID.desktop"
cp "$HERE/$ID.desktop" "$APPDIR/usr/share/applications/"
cp "$HERE/$ID.png" "$APPDIR/$ID.png"
cp "$HERE/$ID.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/offprint" "$@"
RUN
chmod +x "$APPDIR/AppRun"

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/Offprint-$VERSION-x86_64.AppImage"
ARCH=x86_64 "$TOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUT"
echo "Built $OUT"
