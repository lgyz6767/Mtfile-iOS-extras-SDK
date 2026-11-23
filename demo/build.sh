#!/bin/bash
set -e
SDK=/home/user/theos/sdks/iPhoneOS16.5.sdk
CLANG=/home/user/theos/toolchain/linux/iphone/bin/clang
cd "$(dirname "$0")"
"$CLANG" -arch arm64 -dynamiclib -fobjc-arc -target arm64-apple-ios15.0 -Wl,-platform_version,ios,15.0,15.0 \
  -isysroot "$SDK" -framework UIKit -framework Foundation -framework CoreGraphics \
  -undefined dynamic_lookup -Os -o MTDemoExt.dylib MTDemoExt.m
ls -l MTDemoExt.dylib
LDID=${LDID:-/home/user/ios-toolchain/ldid}
[ -x "$LDID" ] && "$LDID" -S MTDemoExt.dylib || true
rm -f MTDemoExt.zip MTDemoExt.mtextra
zip -q -r MTDemoExt.mtextra manifest.json MTDemoExt.dylib icon.png
ls -l MTDemoExt.mtextra
