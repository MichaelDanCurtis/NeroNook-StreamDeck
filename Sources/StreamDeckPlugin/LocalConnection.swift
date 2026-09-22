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
    private var listener: Int32 = -1
    private var socketPath = ""
    private var lockFD: Int32 = -1
    static var folder: String {
        // Fixture processes use a unique socket namespace and cannot attach to a
        // running installation. The flag accepts a UUID, never an arbitrary path.
        if let index = CommandLine.arguments.firstIndex(of: "--bridge-fixture"),
           index + 1 < CommandLine.arguments.count,
           let id = UUID(uuidString: CommandLine.arguments[index + 1]) {
            return "/tmp/nn-deck-test-\(getuid())-\(id.uuidString)"
        }
        return "/tmp/neronook-deck-\(getuid())"
    }
    static var path: String { folder + "/bridge.sock" }
    static func address() -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { buffer in for (i, byte) in (Array(path.utf8) + [UInt8(0)]).enumerated() { buffer[i] = byte } }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); return a
    }
    static func verifyFolder(create: Bool) throws {
        if create { if mkdir(folder, 0o700) != 0 && errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) } }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0 else { throw NSError(domain: "Private local bridge folder is unavailable", code: 1) }
    }
    func listen(accept: @escaping (LocalConnection) -> Void) throws {
        try Self.verifyFolder(create: true)
        // flock prevents a second plugin instance from unlinking the active listener.
        let lock = open(Self.folder + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw NSError(domain: "Bridge lock unavailable", code: 1) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, flock(lock, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lock); throw NSError(domain: "Another bridge owns this connection", code: 1) }
        lockFD = lock
        unlink(Self.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var a = Self.address()
        let result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, Darwin.listen(fd, 4) == 0 else { Darwin.close(fd); throw NSError(domain: "Stream Deck bridge already active or unavailable", code: 1) }
        chmod(Self.path, 0o600); listener = fd; socketPath = Self.path
        DispatchQueue.global().async {
            while true {
                let client = Darwin.accept(fd, nil, nil); if client < 0 { break }
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); continue }
                var noPipe: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
                accept(LocalConnection(client))
            }
        }
    }
    static func connect() throws -> LocalConnection {
        try verifyFolder(create: false)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var a = address()
        let status = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0 else { Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); throw NSError(domain: "Unexpected bridge owner", code: 1) }
        var noPipe: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        return LocalConnection(fd)
    }
    func stop() { if listener >= 0 { shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1; unlink(socketPath) }; if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 } }
    deinit { stop() }
}
