#!/bin/bash
set -e
cd "$(dirname "$0")"
rm -rf build
APP=build/PhoneLink.app
mkdir -p $APP/Contents/MacOS build/dmg
clang -fobjc-arc -arch x86_64 -arch arm64 -mmacosx-version-min=10.13 \
  -Wno-deprecated-declarations -framework Cocoa PhoneLink.m -o $APP/Contents/MacOS/PhoneLink
cp Info.plist $APP/Contents/Info.plist
codesign --force --deep -s - $APP
cp -R $APP build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname PhoneLink -srcfolder build/dmg -ov -format UDZO build/PhoneLink.dmg
