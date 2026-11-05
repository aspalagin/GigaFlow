import Foundation
import Darwin

/// A worker can exit between isRunning and write. Protect this descriptor so
/// Foundation reports EPIPE instead of SIGPIPE terminating the entire app.
enum WorkerPipe {
    static func write(_ data: Data, to handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.write(contentsOf: data)
    }
}
