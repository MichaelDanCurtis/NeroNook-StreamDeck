import XCTest
import Foundation
@testable import StreamDeckPlugin
import NookPluginSDK
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class RecoveryLedgerTests: XCTestCase {
    private typealias Ledger = DeckRecoveryLedger
    private enum Injected: Error { case stopped }
    private func root() throws -> URL {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("nero-deck-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock {
            if let path = ProcessInfo.processInfo.environment["NERO_DECK_RECOVERY_EVIDENCE"] {
                let destination = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: parent, to: destination.appendingPathComponent(parent.lastPathComponent))
            }
            try FileManager.default.removeItem(at: parent)
        }
        return parent.appendingPathComponent("recovery-data")
    }
    private func slot(_ context: String = "authored-context") -> Ledger.Slot {
        .init(context: context, action: "cafe.nero.neronook.run", device: "authored-device", controller: "Keypad", row: 0, column: 0, revision: "authored-revision")
    }
    private func settings(_ name: String) throws -> Data {
        try DeckRebindingJSON.canonical(["provider": "local.neronook.automations", "name": name,
            "unknown": ["nested": [1.25, NSNull(), true], "label": "authored café 🌿"]])
    }
    private func intent(_ id: UUID = UUID(), kind: Ledger.SettingsKind = .save, parent: UUID? = nil, before: Data? = nil, after: Data? = nil) throws -> Ledger.SettingsIntent {
        let beforeData: Data, afterData: Data
        if let before { beforeData = before } else { beforeData = try settings("before") }
        if let after { afterData = after } else { afterData = try settings("after") }
        return .init(id: id, requestID: UUID(), kind: kind, slot: slot(), oldAddress: .init("local.neronook.automations", kind == .undo ? "after" : "before"), newAddress: .init("local.neronook.automations", kind == .undo ? "before" : "after"),
            beforeData: beforeData, afterData: afterData, parentID: parent)
    }
    private func runIntent(_ id: UUID = UUID()) -> Ledger.RunIntent { .init(id: id, slot: slot(), address: .init("local.neronook.automations", "authored"), descriptorSHA256: String(repeating: "a", count: 64)) }
    private func failure<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Expected failure", file: file, line: line) } catch {}
    }
    private func bytes(_ root: URL) throws -> Data { try Data(contentsOf: root.appendingPathComponent(Ledger.filename)) }
    private func replace(_ data: Data, root: URL) throws {
        let url = root.appendingPathComponent(Ledger.filename); try data.write(to: url, options: .atomic); XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    func testActualPrivateModesSingleOwnerAndColdRoundTripPreserveCompleteSettings() async throws {
        let directory = try root(), ledger = try await Ledger.open(directory: directory), value = try intent()
        let row = try await ledger.prepareSettings(value)
        let live = try await ledger.listRecords()
        XCTAssertEqual(row.sessionID, live.sessionID); XCTAssertTrue(row.unresolved)
        var info = stat(); XCTAssertEqual(lstat(directory.path, &info), 0); XCTAssertEqual(info.st_mode & 0o7777, 0o700)
        for leaf in [Ledger.filename, Ledger.lockFilename] {
            XCTAssertEqual(lstat(directory.appendingPathComponent(leaf).path, &info), 0); XCTAssertEqual(info.st_mode & 0o7777, 0o600); XCTAssertEqual(info.st_nlink, 1)
        }
        await failure { try await Ledger.open(directory: directory) }
        let raw = try bytes(directory)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("authored café"))
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains(value.beforeData.base64EncodedString()))
        await ledger.close()
        let cold = try await Ledger.open(directory: directory), snapshot = try await cold.listRecords()
        XCTAssertNotEqual(snapshot.sessionID, live.sessionID)
        XCTAssertEqual(snapshot.settings[0].beforeData, value.beforeData); XCTAssertEqual(snapshot.settings[0].afterData, value.afterData)
        XCTAssertEqual(snapshot.settings[0].state, .intent); XCTAssertTrue(snapshot.settings[0].unresolved)
        XCTAssertEqual(try bytes(directory), raw)
        await cold.close()
    }
    func testExplicitPhysicalPathOpensExistingAndNewDirectoryWithoutCanonicalSpellingAssumption() async throws {
        for alreadyExists in [true, false] {
            let directory = try root(), physicalPath = directory.path
            if alreadyExists { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let ledger = try await Ledger.open(directory: directory), value = try intent(), row = try await ledger.prepareSettings(value)
            await ledger.close()
            XCTAssertEqual(directory.path, physicalPath)
            let reopened = try await Ledger.open(directory: URL(fileURLWithPath: physicalPath)), snapshot = try await reopened.listRecords()
            XCTAssertEqual(snapshot.settings.first?.id, row.id); XCTAssertEqual(snapshot.settings.first?.beforeData, value.beforeData)
            XCTAssertTrue(snapshot.settings.first?.unresolved == true)
            await reopened.close()
        }
    }
    func testDotDotdotEmptyNULQueryAndFragmentPathsRefuseWithoutCreatingLeaf() async throws {
        let parent = try root().deletingLastPathComponent(), prefix = parent.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let paths = [parent.path + "/./dot-target", parent.path + "/prefix/../dotdot-target", parent.path + "//empty-target"]
        for path in paths {
            let url = try XCTUnwrap(URL(string: "file://" + path))
            await failure { try await Ledger.open(directory: url) }
        }
        for suffix in ["/query-target?authored=1", "/fragment-target#authored", "/%00nul-target"] {
            let url = try XCTUnwrap(URL(string: "file://" + parent.path + suffix))
            await failure { try await Ledger.open(directory: url) }
        }
        for leaf in ["dot-target", "dotdot-target", "empty-target", "query-target", "fragment-target", "nul-target"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(leaf).path))
        }
    }

    func testBeforeIntentAndOutcomeMustBeDurableAndExpectedRevisionMatches() async throws {
        let directory = try root(), ledger = try await Ledger.open(directory: directory), value = try intent()
        let row = try await ledger.prepareSettings(value)
        let committed = try bytes(directory)
        await failure { try await ledger.finishSettings(id: row.id, expectedRevision: 1, outcome: .confirmed(observedData: value.afterData)) }
        await failure { try await ledger.finishSettings(id: row.id, expectedRevision: 0, outcome: .confirmed(observedData: value.beforeData)) }
        XCTAssertEqual(try bytes(directory), committed)
        let finished = try await ledger.finishSettings(id: row.id, expectedRevision: 0, outcome: .confirmed(observedData: value.afterData))
        XCTAssertEqual(finished.state, .confirmed); XCTAssertFalse(finished.unresolved); XCTAssertEqual(finished.observedData, value.afterData)
        await ledger.close()
        let reopened = try await Ledger.open(directory: directory), state = try await reopened.listRecords()
        XCTAssertEqual(state.settings[0].revision, 1); XCTAssertEqual(state.settings[0].state, .confirmed)
        await reopened.close()
    }
    func testConflictPreservesActualObservedDataAndUncertainKeepsBarrier() async throws {
        let ledger = try await Ledger.open(directory: root()), first = try await ledger.prepareSettings(intent()), observed = try settings("manual-later-edit")
        let conflict = try await ledger.finishSettings(id: first.id, expectedRevision: 0, outcome: .conflict(observedData: observed))
        XCTAssertEqual(conflict.observedData, observed); XCTAssertFalse(conflict.unresolved)
        let second = try await ledger.prepareSettings(intent())
        let uncertain = try await ledger.finishSettings(id: second.id, expectedRevision: 0, outcome: .uncertain)
        XCTAssertTrue(uncertain.unresolved); XCTAssertEqual(uncertain.state, .uncertain)
        await ledger.close()
    }
    func testColdSettingsRequireExplicitVisibleObservationAndCannotUseWarmNotSent() async throws {
        let directory = try root(), warm = try await Ledger.open(directory: directory), value = try intent(), row = try await warm.prepareSettings(value)
        await warm.close()
        let cold = try await Ledger.open(directory: directory)
        await failure { try await cold.finishSettings(id: row.id, expectedRevision: 0, outcome: .notSent) }
        await failure { try await cold.finishSettings(id: row.id, expectedRevision: 0, outcome: .confirmed(observedData: value.afterData)) }
        let observed = try settings("current-visible-manual-edit"), chosen = slot("explicitly-reassociated-visible-key")
        let result = try await cold.reconcileSettings(id: row.id, expectedRevision: 0, observedData: observed, selectedSlot: chosen)
        XCTAssertEqual(result.state, .reconciledDifferent); XCTAssertEqual(result.reassociatedSlot, chosen)
        XCTAssertEqual(result.slot, value.slot); XCTAssertEqual(result.beforeData, value.beforeData); XCTAssertEqual(result.afterData, value.afterData)
        XCTAssertEqual(result.observedData, observed); XCTAssertFalse(result.unresolved)
        await cold.close()
    }
    func testRunAndCancelIntentRetainOriginalRequestAndCannotBeSettledAfterColdOpen() async throws {
        let directory = try root(), ledger = try await Ledger.open(directory: directory), value = runIntent()
        let running = try await ledger.prepareRun(value), cancelID = UUID()
        let cancelling = try await ledger.prepareCancel(runID: running.id, expectedRevision: 0, cancelID: cancelID)
        XCTAssertEqual(cancelling.id, value.id); XCTAssertEqual(cancelling.cancelIDs, [cancelID]); XCTAssertTrue(cancelling.cancelUncertain)
        await ledger.close()
        let cold = try await Ledger.open(directory: directory), state = try await cold.listRecords()
        XCTAssertTrue(state.runs[0].unresolved); XCTAssertEqual(state.runs[0].phase, .cancelling)
        await failure { try await cold.finishRun(id: value.id, expectedRevision: 1, phase: .cancelled) }
        await failure { try await cold.prepareCancel(runID: value.id, expectedRevision: 1, cancelID: UUID()) }
        let afterRefusal = try await cold.listRecords()
        XCTAssertEqual(afterRefusal.runs[0].cancelIDs, [cancelID])
        await cold.close()
    }
    func testLiveProviderTerminalClearsOnlyItsCurrentSessionRunWhileInterruptedStaysUnknown() async throws {
        let ledger = try await Ledger.open(directory: root()), a = try await ledger.prepareRun(runIntent())
        let interrupted = try await ledger.finishRun(id: a.id, expectedRevision: 0, phase: .interrupted)
        XCTAssertTrue(interrupted.unresolved)
        let b = try await ledger.prepareRun(runIntent()), stopped = try await ledger.prepareCancel(runID: b.id, expectedRevision: 0, cancelID: UUID())
        let terminal = try await ledger.finishRun(id: b.id, expectedRevision: stopped.revision, phase: .cancelled)
        XCTAssertFalse(terminal.unresolved); XCTAssertFalse(terminal.cancelUncertain)
        let rows = try await ledger.listRecords(); XCTAssertTrue(rows.runs.first { $0.id == a.id }!.unresolved)
        await ledger.close()
    }
    func testUndoIsExactParentInverseAndKeepsBothReceipts() async throws {
        let ledger = try await Ledger.open(directory: root()), original = try intent(kind: .rebind), prepared = try await ledger.prepareSettings(original)
        _ = try await ledger.finishSettings(id: prepared.id, expectedRevision: 0, outcome: .confirmed(observedData: original.afterData))
        await failure { try await ledger.prepareSettings(intent(kind: .undo, parent: original.id)) }
        let inverse = try intent(kind: .undo, parent: original.id, before: original.afterData, after: original.beforeData)
        let undo = try await ledger.prepareSettings(inverse)
        _ = try await ledger.finishSettings(id: undo.id, expectedRevision: 0, outcome: .confirmed(observedData: inverse.afterData))
        let state = try await ledger.listRecords(); XCTAssertEqual(state.settings.count, 2); XCTAssertEqual(state.settings[1].parentID, original.id)
        await ledger.close()
    }
    func testMalformedUnknownEscapedDuplicateAndBadBase64NeverResetLedger() async throws {
        for mode in ["unknown", "duplicate", "base64", "format"] {
            let directory = try root(), ledger = try await Ledger.open(directory: directory)
            _ = try await ledger.prepareSettings(intent()); await ledger.close()
            let original = try bytes(directory), changed: Data
            if mode == "unknown" { changed = Data("{\"unknown\":true,".utf8) + original.dropFirst() }
            else if mode == "duplicate" { changed = Data("{\"\\u0066ormat\":\"nero-streamdeck-recovery/1\",".utf8) + original.dropFirst() }
            else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
                if mode == "format" { object["format"] = "other" }
                else { var rows = try XCTUnwrap(object["settings"] as? [[String: Any]]); rows[0]["beforeData"] = "***"; object["settings"] = rows }
                changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            }
            try replace(changed, root: directory)
            await failure { try await Ledger.open(directory: directory) }
            XCTAssertEqual(try bytes(directory), changed)
        }
    }
    func testExternalSameByteReplacementAndChangedBytesInvalidateExistingOwner() async throws {
        for same in [true, false] {
            let directory = try root(), ledger = try await Ledger.open(directory: directory), original = try bytes(directory)
            let changed = same ? original : Data("authored external mutation".utf8)
            try replace(changed, root: directory)
            await failure { try await ledger.prepareSettings(intent()) }
            XCTAssertEqual(try bytes(directory), changed); await ledger.close()
        }
    }
    func testForeignModesSymlinkAndOversizedFileAreRefusedWithoutRepair() async throws {
        let parent = try root().deletingLastPathComponent(), other = parent.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = parent.appendingPathComponent("alias"); XCTAssertEqual(symlink(other.path, alias.path), 0)
        await failure { try await Ledger.open(directory: alias) }
        let directory = parent.appendingPathComponent("actual"), ledger = try await Ledger.open(directory: directory); await ledger.close()
        let file = directory.appendingPathComponent(Ledger.filename), original = try Data(contentsOf: file)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        await failure { try await Ledger.open(directory: directory) }; XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(Ledger.encodedByteLimit + 1)); try handle.close()
        await failure { try await Ledger.open(directory: directory) }
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Ledger.encodedByteLimit + 1)
    }
    func testUnwritableDirectoryAndOversizedSettingsRefuseBeforeChangingLedger() async throws {
        let directory = try root(), ledger = try await Ledger.open(directory: directory), original = try bytes(directory)
        let oversized = try DeckRebindingJSON.canonical(["x": "small"])
        let tooLarge = Data(repeating: 97, count: 131_073)
        await failure { try await ledger.prepareSettings(intent(before: oversized, after: tooLarge)) }
        XCTAssertEqual(try bytes(directory), original)
        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        await failure { try await ledger.prepareSettings(intent()) }
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        XCTAssertEqual(try bytes(directory), original); await ledger.close()
    }

    func testAllUnresolvedCapacityRefusesAndNeverEvictsUnknownSettings() async throws {
        let directory = try root(), ledger = try await Ledger.open(directory: directory)
        var ids = [UUID]()
        for _ in 0..<128 { ids.append(try await ledger.prepareSettings(intent()).id) }
        let original = try bytes(directory)
        await failure { try await ledger.prepareSettings(intent()) }
        let state = try await ledger.listRecords(); XCTAssertEqual(state.settings.map(\.id), ids); XCTAssertEqual(try bytes(directory), original)
        await ledger.close()
    }
    func testResolvedRunRetentionKeepsNewestAndNeverEvictsUnknownRun() async throws {
        let ledger = try await Ledger.open(directory: root()), unknown = try await ledger.prepareRun(runIntent())
        var resolved = [UUID]()
        for _ in 0..<127 {
            let row = try await ledger.prepareRun(runIntent()); _ = try await ledger.finishRun(id: row.id, expectedRevision: 0, phase: .succeeded); resolved.append(row.id)
        }
        let latest = try await ledger.prepareRun(runIntent()), state = try await ledger.listRecords()
        XCTAssertEqual(state.runs.count, 128); XCTAssertTrue(state.runs.contains { $0.id == unknown.id && $0.unresolved })
        XCTAssertFalse(state.runs.contains { $0.id == resolved[0] }); XCTAssertTrue(state.runs.contains { $0.id == resolved.last! }); XCTAssertTrue(state.runs.contains { $0.id == latest.id })
        XCTAssertFalse(Ledger.retentionMessage.isEmpty); await ledger.close()
    }
    func testUndoFamilyRetentionIsAtomicAndUnresolvedChildProtectsParent() async throws {
        for unresolvedChild in [true, false] {
            let ledger = try await Ledger.open(directory: root()), value = try intent(kind: .rebind), parent = try await ledger.prepareSettings(value)
            _ = try await ledger.finishSettings(id: parent.id, expectedRevision: 0, outcome: .confirmed(observedData: value.afterData))
            let inverse = try intent(kind: .undo, parent: parent.id, before: value.afterData, after: value.beforeData), child = try await ledger.prepareSettings(inverse)
            if !unresolvedChild { _ = try await ledger.finishSettings(id: child.id, expectedRevision: 0, outcome: .confirmed(observedData: inverse.afterData)) }
            var filler = [UUID]()
            for _ in 0..<126 {
                let value = try intent(), row = try await ledger.prepareSettings(value); filler.append(row.id)
                if unresolvedChild { _ = try await ledger.finishSettings(id: row.id, expectedRevision: 0, outcome: .confirmed(observedData: value.afterData)) }
            }
            let newest = try await ledger.prepareSettings(intent()), state = try await ledger.listRecords()
            XCTAssertTrue(state.settings.contains { $0.id == newest.id })
            XCTAssertEqual(state.settings.contains { $0.id == parent.id }, unresolvedChild)
            XCTAssertEqual(state.settings.contains { $0.id == child.id }, unresolvedChild)
            if !unresolvedChild { XCTAssertTrue(Set(filler).isSubset(of: Set(state.settings.map(\.id)))) }
            await ledger.close()
        }
    }
    func testFailureBeforePublishLeavesOldLedgerAndNoIntentReceipt() async throws {
        let directory = try root(), counter = RecoveryLedgerHookCounter()
        let ledger = try await Ledger.open(directory: directory, hooks: .init(beforePublish: {
            XCTAssertFalse(Thread.isMainThread); if counter.next() == 2 { throw Injected.stopped }
        }))
        let before = try bytes(directory)
        await failure { try await ledger.prepareSettings(intent()) }
        XCTAssertEqual(try bytes(directory), before)
        let unchanged = try await ledger.listRecords(); XCTAssertTrue(unchanged.settings.isEmpty)
        await ledger.close()
    }
    func testFailureAfterPublishLeavesColdIntentAndExistingOwnerUncertain() async throws {
        let directory = try root(), counter = RecoveryLedgerHookCounter(), value = try intent()
        let ledger = try await Ledger.open(directory: directory, hooks: .init(afterPublish: {
            XCTAssertFalse(Thread.isMainThread); if counter.next() == 2 { throw Injected.stopped }
        }))
        await failure { try await ledger.prepareSettings(value) }
        await failure { try await ledger.listRecords() }; await ledger.close()
        let cold = try await Ledger.open(directory: directory), state = try await cold.listRecords()
        XCTAssertEqual(state.settings.first?.id, value.id); XCTAssertTrue(state.settings.first?.unresolved == true)
        await cold.close()
    }
}
private final class RecoveryLedgerHookCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
