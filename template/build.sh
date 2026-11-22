#!/bin/bash
set -e
SDK=/home/user/theos/sdks/iPhoneOS16.5.sdk
CLANG=/home/user/theos/toolchain/linux/iphone/bin/clang
cd "$(dirname "$0")"
"$CLANG" -arch arm64 -dynamiclib -fobjc-arc -target arm64-apple-ios15.0 -Wl,-platform_version,ios,15.0,15.0 \
  -isysroot "$SDK" -framework UIKit -framework Foundation -framework CoreGraphics \
  -undefined dynamic_lookup -Os -o MTExtTemplate.dylib MTExtTemplate.m
ls -l MTExtTemplate.dylib
LDID=${LDID:-/home/user/ios-toolchain/ldid}
[ -x "$LDID" ] && "$LDID" -S MTExtTemplate.dylib || true
rm -f MTExtTemplate.zip
zip -q -r MTExtTemplate.zip manifest.json MTExtTemplate.dylib
ls -l MTExtTemplate.zip
