import Foundation
import Darwin
import NookPluginSDK

/// Module-owned namespace selection only, never an identity or permission.
/// Actual Entry resolves it once and supplies the same value to both roles.
enum BridgeScope: Equatable, Sendable {
    case live
    case fixture(UUID)

    static let resourceFilename = "NeroNookStreamDeckFixture.json"
    static let resourceLimit = 4096

    var folder: String {
        switch self {
        case .live: return "/tmp/neronook-deck-\(getuid())"
        case .fixture(let id): return "/tmp/nn-deck-test-\(getuid())-\(id.uuidString)"
        }
    }
    var socketPath: String { folder + "/bridge.sock" }
    var recoveryDirectory: URL {
        switch self {
        case .fixture:
            // Do not resolve this selected leaf before the ledger's no-follow checks.
            return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("companion-recovery", isDirectory: true)
        case .live:
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/NeroNookStreamDeck/CompanionRecovery", isDirectory: true)
        }
    }

    private static func commandSelection(_ arguments: [String]) throws -> UUID? {
        var selected: UUID?
        for (index, argument) in arguments.enumerated() where argument.hasPrefix("--bridge-fixture") {
            guard argument == "--bridge-fixture", selected == nil,
                  index + 1 < arguments.count,
                  let value = UUID(uuidString: arguments[index + 1]) else {
                throw BridgeScopeProblem("Invalid or repeated bridge fixture option.")
            }
            selected = value
        }
        return selected
    }
    static func resolve(arguments: [String], resource: Data?) throws -> BridgeScope {
        let command = try commandSelection(arguments)
        guard let resource else { return command.map(Self.fixture) ?? .live }
        guard resource.count <= resourceLimit else { throw BridgeScopeProblem("Fixture resource exceeds its limit.") }
        let value = try PluginFlowJSON.parse(resource)
        guard let members = value.members, members.count == 2,
              Set(members.map(\.name)) == Set(["format", "uuid"]),
              value["format"]?.string == "nero-streamdeck-fixture/1",
              let text = value["uuid"]?.string, text.utf8.count == 36,
              let id = UUID(uuidString: text), text.utf8.elementsEqual(id.uuidString.utf8) else {
            throw BridgeScopeProblem("Invalid fixture resource.")
        }
        guard command == nil else { throw BridgeScopeProblem("CLI and resource fixture selections cannot be combined.") }
        return .fixture(id)
    }
    /// Own-bundle metadata only. Missing leaf means absence; unreadable/aliased or
    /// malformed presence must never be converted to the live namespace.
    static func load(arguments: [String], resourceDirectory: URL?) throws -> BridgeScope {
        _ = try commandSelection(arguments) // reject bad CLI before even own-resource IO
        guard let resourceDirectory else { throw BridgeScopeProblem("Own resource directory is unavailable.") }
        return try resolve(arguments: arguments, resource: readResource(in: resourceDirectory))
    }
    static func readResource(in directory: URL) throws -> Data? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else {
            throw BridgeScopeProblem("Own resource directory is invalid.")
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw BridgeScopeProblem("Own resource directory cannot be read safely.") }
        defer { Darwin.close(parent) }
        var parentPin = stat()
        guard fstat(parent, &parentPin) == 0, (parentPin.st_mode & S_IFMT) == S_IFDIR else {
            throw BridgeScopeProblem("Own resource directory changed.")
        }
        var initial = stat()
        if fstatat(parent, resourceFilename, &initial, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw BridgeScopeProblem("Fixture resource is unreadable.") }
            try validateParent(directory, fd: parent, original: parentPin)
            var absentAgain = stat()
            guard fstatat(parent, resourceFilename, &absentAgain, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw BridgeScopeProblem("Fixture resource appeared while checking absence.")
            }
            return nil
        }
        guard regular(initial), initial.st_size >= 0, initial.st_size <= off_t(resourceLimit) else {
            throw BridgeScopeProblem("Fixture resource must be a bounded, non-linked regular file.")
        }
        let fd = openat(parent, resourceFilename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeScopeProblem("Fixture resource cannot be opened safely.") }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, regular(opened), same(initial, opened) else {
            throw BridgeScopeProblem("Fixture resource changed while opening.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: resourceLimit + 1)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, resourceLimit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BridgeScopeProblem("Fixture resource read failed.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= resourceLimit else { throw BridgeScopeProblem("Fixture resource exceeds its limit.") }
        }
        var final = stat(), named = stat()
        guard data.count == Int(opened.st_size), fstat(fd, &final) == 0,
              fstatat(parent, resourceFilename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              regular(final), regular(named), same(opened, final), same(opened, named) else {
            throw BridgeScopeProblem("Fixture resource changed while reading.")
        }
        try validateParent(directory, fd: parent, original: parentPin)
        return data
    }
    private static func regular(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func validateParent(_ path: URL, fd: Int32, original: stat) throws {
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, lstat(path.path, &named) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino else {
            throw BridgeScopeProblem("Own resource directory changed while reading.")
        }
    }
}
struct BridgeScopeProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
