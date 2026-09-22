#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${NERONOOK_SDK_PATH:-$(xcrun --show-sdk-path)}"
mkdir -p build
swiftc -sdk "$sdk" Sources/DeckCore/ProfileInventory.swift Tests/Acceptance.swift -o build/deck-acceptance
build/deck-acceptance
