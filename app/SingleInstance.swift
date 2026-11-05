import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SingleInstanceLockError: Error, LocalizedError {
    case operation(String, Int32)
    case unsafeFile
    case descriptorMayBeInherited

    var errorDescription: String? {
        switch self {
        case let .operation(name, code):
            return "GigaFlow instance lock: \(name) failed (\(String(cString: strerror(code))))."
        case .unsafeFile:
            return "GigaFlow instance lock must be a regular file owned by the current user."
        case .descriptorMayBeInherited:
            return "GigaFlow instance lock could be inherited by a child process."
        }
    }
}

/// One normal application process per user. Keep the returned object alive for
/// the entire app.run() lifetime. Diagnostic processes use their own policy.
/// The file remains in place: unlinking it would let another process lock a new
/// inode while an existing owner still holds the original inode.
final class SingleInstanceLock {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GigaFlow/instance.lock")
    }

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        // Closing the final descriptor releases flock, including on a crash.
        // Do not explicitly unlock: the kernel owns the descriptor's lifetime.
        close(descriptor)
    }

    /// nil means another process owns the lock; setup/I/O failures throw.
    /// The explicit URL is useful for isolated tests, never a second live lock.
    static func acquire(at url: URL = defaultURL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SingleInstanceLockError.operation("open", errno) }
        var adopted = false
        defer { if !adopted { close(descriptor) } }

        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw SingleInstanceLockError.operation("fstat", errno)
        }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_uid == getuid() else { throw SingleInstanceLockError.unsafeFile }

        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { throw SingleInstanceLockError.operation("fcntl", errno) }
        guard flags & FD_CLOEXEC != 0 else { throw SingleInstanceLockError.descriptorMayBeInherited }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw SingleInstanceLockError.operation("flock", code)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SingleInstanceLockError.operation("fchmod", errno)
        }
        adopted = true
        return SingleInstanceLock(descriptor: descriptor)
    }
}
