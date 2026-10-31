import XCTest
import Foundation
import Darwin
@testable import StreamDeckPlugin

final class BridgeScopeTests: XCTestCase {
    private let id = UUID(uuidString: "26A86413-E5E1-4BA4-B1FB-93AE921DF25B")!
    private func resource(_ id: UUID) -> Data {
        Data(("{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":\"" + id.uuidString + "\"}").utf8)
    }
    private func withResources(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nero-deck-scope-resource-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func withFixtureFolder(_ body: (BridgeScope) throws -> Void) throws {
        let scope = BridgeScope.fixture(UUID())
        guard mkdir(scope.folder, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var original = stat(); XCTAssertEqual(lstat(scope.folder, &original), 0)
        defer {
            var current = stat()
            if lstat(scope.folder, &current) == 0, current.st_dev == original.st_dev,
               current.st_ino == original.st_ino, (current.st_mode & S_IFMT) == S_IFDIR {
                try? FileManager.default.removeItem(atPath: scope.folder)
            }
        }
        try body(scope)
    }

    @MainActor func testAbsentSelectorsKeepLiveAndCLIOrResourceChooseSameTypedScope() throws {
        XCTAssertEqual(try BridgeScope.resolve(arguments: ["module", "--neronook-plugin"], resource: nil), .live)
        let cli = try BridgeScope.resolve(arguments: ["module", "--bridge-fixture", id.uuidString.lowercased()], resource: nil)
        let sealed = try BridgeScope.resolve(arguments: ["module", "--neronook-plugin"], resource: resource(id))
        XCTAssertEqual(cli, .fixture(id)); XCTAssertEqual(sealed, cli)
        XCTAssertEqual(cli.folder, "/tmp/nn-deck-test-\(getuid())-\(id.uuidString)")
        XCTAssertEqual(cli.socketPath, cli.folder + "/bridge.sock")
        XCTAssertEqual(cli.recoveryDirectory.path, cli.folder + "/companion-recovery")
        XCTAssertEqual(DeckRecoveryCoordinator.directory(scope: sealed), cli.recoveryDirectory)
    }
    func testMalformedDuplicateMissingAndPrefixCLIAlwaysRefuse() throws {
        let cases = [
            ["--bridge-fixture"], ["--bridge-fixture", ""], ["--bridge-fixture", "not-a-uuid"],
            ["--bridge-fixture", "--neronook-plugin"], ["--bridge-fixture=" + id.uuidString],
            ["--bridge-fixture-extra", id.uuidString], ["--bridge-fixture", id.uuidString, "--bridge-fixture", id.uuidString],
            ["--bridge-fixture", id.uuidString, "--bridge-fixture", UUID().uuidString]
        ]
        for args in cases {
            XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module"] + args, resource: nil), "\(args)")
            XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module"] + args, resource: resource(id)), "\(args)")
        }
    }
    func testSimultaneousSourcesRefuseEvenWhenEqual() throws {
        XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module", "--bridge-fixture", id.uuidString], resource: resource(id)))
        XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module", "--bridge-fixture", UUID().uuidString], resource: resource(id)))
    }
    func testStrictResourceRejectsDuplicateUnknownBadTypeAndNoncanonicalUUID() throws {
        let text = id.uuidString
        let cases = [
            "{}", "null", "[]", "{\"format\":\"nero-streamdeck-fixture/2\",\"uuid\":\"\(text)\"}",
            "{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":null}",
            "{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":7}",
            "{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":\"\(text.lowercased())\"}",
            "{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":\"\(text)\",\"path\":\"/tmp/elsewhere\"}",
            "{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":\"\(text)\",\"uuid\":\"\(text)\"}",
            "{\"format\":\"nero-streamdeck-fixture/1\",\"uuid\":\"\(text)\",\"uu\\u0069d\":\"\(text)\"}"
        ]
        for value in cases { XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module"], resource: Data(value.utf8)), value) }
        XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module"], resource: Data([0xff])))
        XCTAssertThrowsError(try BridgeScope.resolve(arguments: ["module"], resource: Data(repeating: 32, count: 4097)))
    }
    func testOwnResourceAbsentAndExactBoundedRead() throws {
        try withResources { root in
            XCTAssertEqual(try BridgeScope.load(arguments: ["module"], resourceDirectory: root), .live)
            let body = resource(id)
            let padded = body + Data(repeating: 32, count: BridgeScope.resourceLimit - body.count)
            try padded.write(to: root.appendingPathComponent(BridgeScope.resourceFilename))
            XCTAssertEqual(try BridgeScope.readResource(in: root), padded)
            XCTAssertEqual(try BridgeScope.load(arguments: ["module", "--neronook-plugin"], resourceDirectory: root), .fixture(id))
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module", "--bridge-fixture", id.uuidString], resourceDirectory: root))
        }
    }
    func testPresentMalformedAndOversizedResourceNeverBecomeLive() throws {
        try withResources { root in
            let leaf = root.appendingPathComponent(BridgeScope.resourceFilename)
            for data in [Data(), Data("invalid".utf8), Data(repeating: 32, count: 4097)] {
                try data.write(to: leaf)
                XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: root))
                XCTAssertThrowsError(try BridgeScope.load(arguments: ["module", "--bridge-fixture", id.uuidString], resourceDirectory: root))
            }
        }
    }
    func testBrokenSymlinkHardlinkAndNonregularResourcesRefuseWithoutFollowing() throws {
        try withResources { root in
            let leaf = root.appendingPathComponent(BridgeScope.resourceFilename)
            XCTAssertEqual(symlink("missing-target", leaf.path), 0)
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: root))
            try FileManager.default.removeItem(at: leaf)
            let original = root.appendingPathComponent("original.json")
            try resource(id).write(to: original)
            XCTAssertEqual(link(original.path, leaf.path), 0)
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: root))
            try FileManager.default.removeItem(at: leaf)
            XCTAssertEqual(mkfifo(leaf.path, 0o600), 0)
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: root))
            try FileManager.default.removeItem(at: leaf)
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: root))
            XCTAssertEqual(try Data(contentsOf: original), resource(id))
        }
    }
    func testAliasedOrMissingOwnResourceDirectoryRefuses() throws {
        try withResources { root in
            let actual = root.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            try resource(id).write(to: actual.appendingPathComponent(BridgeScope.resourceFilename))
            let alias = root.appendingPathComponent("alias", isDirectory: true)
            XCTAssertEqual(symlink(actual.path, alias.path), 0)
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: alias))
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: root.appendingPathComponent("missing")))
            XCTAssertThrowsError(try BridgeScope.load(arguments: ["module"], resourceDirectory: nil))
        }
    }
    func testBadCLIRefusesBeforeOwnResourceAccess() throws {
        // Invalid CLI wins even when the own-resource location cannot be read.
        XCTAssertThrowsError(try BridgeScope.load(arguments: ["module", "--bridge-fixture"], resourceDirectory: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("fixture option"))
        }
    }
    func testNonSocketConflictReleasesLockAndKeepsExistingData() throws {
        try withFixtureFolder { scope in
            let file = URL(fileURLWithPath: scope.socketPath), marker = Data("retain external object".utf8)
            try marker.write(to: file)
            let bridge = LocalBridge(scope: scope); defer { bridge.stop() }
            XCTAssertThrowsError(try bridge.listen { $0.close() })
            XCTAssertEqual(try Data(contentsOf: file), marker)
            try FileManager.default.removeItem(at: file)
            XCTAssertNoThrow(try bridge.listen { $0.close() }) // failed acquisition left no held lock/FD state
        }
    }
    func testSocketSymlinkConflictIsPreservedAndDoesNotFollow() throws {
        try withFixtureFolder { scope in
            let target = URL(fileURLWithPath: scope.folder).appendingPathComponent("target")
            try Data("retain target".utf8).write(to: target)
            XCTAssertEqual(symlink(target.path, scope.socketPath), 0)
            let bridge = LocalBridge(scope: scope); defer { bridge.stop() }
            XCTAssertThrowsError(try bridge.listen { $0.close() })
            var value = stat(); XCTAssertEqual(lstat(scope.socketPath, &value), 0)
            XCTAssertEqual(value.st_mode & S_IFMT, S_IFLNK)
            XCTAssertEqual(try Data(contentsOf: target), Data("retain target".utf8))
            XCTAssertEqual(unlink(scope.socketPath), 0)
            XCTAssertNoThrow(try bridge.listen { $0.close() })
        }
    }
    func testDuplicateAndRepeatedListenCannotUnlinkOriginalListener() throws {
        try withFixtureFolder { scope in
            let accepted = expectation(description: "real same-user connection accepted")
            let original = LocalBridge(scope: scope), duplicate = LocalBridge(scope: scope)
            defer { duplicate.stop(); original.stop() }
            try original.listen { connection in connection.close(); accepted.fulfill() }
            var before = stat(); XCTAssertEqual(lstat(scope.socketPath, &before), 0)
            XCTAssertThrowsError(try original.listen { $0.close() })
            XCTAssertThrowsError(try duplicate.listen { $0.close() })
            var after = stat(); XCTAssertEqual(lstat(scope.socketPath, &after), 0)
            XCTAssertEqual(before.st_dev, after.st_dev); XCTAssertEqual(before.st_ino, after.st_ino)
            let client = try LocalBridge.connect(scope: scope); client.close()
            wait(for: [accepted], timeout: 2)
        }
    }
    func testStopKeepsReplacementNodeInsteadOfUnlinkingIt() throws {
        try withFixtureFolder { scope in
            let bridge = LocalBridge(scope: scope)
            try bridge.listen { $0.close() }
            XCTAssertEqual(unlink(scope.socketPath), 0)
            let file = URL(fileURLWithPath: scope.socketPath), marker = Data("later replacement".utf8)
            try marker.write(to: file)
            bridge.stop()
            XCTAssertEqual(try Data(contentsOf: file), marker)
        }
    }
    func testSymlinkedFixtureFolderCannotCreateLockInReferent() throws {
        try withResources { root in
            let scope = BridgeScope.fixture(UUID())
            XCTAssertEqual(symlink(root.path, scope.folder), 0)
            defer { unlink(scope.folder) }
            let bridge = LocalBridge(scope: scope); defer { bridge.stop() }
            XCTAssertThrowsError(try bridge.listen { $0.close() })
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("owner.lock").path))
        }
    }
}
