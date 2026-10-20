**October 19 · local 0.3.4:** Nearly Nothing refinement: softer shared glass and controls, compact fit review and paired Light/Dark. Local package installed; visual checks do not imply fresh audio, device or network acceptance. [Evidence and limits](../NeroNook/reports/nearly-nothing-refinement-2026-10-18/README.md). No public update.

**October 18 · local 0.3.3 installed:** shared glass, paired Light/Dark, independent bundled presence/particle artwork and component motion. Saved connection/settings remain scoped to this plugin. Matching Elgato companion updated locally; device inventory and existing dial assignment reappear. No profile edits or physical execution in this pass. [Rollout evidence and limits](../NeroNook/reports/redesign-ember-2026-10-18/README.md). No public release.

# NeroNook Stream Deck

Independent Stream Deck Module 0.3.2 and an Elgato companion plugin. NeroNook remains usable with zero plugins. This package builds with a vendored generic NookPluginSDK; no host checkout or other module is required.

Elgato owns the device, profiles and existing plugins. This integration connects Elgato keys to permitted NeroNook actions and live status through the shared `actions-v1` contract. It does not replace Elgato or edit arbitrary user-created profiles.

## Dials and menus — local 0.3.2

Physical-style selection now closes the action menu; browsing feedback remains
selected across refreshes. Extended signed dial/touch/key-menu fixtures pass,
and the installed menu completes its local connection check. Compact Nook key
labels remain visible. The original three keys are retained; a Menu key is added
in the unused bottom-right position. Dial dragging subsequently failed for the
owner too. A separate, original **NeroNook Dials** profile is now imported through
Elgato, with a real first-dial assignment and live Nook feedback; the original
profile remains saved. The owner confirms the physical first-dial press opens
the Nook menu, turning moves the selection, and pressing invokes it. Live receipts
show the saved workflow was selected; its Prepare review was declined before
execution. The separate native-menu connection check succeeds. Touch remains
unverified.
[Assignment follow-up](reports/dial-assignment-2026-10-17/README.md).
[Evidence and limits](reports/dials-menus-2026-10-17/README.md).

## Device and key recovery — local 0.3.1

Stream Deck+ and all three existing Nero assignments are visible again in the
redesigned Nook studio. Native transport callbacks now apply frames in arrival
order, and **Refresh deck** requests read-only device/key inventory and Elgato
settings readback. Refresh is disabled while editing a mapping. Keys retain equal
grid cells when progress feedback grows. The module and matching 0.3.1.0 Elgato
companion are signed and installed locally; previous versions are retained.

Live checks cover the picker, Elgato-confirmed same-value save, workflow review
and Stop before execution, the expanded studio and simplified setup. Repeated
restart fixtures verify device and key recovery without action replay. The one
previously approved workflow permission was renewed for the updated package;
no additional action scope was granted. The owner's physical follow-up exposed
stale permissions inside that workflow as well: its three existing Fuego grants
are now renewed. The owner confirms physical Stop, and matching native receipts
show the workflow and pending Prepare step cancelled before execution. Acceptance
and exact limits
are tracked in the [current evidence](reports/device-recovery-2026-10-17/README.md).
No public release, catalog, website or download update.

## Workflow keys — 0.3.0

Run Action can launch a permitted saved Fuego workflow. A paired **Stop Run**
key targets that companion's exact original request and waits for confirmation.
Both keys show review, completed steps, elapsed time and confirmed outcomes.
Page changes preserve the run; repeated presses and reconnect never replay it.
Native live Ember completion and confirmed Stop pass through the actual Elgato
companion. **7 module tests**, profile fixtures and isolated signed bridge checks
pass. The owner confirmed the physical Run key opens review and the paired Stop
key dismisses that review; physical Stop during remote execution remains pending.
[Setup](docs/WORKFLOW-KEYS.md) · [evidence](reports/workflow-keys-2026-10-14/README.md).

## Deck studio

Select a Nero key in the live device grid to edit its permitted action or status field. The searchable picker uses the shared SDK catalog; action inputs get typed controls. Save updates only that Nero action instance through Elgato setSettings, then waits for settings readback. Run saved is explicit and blocked while the form has unsaved edits. Device-changing actions retain the host's normal review. Keys owned by other publishers are shown as unavailable placeholders; no imported action settings or artwork are copied.

Action Menu works on a key or encoder. Press to reveal the module and its zero-input action list. Rotate a dial to choose, then press to run; touch uses the same deliberate trigger. Only the currently permitted definition may execute, and rotation itself never runs an action. Host 0.23.0 presentation-v1 reveals this plugin's own visible workspace; older hosts use the standalone window. The menu is an action picker, not arbitrary user-profile switching. Required-parameter actions use a configured Run Action key. Setup lives behind the gear rather than a Connection tab.

Live acceptance: installed 0.2.0 recognizes Stream Deck+ and the two existing Nero assignments. The native studio, searchable picker, same-value Elgato-confirmed save and read-only connection execution were checked. Bridge fixtures additionally verify dials, menu presentation, stale revision rejection and no replay. Physical menu/key/dial input is still pending the owner's manual placement/test. No other profile or original key was replaced. Bundled layouts, direct value-adjusting dial mappings, broader hardware acceptance remains a subsequent slice. Workflow feedback is delivered in 0.3.0 above.

## Build and install

```sh
swift build
bash scripts/package.sh
```

Requires macOS 14+ and NeroNook 0.12.0+ for SDK routing. The companion targets Elgato 6.6+ (recognized locally in 7.4.2). Packaging creates `build/Stream Deck Module.app` and `build/cafe.nero.neronook.sdPlugin`. Use `NERONOOK_SIGNING_IDENTITY` for an available development identity; signatures are verified, not notarized.

1. Install the app package using NeroNook Settings → Modules → Install or Update Plugin.
2. Install the companion folder in `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`, then restart Elgato. Preserve any previous companion for recovery when updating; never replace other plugins or profiles.
3. In Elgato, assign NeroNook → Run Action, Stop Run, Show Status or Action Menu to an empty key. Use a separate empty page for testing.
4. The default Run Action is a read-only connection check. The default Show Status displays the current connection. The property inspector lists permitted exports; choose a mapping, save it and use Test mapping to check its result.
5. Grant individual cross-plugin actions/state in NeroNook Settings → Modules → Actions and connections. Package updates invalidate those grants. Device/local-changing actions still require exact-run review in NeroNook.

The module has the shared 16:9 dashboard, its own status line and configuration window. Status expires when stale; reconnect never replays a previous action. Settings and Elgato context identifiers remain plugin-side.

## Architecture

`StreamDeckPlugin` runs in two modes: a native module hosted by NeroNook, and a console companion launched by Elgato with its documented WebSocket arguments. A same-user private Unix socket links those two independent ends. Folder mode 0700, socket mode 0600, peer UID validation and a file lock restrict access and prevent competing bridge instances. No TCP listener or browser endpoint is added. Native code running as the same user is trusted; this is not process authentication or a native-code sandbox.

The module forwards only discovery, invocation, cancellation and subscriptions to the generic SDK. The core owns typed validation, cross-plugin grants, exact-run review and bounded execution history. All Elgato protocol handling and local connection code lives here. Other integrations can use the same SDK without installing Stream Deck.

## Verification

```sh
bash scripts/test.sh
python3 scripts/test-bridge.py
swift test
swift run deck-audit "$HOME/Library/Application Support/com.elgato.StreamDeck/ProfilesV3"
```

Package before running the bridge fixture. Fixtures use a unique UUID socket namespace, a fake local Elgato WebSocket and a fake core peer; they do not contact a running installation or physical device. They cover registration, catalog, inspector invocation, result feedback, subscribed status and expiry, single-client ownership, disconnect, stale socket recovery and no replay after restart.

The bounded read-only profile audit remains available. It counts controllers/pages/action types without copying names, settings, text, URLs, credentials, serials, artwork or executable plugins. Existing fixtures cover malformed pages, bounds, null encoder actions, atomic rejection, unknown action identities and symlinks. The live profile audit passes; an empty test page was added through Elgato for manual acceptance.

Installed native acceptance: Elgato 7.4.2 recognizes Run Action and Show Status; the installed module connects to the actual companion. Its read-only core check returns “Core and Elgato plugin connected” and NeroNook records Completed. The standard module dashboard was visually inspected. This earlier baseline predates the 0.2.0 studio checks above. Physical key/dial input remains pending manual assignment; the computer-control tool could not perform the custom grid drag. No original key assignment was replaced.

## Remaining scope

Additional action providers, bundled Nero layouts, value-adjusting dial mappings, public distribution and broader device acceptance are later slices. Workflow feedback is delivered above. Multi-action support is disabled until asynchronous completion semantics are defined. No imported marketplace action is executed; no HID ownership is taken. A full Stream Deck replacement would be a separate application.

Current builds use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and the available Apple Development identity. The SDK snapshot is independently vendored and recorded in SDK-SNAPSHOT.json.

References: [Elgato native WebSocket interface](https://docs.elgato.com/streamdeck/sdk/references/websocket/plugin/), [manifest](https://docs.elgato.com/streamdeck/sdk/references/manifest/), [profile restrictions](https://docs.elgato.com/streamdeck/sdk/guides/profiles/). All companion source and icons are originally authored. No installed vendor or marketplace binaries/assets are redistributed.
