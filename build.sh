#!/usr/bin/env bash
# Builds iBox.app and an installable .deb for iPhone 4 / iOS 6 (armv7).
# Runs on Linux or WSL with the Theos Linux toolchain (clang + ld64) and an
# armv7-capable SDK (iPhoneOS10.3.sdk). See README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TC="${IBOX_TC:-$HOME/ibox-tc/toolchain/linux/iphone/bin}"
SDK="${IBOX_SDK:-$HOME/ibox-tc/sdks/iPhoneOS10.3.sdk}"
LDID="${LDID:-$(command -v ldid || echo "$HOME/tools/bin/ldid")}"
WORK="${IBOX_BUILD:-$HOME/ibox-build}"
DIST="$ROOT/dist"
VERSION="1.0-$(date +%Y%m%d%H%M)"
BEARSSL="$ROOT/third_party/bearssl-0.6"
JOBS="$(nproc 2>/dev/null || echo 4)"

CC="$TC/clang"

# Theos' iPhoneOS10.3.sdk stubs lack the armv7-only objc_msgSend*_stret entry
# points; borrow libobjc's stub from the 9.3 SDK in a patched copy.
OLD_SDK="${IBOX_OLD_SDK:-$(dirname "$SDK")/iPhoneOS9.3.sdk}"
if ! grep -q "_objc_msgSend_stret" "$SDK/usr/lib/libobjc.A.tbd" 2>/dev/null && [ -f "$OLD_SDK/usr/lib/libobjc.A.tbd" ]; then
    PATCHED="${SDK%.sdk}-armv7.sdk"
    if [ ! -d "$PATCHED" ]; then
        echo "== patching SDK -> $PATCHED"
        cp -al "$SDK" "$PATCHED" 2>/dev/null || cp -a "$SDK" "$PATCHED"
        rm -f "$PATCHED/usr/lib/libobjc.A.tbd"
        cp "$OLD_SDK/usr/lib/libobjc.A.tbd" "$PATCHED/usr/lib/libobjc.A.tbd"
    fi
    SDK="$PATCHED"
fi
TARGET="-target armv7-apple-ios6.0 -isysroot $SDK"
export CC TARGET BEARSSL WORK

for tool in "$CC" "$TC/ld" "$LDID"; do
    [ -x "$tool" ] || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -d "$SDK" ] || { echo "missing SDK: $SDK" >&2; exit 1; }

mkdir -p "$WORK/obj/bearssl" "$WORK/obj/app" "$DIST"

# 1. BearSSL, compiled once.
if [ ! -f "$WORK/libbearssl.a" ]; then
    echo "== BearSSL"
    find "$BEARSSL/src" -name '*.c' | xargs -P "$JOBS" -I{} sh -c '
        f="{}"; o="$WORK/obj/bearssl/$(echo "${f#$BEARSSL/src/}" | tr / _).o"
        $CC $TARGET -O2 -I"$BEARSSL/inc" -I"$BEARSSL/src" -c "$f" -o "$o"'
    "$TC/llvm-ar" rcs "$WORK/libbearssl.a" "$WORK"/obj/bearssl/*.o
fi

# 2. App sources (ARC Objective-C + C).
echo "== iBox"
CFLAGS="$TARGET -O2 -Wall -Wno-unused-function -Wno-deprecated-declarations -I$ROOT/src -I$ROOT/src/net -I$BEARSSL/inc"
OBJS=()
while IFS= read -r f; do
    o="$WORK/obj/app/$(basename "${f%.*}").o"
    OBJS+=("$o")
    if [ ! -f "$o" ] || [ "$f" -nt "$o" ] || [ -n "$(find "$ROOT/src" -name '*.h' -newer "$o" -print -quit)" ]; then
        case "$f" in
            *.m) "$CC" $CFLAGS -fobjc-arc -c "$f" -o "$o" ;;
            *.c) "$CC" $CFLAGS -c "$f" -o "$o" ;;
        esac
    fi
done < <(find "$ROOT/src" \( -name '*.m' -o -name '*.c' \) -not -path '*/launcher/*' | sort)

# Linking without -fobjc-arc: iOS 6 has the ARC runtime built in, so no libarclite.
APP="$WORK/iBox.app"
rm -rf "$APP"
mkdir -p "$APP"
"$CC" $TARGET -fuse-ld="$TC/ld" -o "$APP/iBox" "${OBJS[@]}" "$WORK/libbearssl.a" -lz -lgcc_s.1 \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework ImageIO \
    -framework Security -framework CFNetwork 2>&1 | grep -v -e "built for iOS Simulator" -e "is deprecated" || true
[ -f "$APP/iBox" ] || { echo "link failed" >&2; exit 1; }

# 3. Self-signed identity for the HTTPS screen-cast page (generated once per machine).
TLS="$WORK/tls"
if [ ! -f "$TLS/server.key.der" ]; then
    mkdir -p "$TLS"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=iBox" \
        -keyout "$TLS/key.pem" -out "$TLS/crt.pem" 2>/dev/null
    openssl x509 -in "$TLS/crt.pem" -outform DER -out "$TLS/server.crt.der"
    openssl rsa -in "$TLS/key.pem" -outform DER -out "$TLS/server.key.der" 2>/dev/null
fi

# 4. Bundle.
cp "$ROOT/res/Info.plist" "$ROOT/res/remote.html" "$ROOT/res/cast.html" "$ROOT/res/ytshim.js" "$ROOT/res/msebridge.js" "$ROOT/res/cacert.pem" \
   "$ROOT"/res/Icon*.png "$ROOT"/res/Default*.png "$TLS/server.crt.der" "$TLS/server.key.der" "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
chmod 644 "$APP"/*.*  # the app runs as "mobile" and must read its (throwaway, LAN-only) TLS key
"$LDID" -S "$APP/iBox"

# 5. Launcher / watchdog helper.
"$CC" $TARGET -fuse-ld="$TC/ld" -O2 -framework CoreFoundation -o "$WORK/ibox-launch" "$ROOT/src/launcher/ibox-launch.c" \
    2>&1 | grep -v -e "built for iOS Simulator" -e "is deprecated" || true
"$LDID" -S"$ROOT/res/launcher.entitlements" "$WORK/ibox-launch"

# 6. Debian package (gzip: iOS 6's dpkg predates xz/zstd).
DEB="$WORK/deb"
rm -rf "$DEB"
mkdir -p "$DEB/DEBIAN" "$DEB/Applications" "$DEB/usr/bin" "$DEB/Library/LaunchDaemons"
cp -R "$APP" "$DEB/Applications/"
cp "$WORK/ibox-launch" "$DEB/usr/bin/"
cp "$ROOT/res/com.ibox.watchdog.plist" "$DEB/Library/LaunchDaemons/"
cat > "$DEB/DEBIAN/control" <<EOF
Package: com.ibox.tv
Name: iBox
Version: $VERSION
Architecture: iphoneos-arm
Section: Utilities
Depends: firmware (>= 6.0)
Maintainer: iBox
Author: iBox
Description: Turns an iPhone 4 + Apple AV adapter into a TV box (Jellyfin, YouTube, Spotify, radio, live TV, screen share).
EOF
cat > "$DEB/DEBIAN/postinst" <<'EOF'
#!/bin/sh
chmod 755 /usr/bin/ibox-launch
chmod 644 /Library/LaunchDaemons/com.ibox.watchdog.plist
su mobile -c /usr/bin/uicache 2>/dev/null || /usr/bin/uicache 2>/dev/null
launchctl unload /Library/LaunchDaemons/com.ibox.watchdog.plist 2>/dev/null
launchctl load /Library/LaunchDaemons/com.ibox.watchdog.plist 2>/dev/null
exit 0
EOF
cat > "$DEB/DEBIAN/prerm" <<'EOF'
#!/bin/sh
launchctl unload /Library/LaunchDaemons/com.ibox.watchdog.plist 2>/dev/null
killall iBox 2>/dev/null
exit 0
EOF
chmod 755 "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/prerm"
dpkg-deb --root-owner-group -Zgzip -b "$DEB" "$DIST/ibox.deb" >/dev/null

rm -rf "$DIST/iBox.app"
cp -R "$APP" "$DIST/"
echo "== done: $DIST/ibox.deb ($VERSION)"
