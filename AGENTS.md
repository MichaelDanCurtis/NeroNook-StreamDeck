# Stream Deck module

Build independently of NeroNook and other plugins. Keep device I/O, profile data, imports, actions, permissions and configuration here. Use the versioned generic NookPluginSDK only when adding host presentation. The host must remain usable with no plugins.

Current milestone: independent NeroNook module plus Elgato companion using the generic actions-v1 SDK. Elgato retains hardware/profile ownership; full replacement is a separate future app. Preserve the read-only profile inventory. Never overwrite Elgato profiles, import credentials into reports, invoke imported actions, claim working plugin compatibility from parsing, or seize hardware while the existing owner is active. Profile names, user text, URLs and action settings do not belong in the aggregate audit report.

Use original UI assets. Reused open-source adapters require pinned provenance and license notices. Do not redistribute installed Elgato or marketplace binaries/artwork. Run scripts/test.sh, package and scripts/test-bridge.py, plus an explicit read-only audit before recording acceptance. Bridge fixtures must use a unique --bridge-fixture UUID so they never attach to a live installation. Hardware output and button/dial execution are separate gates.
