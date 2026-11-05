#!/usr/bin/env bash
# One-time setup of the iOS cross toolchain on Linux/WSL (x86_64):
#  - clang + ld64 from the Theos Linux toolchain (L1ghtmann/llvm-project)
#  - iPhoneOS 10.3 SDK (last with armv7) and 9.3 SDK (its libobjc stub fills gaps)
# ldid comes from your distro/Procursus, or set LDID=/path/to/ldid for build.sh.
set -euo pipefail
DEST="${IBOX_TC_ROOT:-$HOME/ibox-tc}"
mkdir -p "$DEST" && cd "$DEST"

if [ ! -x toolchain/linux/iphone/bin/clang ]; then
    curl -fsSL -o tc.tar.xz https://github.com/L1ghtmann/llvm-project/releases/download/main-ca1f250/iOSToolchain-x86_64.tar.xz
    mkdir -p toolchain && tar -xJf tc.tar.xz -C toolchain && rm tc.tar.xz
fi
if [ ! -d sdks/iPhoneOS10.3.sdk ]; then
    rm -rf sdks
    git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks sdks
    (cd sdks && git sparse-checkout set iPhoneOS9.3.sdk iPhoneOS10.3.sdk)
fi
echo "Toolchain ready in $DEST"
