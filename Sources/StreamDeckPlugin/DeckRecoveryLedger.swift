import Foundation
import CryptoKit
import NookPluginSDK
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Consumer-owned effect evidence only. No stored context is a cold key identity,
/// provider authority, a terminal query, cancellation permission or replay plan.
actor DeckRecoveryLedger {
    static let filename = "ledger-v1.json"
    static let lockFilename = ".ledger.lock"
    static let encodedByteLimit = 50_331_648
    static let rawByteLimit = 33_554_432
    static let retentionMessage = "Recovery history is bounded. Oldest fully resolved records may expire; unresolved settings, unknown runs and their Undo families are never evicted. Recent resolved history is retained where capacity permits."
    enum Problem: String, Error, Sendable, Equatable { case invalid, unavailable, busy, capacity, conflict, closed, uncertain, staleSession }
    enum SettingsKind: String, Codable, Sendable { case save, rebind, undo }
    enum SettingsState: String, Codable, Sendable { case intent, confirmed, conflict, uncertain, notSent, reconciledBefore, reconciledAfter, reconciledDifferent }
    enum SettingsOutcome: Sendable { case confirmed(observedData: Data), conflict(observedData: Data), uncertain, notSent }
    struct Slot: Codable, Sendable, Equatable {
        let context, action, device, controller: String
        let row, column: Int
        let revision: String
    }
    struct SettingsIntent: Sendable {
        let id, requestID: UUID
        let kind: SettingsKind
        let slot: Slot
        let oldAddress, newAddress: PluginActionAddress
        let beforeData, afterData: Data
        let parentID: UUID?
    }
    struct SettingsRecord: Codable, Sendable {
        let id, requestID: UUID
        let kind: SettingsKind
        let slot: Slot
        let oldAddress, newAddress: PluginActionAddress
        let beforeData, afterData: Data
        let parentID: UUID?
        let createdAt: String
        let sessionID: UUID
        var revision: UInt64
        var state: SettingsState
        var observedData: Data?
        var reassociatedSlot: Slot?
        var unresolved: Bool { state == .intent || state == .uncertain }
    }
    struct RunIntent: Sendable {
        let id: UUID
        let slot: Slot
        let address: PluginActionAddress
        let descriptorSHA256: String
    }
    struct RunRecord: Codable, Sendable {
        let id: UUID
        let slot: Slot
        let address: PluginActionAddress
        let descriptorSHA256: String
        let createdAt: String
        let sessionID: UUID
        var revision: UInt64
        var phase: PluginRunPhase
        var cancelIDs: [UUID]
        var cancelUncertain: Bool
        var unresolved: Bool { ![.succeeded, .failed, .cancelled].contains(phase) }
    }
    struct Snapshot: Sendable {
        let sessionID: UUID
        let revision: UInt64
        let settings: [SettingsRecord]
        let runs: [RunRecord]
    }
    struct Hooks: Sendable {
        var beforePublish: (@Sendable () throws -> Void)?
        var afterPublish: (@Sendable () throws -> Void)?
    }
    private let disk: DeckRecoveryLedgerDisk
    private init(_ disk: DeckRecoveryLedgerDisk) { self.disk = disk }
    static func open(directory: URL, hooks: Hooks = .init()) async throws -> DeckRecoveryLedger {
        let disk = DeckRecoveryLedgerDisk(directory: directory, hooks: hooks)
        try await disk.perform { try $0.open() }
        return .init(disk)
    }
    func listRecords() async throws -> Snapshot { try await disk.perform { try $0.list() } }
    func prepareSettings(_ intent: SettingsIntent) async throws -> SettingsRecord { try await disk.perform { try $0.prepareSettings(intent) } }
    func finishSettings(id: UUID, expectedRevision: UInt64, outcome: SettingsOutcome) async throws -> SettingsRecord {
        try await disk.perform { try $0.finishSettings(id: id, expected: expectedRevision, outcome: outcome) }
    }
    func reconcileSettings(id: UUID, expectedRevision: UInt64, observedData: Data, selectedSlot: Slot) async throws -> SettingsRecord {
        try await disk.perform { try $0.reconcile(id: id, expected: expectedRevision, data: observedData, slot: selectedSlot) }
    }
    func prepareRun(_ intent: RunIntent) async throws -> RunRecord { try await disk.perform { try $0.prepareRun(intent) } }
    func prepareCancel(runID: UUID, expectedRevision: UInt64, cancelID: UUID) async throws -> RunRecord {
        try await disk.perform { try $0.prepareCancel(id: runID, expected: expectedRevision, cancelID: cancelID) }
    }
    func finishRun(id: UUID, expectedRevision: UInt64, phase: PluginRunPhase) async throws -> RunRecord {
        try await disk.perform { try $0.finishRun(id: id, expected: expectedRevision, phase: phase) }
    }
    func close() async { _ = try? await disk.perform { $0.close() } }
}

/// One queue owns every descriptor, cached byte image and disk mutation. Actor
/// reentrancy cannot overlap filesystem commits; no callback sends an effect.
private final class DeckRecoveryLedgerDisk: @unchecked Sendable {
    typealias Ledger = DeckRecoveryLedger
    private struct State: Codable {
        let format: String
        var revision: UInt64
        var settings: [Ledger.SettingsRecord]
        var runs: [Ledger.RunRecord]
    }
    private struct DirectoryPin: Equatable {
        let device: dev_t; let inode: ino_t; let uid: uid_t; let mode: mode_t
        static func capture(_ info: stat) throws -> Self {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { throw Ledger.Problem.invalid }
            return .init(device: info.st_dev, inode: info.st_ino, uid: info.st_uid, mode: info.st_mode & 0o7777)
        }
    }
    private struct FilePin: Equatable {
        let device: dev_t; let inode: ino_t; let size: Int
        let mtimeSeconds, mtimeNanos, ctimeSeconds, ctimeNanos: Int64
        static func capture(_ info: stat, limit: Int) throws -> Self {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600,
                info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else { throw Ledger.Problem.invalid }
            #if canImport(Darwin)
            let mt = info.st_mtimespec, ct = info.st_ctimespec
            #else
            let mt = info.st_mtim, ct = info.st_ctim
            #endif
            return .init(device: info.st_dev, inode: info.st_ino, size: Int(info.st_size), mtimeSeconds: Int64(mt.tv_sec), mtimeNanos: Int64(mt.tv_nsec), ctimeSeconds: Int64(ct.tv_sec), ctimeNanos: Int64(ct.tv_nsec))
        }
    }
    private struct Image { let data: Data; let pin: FilePin }
    private let queue = DispatchQueue(label: "cafe.nero.streamdeck.recovery-ledger", qos: .utility)
    private let directory: URL
    private let hooks: Ledger.Hooks
    private let sessionID = UUID()
    private var directoryPin: DirectoryPin?
    private var directoryFD: Int32 = -1, lockFD: Int32 = -1
    private var lockPin: FilePin?
    private var image: Image?
    private var state = State(format: "nero-streamdeck-recovery/1", revision: 0, settings: [], runs: [])
    private var closed = false, uncertain = false
    private var timestampFormatter: ISO8601DateFormatter?
    init(directory: URL, hooks: Ledger.Hooks) { self.directory = directory; self.hooks = hooks }
    deinit { if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); _ = DarwinOrGlibcClose(lockFD) }; if directoryFD >= 0 { _ = DarwinOrGlibcClose(directoryFD) } }
    func perform<T: Sendable>(_ body: @escaping @Sendable (DeckRecoveryLedgerDisk) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { guard !Thread.isMainThread else { throw Ledger.Problem.invalid }; continuation.resume(returning: try body(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func open() throws {
        let path = directory.path, components = path.split(separator: "/", omittingEmptySubsequences: false)
        // Pure lexical admission cannot depend on whether this leaf already
        // exists. Foundation standardization rewrites physical /private/var
        // paths after creation on macOS; the actual nofollow FD pins below,
        // not a canonical-path spelling assumption, establish currentness.
        guard !closed, directoryFD < 0, directory.isFileURL, directory.query == nil, directory.fragment == nil,
            let decodedURL = directory.absoluteString.removingPercentEncoding, !decodedURL.utf8.contains(0),
            path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0), components.count > 1,
            components.first == "", components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Ledger.Problem.invalid }
        let parent = directory.deletingLastPathComponent(), parentFD = DarwinOrGlibcOpen(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw Ledger.Problem.unavailable }; defer { _ = DarwinOrGlibcClose(parentFD) }
        var p = stat(); guard fstat(parentFD, &p) == 0, p.st_mode & S_IFMT == S_IFDIR, p.st_uid == getuid(), p.st_mode & 0o022 == 0 else { throw Ledger.Problem.invalid }
        var info = stat()
        if fstatat(parentFD, directory.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, mkdirat(parentFD, directory.lastPathComponent, 0o700) == 0, fsync(parentFD) == 0 else { throw Ledger.Problem.unavailable }
        }
        directoryFD = openat(parentFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0, fstat(directoryFD, &info) == 0 else { throw Ledger.Problem.invalid }
        directoryPin = try DirectoryPin.capture(info); try validateDirectory()
        let existingLock = try named(Ledger.lockFilename, limit: 0)
        if existingLock == nil {
            guard try named(Ledger.filename, limit: Ledger.encodedByteLimit) == nil else { throw Ledger.Problem.invalid }
            let created = openat(directoryFD, Ledger.lockFilename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard created >= 0 else { throw Ledger.Problem.conflict }
            let synced = fsync(created); _ = DarwinOrGlibcClose(created)
            guard synced == 0, fsync(directoryFD) == 0 else { throw Ledger.Problem.uncertain }
        }
        lockFD = openat(directoryFD, Ledger.lockFilename, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard lockFD >= 0, fstat(lockFD, &info) == 0 else { throw Ledger.Problem.invalid }
        lockPin = try FilePin.capture(info, limit: 0)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Ledger.Problem.busy }
        try validateOwner()
        if let saved = try readLedger() {
            try DeckLedgerJSONPreflight.validate(saved.data)
            let parsed = try JSONDecoder().decode(State.self, from: saved.data)
            try validate(parsed)
            guard try encode(parsed) == saved.data else { throw Ledger.Problem.invalid }
            state = parsed; image = saved
        } else {
            guard try tempNames().isEmpty else { throw Ledger.Problem.conflict }
            try persist(state)
        }
        try validateCurrent()
    }
    func close() {
        guard !closed else { return }; closed = true
        if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); _ = DarwinOrGlibcClose(lockFD); lockFD = -1 }
        if directoryFD >= 0 { _ = DarwinOrGlibcClose(directoryFD); directoryFD = -1 }
    }
    func list() throws -> Ledger.Snapshot { try validateCurrent(); return .init(sessionID: sessionID, revision: state.revision, settings: state.settings, runs: state.runs) }
    func prepareSettings(_ intent: Ledger.SettingsIntent) throws -> Ledger.SettingsRecord {
        try validateCurrent(); try validateSlot(intent.slot); try intent.oldAddress.validate(); try intent.newAddress.validate()
        try canonicalSettings(intent.beforeData); try canonicalSettings(intent.afterData)
        guard !state.settings.contains(where: { $0.id == intent.id }), !state.runs.contains(where: { $0.id == intent.id }) else { throw Ledger.Problem.conflict }
        if intent.kind == .undo {
            guard let parent = intent.parentID, let original = state.settings.first(where: { $0.id == parent }), !original.unresolved,
                original.state == .confirmed || original.state == .reconciledAfter,
                intent.beforeData == original.afterData, intent.afterData == original.beforeData,
                intent.oldAddress == original.newAddress, intent.newAddress == original.oldAddress else { throw Ledger.Problem.conflict }
        } else { guard intent.parentID == nil else { throw Ledger.Problem.invalid } }
        let record = Ledger.SettingsRecord(id: intent.id, requestID: intent.requestID, kind: intent.kind, slot: intent.slot, oldAddress: intent.oldAddress, newAddress: intent.newAddress,
            beforeData: intent.beforeData, afterData: intent.afterData, parentID: intent.parentID, createdAt: timestamp(), sessionID: sessionID,
            revision: 0, state: .intent, observedData: nil, reassociatedSlot: nil)
        var next = state; next.settings.append(record); try commit(next); return record
    }
    func finishSettings(id: UUID, expected: UInt64, outcome: Ledger.SettingsOutcome) throws -> Ledger.SettingsRecord {
        try validateCurrent()
        guard let i = state.settings.firstIndex(where: { $0.id == id }) else { throw Ledger.Problem.conflict }
        var record = state.settings[i]
        guard record.sessionID == sessionID else { throw Ledger.Problem.staleSession }
        guard record.revision == expected, record.unresolved else { throw Ledger.Problem.conflict }
        switch outcome {
        case .confirmed(let data):
            try canonicalSettings(data); guard data == record.afterData else { throw Ledger.Problem.conflict }; record.state = .confirmed; record.observedData = data
        case .conflict(let data):
            try canonicalSettings(data); guard data != record.afterData else { throw Ledger.Problem.conflict }; record.state = .conflict; record.observedData = data
        case .uncertain: record.state = .uncertain
        case .notSent:
            guard record.state == .intent else { throw Ledger.Problem.conflict }; record.state = .notSent
        }
        try increment(&record.revision)
        var next = state; next.settings[i] = record; try commit(next, protecting: [record.id]); return record
    }
    func reconcile(id: UUID, expected: UInt64, data: Data, slot: Ledger.Slot) throws -> Ledger.SettingsRecord {
        try validateCurrent(); try canonicalSettings(data); try validateSlot(slot)
        guard let i = state.settings.firstIndex(where: { $0.id == id }) else { throw Ledger.Problem.conflict }
        var record = state.settings[i]; guard record.revision == expected else { throw Ledger.Problem.conflict }
        record.state = data == record.afterData ? .reconciledAfter : data == record.beforeData ? .reconciledBefore : .reconciledDifferent
        record.observedData = data; record.reassociatedSlot = slot; try increment(&record.revision)
        var next = state; next.settings[i] = record; try commit(next, protecting: [record.id]); return record
    }
    func prepareRun(_ intent: Ledger.RunIntent) throws -> Ledger.RunRecord {
        try validateCurrent(); try validateSlot(intent.slot); try intent.address.validate()
        guard hashSyntax(intent.descriptorSHA256) else { throw Ledger.Problem.invalid }
        guard !state.runs.contains(where: { $0.id == intent.id }), !state.settings.contains(where: { $0.id == intent.id }) else { throw Ledger.Problem.conflict }
        let record = Ledger.RunRecord(id: intent.id, slot: intent.slot, address: intent.address, descriptorSHA256: intent.descriptorSHA256,
            createdAt: timestamp(), sessionID: sessionID, revision: 0, phase: .running, cancelIDs: [], cancelUncertain: false)
        var next = state; next.runs.append(record); try commit(next); return record
    }
    func prepareCancel(id: UUID, expected: UInt64, cancelID: UUID) throws -> Ledger.RunRecord {
        try validateCurrent(); guard let i = state.runs.firstIndex(where: { $0.id == id }) else { throw Ledger.Problem.conflict }
        var record = state.runs[i]
        guard record.sessionID == sessionID else { throw Ledger.Problem.staleSession }
        guard record.revision == expected, record.unresolved, record.phase != .interrupted, record.cancelIDs.count < 8,
            !state.runs.contains(where: { $0.cancelIDs.contains(cancelID) }) else { throw Ledger.Problem.conflict }
        record.cancelIDs.append(cancelID); record.cancelUncertain = true; record.phase = .cancelling; try increment(&record.revision)
        var next = state; next.runs[i] = record; try commit(next, protecting: [record.id]); return record
    }
    func finishRun(id: UUID, expected: UInt64, phase: PluginRunPhase) throws -> Ledger.RunRecord {
        try validateCurrent(); guard let i = state.runs.firstIndex(where: { $0.id == id }) else { throw Ledger.Problem.conflict }
        var record = state.runs[i]
        guard record.sessionID == sessionID else { throw Ledger.Problem.staleSession }
        guard record.revision == expected, record.unresolved, [.succeeded, .failed, .cancelled, .interrupted].contains(phase) else { throw Ledger.Problem.conflict }
        record.phase = phase; if phase != .interrupted { record.cancelUncertain = false }; try increment(&record.revision)
        var next = state; next.runs[i] = record; try commit(next, protecting: [record.id]); return record
    }
    private func increment(_ value: inout UInt64) throws { guard value < UInt64.max else { throw Ledger.Problem.capacity }; value += 1 }
    private func commit(_ next: State, protecting protected: Set<UUID> = []) throws {
        var value = next; try retainWithinLimits(&value, protecting: protected); try increment(&value.revision); try validate(value); try persist(value); state = value
    }
    private func reservedRaw(_ state: State) -> Int {
        state.settings.reduce(0) { $0 + $1.beforeData.count + $1.afterData.count + ($1.unresolved ? 131_072 : ($1.observedData?.count ?? 0)) }
    }
    private func retainWithinLimits(_ value: inout State, protecting protected: Set<UUID>) throws {
        func raw(_ state: State) -> Int { reservedRaw(state) }
        while value.settings.count > 128 || value.runs.count > 128 || raw(value) > Ledger.rawByteLimit {
            if value.settings.count > 128 || raw(value) > Ledger.rawByteLimit {
                let recent = Set(value.settings.filter { !$0.unresolved }.suffix(64).map(\.id))
                var visited = Set<UUID>(), families = [Set<UUID>]()
                for row in value.settings where !visited.contains(row.id) {
                    var family: Set<UUID> = [row.id], changed = true
                    while changed {
                        changed = false
                        for member in value.settings {
                            if family.contains(member.id), let parent = member.parentID, family.insert(parent).inserted { changed = true }
                            if let parent = member.parentID, family.contains(parent), family.insert(member.id).inserted { changed = true }
                        }
                    }
                    visited.formUnion(family)
                    if family.isDisjoint(with: protected), value.settings.filter({ family.contains($0.id) }).allSatisfy({ !$0.unresolved }) { families.append(family) }
                }
                guard let chosen = families.first(where: { $0.isDisjoint(with: recent) }) ?? families.first else { throw Ledger.Problem.capacity }
                value.settings.removeAll { chosen.contains($0.id) }
            } else {
                let recent = Set(value.runs.filter { !$0.unresolved }.suffix(64).map(\.id))
                guard let index = value.runs.firstIndex(where: { !$0.unresolved && !recent.contains($0.id) && !protected.contains($0.id) }) ?? value.runs.firstIndex(where: { !$0.unresolved && !protected.contains($0.id) }) else { throw Ledger.Problem.capacity }
                value.runs.remove(at: index)
            }
        }
    }
    private func validate(_ value: State) throws {
        guard value.format == "nero-streamdeck-recovery/1", value.settings.count <= 128, value.runs.count <= 128,
            Set(value.settings.map(\.id)).count == value.settings.count, Set(value.runs.map(\.id)).count == value.runs.count,
            Set(value.settings.map(\.id)).isDisjoint(with: Set(value.runs.map(\.id))) else { throw Ledger.Problem.invalid }
        guard reservedRaw(value) <= Ledger.rawByteLimit else { throw Ledger.Problem.capacity }
        var bytes = 0
        for row in value.settings {
            try validateSlot(row.slot); try row.oldAddress.validate(); try row.newAddress.validate(); try canonicalSettings(row.beforeData); try canonicalSettings(row.afterData)
            guard validTimestamp(row.createdAt), row.kind == .undo ? row.parentID != nil : row.parentID == nil else { throw Ledger.Problem.invalid }
            bytes += row.beforeData.count + row.afterData.count
            if let observed = row.observedData { try canonicalSettings(observed); bytes += observed.count }
            switch row.state {
            case .intent, .uncertain, .notSent: guard row.observedData == nil, row.reassociatedSlot == nil else { throw Ledger.Problem.invalid }
            case .confirmed: guard row.observedData == row.afterData, row.reassociatedSlot == nil else { throw Ledger.Problem.invalid }
            case .conflict: guard row.observedData != nil, row.observedData != row.afterData, row.reassociatedSlot == nil else { throw Ledger.Problem.invalid }
            case .reconciledBefore: guard row.observedData == row.beforeData, row.reassociatedSlot != nil else { throw Ledger.Problem.invalid }
            case .reconciledAfter: guard row.observedData == row.afterData, row.reassociatedSlot != nil else { throw Ledger.Problem.invalid }
            case .reconciledDifferent: guard row.observedData != nil, row.observedData != row.beforeData, row.observedData != row.afterData, row.reassociatedSlot != nil else { throw Ledger.Problem.invalid }
            }
            if let slot = row.reassociatedSlot { try validateSlot(slot) }
            if row.kind == .undo {
                guard let parentID = row.parentID, parentID != row.id,
                    let parent = value.settings.first(where: { $0.id == parentID }),
                    row.beforeData == parent.afterData, row.afterData == parent.beforeData,
                    row.oldAddress == parent.newAddress, row.newAddress == parent.oldAddress else { throw Ledger.Problem.invalid }
            }
            guard bytes <= Ledger.rawByteLimit else { throw Ledger.Problem.capacity }
        }
        var cancels = Set<UUID>()
        for row in value.runs {
            try validateSlot(row.slot); try row.address.validate()
            guard hashSyntax(row.descriptorSHA256), validTimestamp(row.createdAt), row.cancelIDs.count <= 8,
                Set(row.cancelIDs).count == row.cancelIDs.count, row.cancelIDs.allSatisfy({ cancels.insert($0).inserted }),
                row.unresolved || !row.cancelUncertain,
                !row.cancelUncertain || !row.cancelIDs.isEmpty,
                row.phase != .cancelling || (!row.cancelIDs.isEmpty && row.cancelUncertain) else { throw Ledger.Problem.invalid }
        }
    }
    private func canonicalSettings(_ data: Data) throws {
        guard data.count <= 131_072 else { throw Ledger.Problem.capacity }
        guard try DeckRebindingJSON.canonical(DeckRebindingJSON.object(data)) == data else { throw Ledger.Problem.invalid }
    }
    private func validateSlot(_ slot: Ledger.Slot) throws {
        guard [slot.context, slot.action, slot.device, slot.controller, slot.revision].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.contains("\0") }),
            ["Keypad", "Encoder"].contains(slot.controller), (0..<8).contains(slot.row), (0..<12).contains(slot.column),
            ["cafe.nero.neronook.run", "cafe.nero.neronook.stop", "cafe.nero.neronook.status", "cafe.nero.neronook.menu"].contains(slot.action) else { throw Ledger.Problem.invalid }
    }
    private func timestamp() -> String { formatter().string(from: Date()) }
    private func formatter() -> ISO8601DateFormatter {
        if let timestampFormatter { return timestampFormatter }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter; return formatter
    }
    private func validTimestamp(_ value: String) -> Bool { let f = formatter(); guard value.utf8.count <= 40, let date = f.date(from: value) else { return false }; return f.string(from: date) == value }
    private func hashSyntax(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func encode(_ value: State) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value); guard data.count <= Ledger.encodedByteLimit else { throw Ledger.Problem.capacity }; return data
    }
    private func validateDirectory() throws {
        guard !closed, directoryFD >= 0, let directoryPin else { throw Ledger.Problem.closed }
        var fd = stat(), name = stat(); guard fstat(directoryFD, &fd) == 0, lstat(directory.path, &name) == 0,
            try DirectoryPin.capture(fd) == directoryPin, try DirectoryPin.capture(name) == directoryPin else { throw Ledger.Problem.conflict }
    }
    private func validateOwner() throws {
        try validateDirectory(); guard lockFD >= 0, let lockPin else { throw Ledger.Problem.closed }
        var info = stat(); guard fstat(lockFD, &info) == 0, try FilePin.capture(info, limit: 0) == lockPin,
            try named(Ledger.lockFilename, limit: 0) == lockPin else { throw Ledger.Problem.conflict }
    }
    private func validateCurrent() throws {
        guard !uncertain else { throw Ledger.Problem.uncertain }
        try validateOwner(); let current = try readLedger()
        guard current?.pin == image?.pin, current?.data == image?.data else { throw Ledger.Problem.conflict }; try validateOwner()
    }
    private func named(_ name: String, limit: Int) throws -> FilePin? {
        var info = stat(); if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw Ledger.Problem.unavailable }
        return try FilePin.capture(info, limit: limit)
    }
    private func readLedger() throws -> Image? {
        guard let pin = try named(Ledger.filename, limit: Ledger.encodedByteLimit) else { return nil }
        let fd = openat(directoryFD, Ledger.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Ledger.Problem.unavailable }; defer { _ = DarwinOrGlibcClose(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, try FilePin.capture(info, limit: Ledger.encodedByteLimit) == pin else { throw Ledger.Problem.conflict }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while bytes.count < pin.size {
            let n = readFD(fd, &buffer, min(buffer.count, pin.size - bytes.count))
            if n < 0, errno == EINTR { continue }; guard n > 0 else { throw Ledger.Problem.conflict }; bytes.append(contentsOf: buffer.prefix(n))
        }
        guard readFD(fd, &buffer, 1) == 0, fstat(fd, &info) == 0, try FilePin.capture(info, limit: Ledger.encodedByteLimit) == pin,
            try named(Ledger.filename, limit: Ledger.encodedByteLimit) == pin else { throw Ledger.Problem.conflict }
        return .init(data: bytes, pin: pin)
    }
    private func tempNames() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 130 else { throw Ledger.Problem.capacity }
        var result = [String](), total = 0
        for name in names where name != Ledger.filename && name != Ledger.lockFilename {
            guard name.hasPrefix(".ledger-"), name.hasSuffix(".tmp"), UUID(uuidString: String(name.dropFirst(8).dropLast(4))) != nil,
                let pin = try named(name, limit: Ledger.encodedByteLimit) else { throw Ledger.Problem.invalid }
            total += pin.size; guard total <= Ledger.encodedByteLimit else { throw Ledger.Problem.capacity }; result.append(name)
        }
        return result
    }
    private func persist(_ value: State) throws {
        try validateCurrent(); let bytes = try encode(value)
        guard try tempNames().isEmpty else { throw Ledger.Problem.conflict }
        let name = ".ledger-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Ledger.Problem.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var staged: FilePin?, published = false
        defer {
            try? handle.close()
            if !published, let staged, (try? named(name, limit: Ledger.encodedByteLimit)) == staged { _ = unlinkat(directoryFD, name, 0) }
        }
        do {
            try handle.write(contentsOf: bytes); try handle.synchronize()
            var info = stat(); guard fstat(fd, &info) == 0 else { throw Ledger.Problem.unavailable }; staged = try FilePin.capture(info, limit: Ledger.encodedByteLimit)
            try handle.close(); guard fsync(directoryFD) == 0 else { throw Ledger.Problem.uncertain }
            try validateCurrent()
            guard let staged, try named(name, limit: Ledger.encodedByteLimit) == staged else { throw Ledger.Problem.conflict }
            try hooks.beforePublish?()
            try validateCurrent()
            guard try named(name, limit: Ledger.encodedByteLimit) == staged else { throw Ledger.Problem.conflict }
            published = true // any subsequent failure may have published bytes
            if image == nil {
                guard linkat(directoryFD, name, directoryFD, Ledger.filename, 0) == 0, unlinkat(directoryFD, name, 0) == 0 else { throw Ledger.Problem.uncertain }
            } else { guard renameat(directoryFD, name, directoryFD, Ledger.filename) == 0 else { throw Ledger.Problem.uncertain } }
            guard fsync(directoryFD) == 0 else { throw Ledger.Problem.uncertain }
            try hooks.afterPublish?()
            try validateOwner(); guard let actual = try readLedger(), actual.data == bytes,
                actual.pin.device == staged.device, actual.pin.inode == staged.inode else { throw Ledger.Problem.uncertain }
            image = actual
        } catch { if published { uncertain = true; throw Ledger.Problem.uncertain }; throw error }
    }
    private func readFD(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }
}
private func DarwinOrGlibcOpen(_ path: String, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags)
    #else
    Glibc.open(path, flags)
    #endif
}
private func DarwinOrGlibcClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

/// Closed outer metadata is integer/string/base64 only; settings JSON stays an
/// opaque canonical byte string. Decode bounds do not widen the shared SDK.
private struct DeckLedgerJSONPreflight {
    let bytes: [UInt8]
    var cursor = 0, nodes = 0
    static func validate(_ data: Data) throws {
        guard data.count <= DeckRecoveryLedger.encodedByteLimit, String(data: data, encoding: .utf8) != nil else { throw DeckRecoveryLedger.Problem.invalid }
        var p = Self(bytes: Array(data)); try p.value(depth: 0); p.space(); guard p.cursor == p.bytes.count else { throw DeckRecoveryLedger.Problem.invalid }
    }
    mutating func space() { while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
    mutating func take(_ byte: UInt8) throws { space(); guard cursor < bytes.count, bytes[cursor] == byte else { throw DeckRecoveryLedger.Problem.invalid }; cursor += 1 }
    mutating func string() throws -> Data {
        space(); let start = cursor; try take(34)
        while cursor < bytes.count {
            let c = bytes[cursor]; cursor += 1
            if c == 34 {
                guard let text = try JSONSerialization.jsonObject(with: Data(bytes[start..<cursor]), options: [.fragmentsAllowed]) as? String else { throw DeckRecoveryLedger.Problem.invalid }
                return Data(text.utf8)
            }
            guard c >= 32 else { throw DeckRecoveryLedger.Problem.invalid }
            if c == 92 { guard cursor < bytes.count else { throw DeckRecoveryLedger.Problem.invalid }; cursor += 1 }
        }
        throw DeckRecoveryLedger.Problem.invalid
    }
    mutating func value(depth: Int) throws {
        space(); nodes += 1; guard depth <= 16, nodes <= 30_000, cursor < bytes.count else { throw DeckRecoveryLedger.Problem.capacity }
        switch bytes[cursor] {
        case 123:
            cursor += 1; space(); var keys = Set<Data>()
            if cursor < bytes.count && bytes[cursor] == 125 { cursor += 1; return }
            while true {
                guard keys.insert(try string()).inserted else { throw DeckRecoveryLedger.Problem.invalid }
                try take(58); try value(depth: depth + 1); space(); guard cursor < bytes.count else { throw DeckRecoveryLedger.Problem.invalid }
                if bytes[cursor] == 125 { cursor += 1; return }; try take(44)
            }
        case 91:
            cursor += 1; space(); if cursor < bytes.count && bytes[cursor] == 93 { cursor += 1; return }
            while true { try value(depth: depth + 1); space(); guard cursor < bytes.count else { throw DeckRecoveryLedger.Problem.invalid }; if bytes[cursor] == 93 { cursor += 1; return }; try take(44) }
        case 34: _ = try string()
        default:
            let start = cursor
            while cursor < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
            let token = String(decoding: bytes[start..<cursor], as: UTF8.self)
            guard ["true", "false", "null"].contains(token) || (!token.isEmpty && token.utf8.enumerated().allSatisfy({ index, c in (48...57).contains(c) || (index == 0 && c == 45) })) else { throw DeckRecoveryLedger.Problem.invalid }
        }
    }
}
