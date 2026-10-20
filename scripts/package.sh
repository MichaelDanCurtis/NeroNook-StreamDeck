#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-c release)
if [[ -n "${NERONOOK_SDK_PATH:-}" ]]; then args+=(--sdk "$NERONOOK_SDK_PATH"); fi
swift build "${args[@]}"
binary_dir="$(swift build "${args[@]}" --show-bin-path)"
mkdir -p build
reference_app="$PWD/build/Stream Deck Module.app"
signing_identity="$(python3 scripts/signing.py identity --bundle cafe.nero.plugin.streamdeck --reference "$reference_app")"
package_stage="$(mktemp -d "$PWD/build/.deck-package.XXXXXX")"
trap 'rm -rf "$package_stage"' EXIT
app_dir="$package_stage/Stream Deck Module.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -R "$binary_dir/NookPluginSDK_NookPluginSDK.bundle" "$app_dir/Contents/Resources/"
cp "$binary_dir/StreamDeckPlugin" "$app_dir/Contents/MacOS/StreamDeckPlugin"
ditto Resources/Views "$app_dir/Contents/Resources/Views"
cp Resources/NookPlugin.json "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cafe.nero.plugin.streamdeck</string><key>CFBundleName</key><string>Stream Deck Module</string><key>CFBundleExecutable</key><string>StreamDeckPlugin</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.3.4</string><key>CFBundleVersion</key><string>6</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
companion="$package_stage/cafe.nero.neronook.sdPlugin"
mkdir -p "$companion"
ditto StreamDeck/cafe.nero.neronook.sdPlugin "$companion"
cp "$binary_dir/StreamDeckPlugin" "$companion/bin/StreamDeckPlugin"
swift -sdk "${NERONOOK_SDK_PATH:-$(xcrun --show-sdk-path)}" scripts/make-icons.swift "$companion/images"
codesign --force --sign "$signing_identity" "$companion/bin/StreamDeckPlugin"
codesign --verify --strict "$companion/bin/StreamDeckPlugin"
python3 scripts/signing.py verify --reference "$reference_app" "$app_dir"
if [[ -e "$reference_app" ]]; then mv "$reference_app" "$PWD/build/Stream Deck Module.previous.$(date +%Y%m%d%H%M%S).app"; fi
if [[ -e "$PWD/build/cafe.nero.neronook.sdPlugin" ]]; then mv "$PWD/build/cafe.nero.neronook.sdPlugin" "$PWD/build/cafe.nero.neronook.previous.$(date +%Y%m%d%H%M%S).sdPlugin"; fi
mv "$app_dir" "$reference_app"
mv "$companion" "$PWD/build/cafe.nero.neronook.sdPlugin"
printf 'Built independent module and Elgato companion in %s/build\n' "$PWD"
