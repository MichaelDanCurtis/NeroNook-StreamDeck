# NeroNook Stream Deck

Independent Stream Deck module workspace. The first implemented foundation is a bounded, read-only inventory of Elgato ProfilesV2/ProfilesV3 for a migration review. It counts device models, pages, keypad/dial controllers and action types without copying action settings, text, URLs, profile names, serial numbers, credentials, icons or executable plugins.

This is not yet an installable NeroNook module or an Elgato replacement. No device ownership, hardware output or imported-action execution is implemented. Candidate native actions are implementation targets; unknown and marketplace action identities remain visible in the report rather than being silently dropped.

## Run

```sh
swift build
swift run deck-audit "$HOME/Library/Application Support/com.elgato.StreamDeck/ProfilesV3"
bash scripts/test.sh
```

For this Mac, use `DEVELOPER_DIR=/Library/Developer/CommandLineTools` and the installed macOS 26.5 SDK. A read-only audit must not stop Elgato, open its devices or change profile files.

## Next

1. Choose full replacement or Elgato-backed compatibility. The official SDK cannot access arbitrary user-created profiles. A companion alone cannot meet full-editor parity.
2. Add plugin-owned profiles, pages, folders, undo and explicit import review, plus a native 16:9 key/dial interface and standalone editor. Reuse the generic NookPluginSDK without a host-source build dependency.
3. Add direct Stream Deck Plus input/output behind explicit device ownership, or a supported Elgato bridge. Verify key images, touch strip, dial turns/presses and disconnect recovery.
4. Add actions incrementally: app/URL opening, text, hotkeys, media, Shortcuts, multi-actions, app profiles. Review unsupported imported actions and third-party plugin compatibility separately.

## References

- [Elgato profile limitations](https://docs.elgato.com/streamdeck/sdk/guides/profiles/)
- [Elgato profile capabilities](https://docs.elgato.com/stream-deck/profiles/getting-started/)
- [Direct hardware library candidate](https://github.com/abcminiuser/python-elgato-streamdeck)

No upstream implementation or Elgato artwork has been copied into this foundation.
