#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"
swift build -c release "$@"
# With --arch arm64 --arch x86_64 the universal binary lands elsewhere: ask SwiftPM where.
bin_path="$(swift build -c release "$@" --show-bin-path)"
bundle="$project_dir/dist/Appothèque.app"
# Start from an empty bundle so that files removed from Resources do not linger.
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_path/Appotheque" "$bundle/Contents/MacOS/Appotheque"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
rm -rf "$bundle/Contents/Resources/Icons"
cp -R Resources/Icons "$bundle/Contents/Resources/Icons"
# English is the development language. Its table is compiled too: without it, macOS falls back to French.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$bundle/Contents/Resources"
/usr/bin/plutil -lint Resources/Info.plist
cp Resources/Info.plist "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
