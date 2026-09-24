#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-c release)
if [[ -n "${NERONOOK_SDK_PATH:-}" ]]; then args+=(--sdk "$NERONOOK_SDK_PATH"); fi
swift build "${args[@]}"
binary_dir="$(swift build "${args[@]}" --show-bin-path)"
signing_identity="${NERONOOK_SIGNING_IDENTITY:--}"
app_dir="$PWD/build/Stream Deck Module.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/StreamDeckPlugin" "$app_dir/Contents/MacOS/StreamDeckPlugin"
ditto Resources/Views "$app_dir/Contents/Resources/Views"
cp Resources/NookPlugin.json "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cafe.nero.plugin.streamdeck</string><key>CFBundleName</key><string>Stream Deck Module</string><key>CFBundleExecutable</key><string>StreamDeckPlugin</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.2.0</string><key>CFBundleVersion</key><string>2</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
companion="$PWD/build/cafe.nero.neronook.sdPlugin"
mkdir -p "$companion"
ditto StreamDeck/cafe.nero.neronook.sdPlugin "$companion"
cp "$binary_dir/StreamDeckPlugin" "$companion/bin/StreamDeckPlugin"
swift -sdk "${NERONOOK_SDK_PATH:-$(xcrun --show-sdk-path)}" scripts/make-icons.swift "$companion/images"
codesign --force --sign "$signing_identity" "$companion/bin/StreamDeckPlugin"
codesign --verify --strict "$companion/bin/StreamDeckPlugin"
printf 'Built independent module and Elgato companion in %s/build\n' "$PWD"
