import Foundation
import Darwin

/// Same-user, local-only transport between this integration's two installed ends.
/// No TCP listener, browser endpoint, or host-specific transport is introduced.
final class LocalConnection {
    let handle: FileHandle
    var received: ((Data) -> Void)?
    var ended: (() -> Void)?
    private let writeQueue = DispatchQueue(label: "StreamDeckBridge.write")
    private let lock = NSLock()
    private var closed = false
    private var queued = 0
    private var queuedBytes = 0
    init(_ fd: Int32) { handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
    func start() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var pending = Data()
            // FileHandle.read(upToCount:) may wait to fill its requested buffer on
            // a socket. POSIX read returns each available chunk immediately.
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(self.handle.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 131072 else { break }
                while let end = pending.firstIndex(of: 10) { let line = Data(pending[..<end]); pending.removeSubrange(...end); self.received?(line) }
            }
            self.close(); self.ended?()
        }
    }
    func send(_ data: Data) {
        lock.lock()
        guard !closed, data.count <= 131071, queued < 1282, queuedBytes + data.count <= 8 * 1024 * 1024 else { lock.unlock(); close(); return }
        queued += 1; queuedBytes += data.count; lock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            do { var line = data; line.append(10); try self.handle.write(contentsOf: line) } catch { self.close() }
            self.lock.lock(); self.queued -= 1; self.queuedBytes -= data.count; self.lock.unlock()
        }
    }
    func close() { lock.lock(); defer { lock.unlock() }; if !closed { closed = true; shutdown(handle.fileDescriptor, SHUT_RDWR); try? handle.close() } }
}
final class LocalBridge {
    private struct SocketIdentity {
        let device: dev_t
        let inode: ino_t
        let uid: uid_t
        init?(_ value: stat) {
            guard (value.st_mode & S_IFMT) == S_IFSOCK, value.st_uid == getuid() else { return nil }
            device = value.st_dev; inode = value.st_ino; uid = value.st_uid
        }
        func matches(_ value: stat) -> Bool {
            value.st_dev == device && value.st_ino == inode && value.st_uid == uid &&
                (value.st_mode & S_IFMT) == S_IFSOCK
        }
    }
    private let scope: BridgeScope
    private var listener: Int32 = -1
    private var socketPath = ""
    private var socketIdentity: SocketIdentity?
    private var lockFD: Int32 = -1
    init(scope: BridgeScope) { self.scope = scope }
    private static func address(scope: BridgeScope) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(scope.socketPath.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else {
            throw BridgeScopeProblem("Bridge socket path exceeds its limit.")
        }
        withUnsafeMutableBytes(of: &a.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); return a
    }
    private static func verifyFolder(scope: BridgeScope, create: Bool) throws {
        let folder = scope.folder
        if create { if mkdir(folder, 0o700) != 0 && errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) } }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0 else { throw NSError(domain: "Private local bridge folder is unavailable", code: 1) }
    }
    private static func unlinkOwnedSocket(_ path: String, identity: SocketIdentity?) {
        guard let identity else { return }
        var current = stat()
        if lstat(path, &current) == 0, identity.matches(current) { unlink(path) }
    }
    func listen(accept: @escaping (LocalConnection) -> Void) throws {
        guard listener < 0, lockFD < 0 else { throw BridgeScopeProblem("This bridge is already listening.") }
        try Self.verifyFolder(scope: scope, create: true)
        let path = scope.socketPath
        // Acquire locally. Only a fully established listener owns class fields.
        let lock = open(scope.folder + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw NSError(domain: "Bridge lock unavailable", code: 1) }
        var fd: Int32 = -1, bound: SocketIdentity?
        var published = false
        defer {
            if !published {
                if fd >= 0 { Darwin.close(fd) }
                Self.unlinkOwnedSocket(path, identity: bound)
                Darwin.close(lock)
            }
        }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "Another bridge owns this connection", code: 1) }
        var prior = stat()
        if lstat(path, &prior) == 0 {
            guard SocketIdentity(prior) != nil, unlink(path) == 0 else {
                throw BridgeScopeProblem("Bridge socket path is occupied by another object.")
            }
        } else if errno != ENOENT { throw BridgeScopeProblem("Bridge socket path cannot be checked.") }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var a = try Self.address(scope: scope)
        let result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw NSError(domain: "Stream Deck bridge already active or unavailable", code: 1) }
        var created = stat()
        guard lstat(path, &created) == 0, let identity = SocketIdentity(created) else {
            throw BridgeScopeProblem("Bound bridge socket could not be checked.")
        }
        bound = identity
        guard Darwin.listen(fd, 4) == 0, chmod(path, 0o600) == 0 else {
            throw NSError(domain: "Stream Deck bridge setup failed", code: 1)
        }
        var final = stat()
        guard lstat(path, &final) == 0, identity.matches(final), (final.st_mode & 0o777) == 0o600 else {
            throw BridgeScopeProblem("Bound bridge socket changed during setup.")
        }
        listener = fd; lockFD = lock; socketPath = path; socketIdentity = identity
        published = true
        let acceptedFD = fd
        DispatchQueue.global().async {
            while true {
                let client = Darwin.accept(acceptedFD, nil, nil); if client < 0 { break }
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); continue }
                var noPipe: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
                accept(LocalConnection(client))
            }
        }
    }
    static func connect(scope: BridgeScope) throws -> LocalConnection {
        try verifyFolder(scope: scope, create: false)
        var a = try address(scope: scope)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let status = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0 else { let code = errno; Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); throw NSError(domain: "Unexpected bridge owner", code: 1) }
        var noPipe: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        return LocalConnection(fd)
    }
    func stop() {
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1
            Self.unlinkOwnedSocket(socketPath, identity: socketIdentity)
            socketPath = ""; socketIdentity = nil
        }
        if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
    }
    deinit { stop() }
}
