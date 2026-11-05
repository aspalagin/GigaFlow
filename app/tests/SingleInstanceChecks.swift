import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum SingleInstanceChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--try-lock" {
            let lock = try SingleInstanceLock.acquire(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            withExtendedLifetime(lock) { exit(lock == nil ? 23 : 0) }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gigaflow-instance-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nested/instance.lock")
        var checked = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checked += 1
        }
        func expectFailure(_ path: URL, _ message: String) {
            do {
                _ = try SingleInstanceLock.acquire(at: path)
                preconditionFailure(message)
            } catch { checked += 1 }
        }
        func childAttempt() throws -> Int32 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--try-lock", path.path]
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus
        }

        var first = try SingleInstanceLock.acquire(at: path)
        expect(first != nil, "Initial acquisition must succeed")
        let before = try FileManager.default.attributesOfItem(atPath: path.path)
        expect((before[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Lock file must be private")
        try withExtendedLifetime(first) {
            let second = try SingleInstanceLock.acquire(at: path)
            expect(second == nil, "Another descriptor must not acquire the same lock")
            let childStatus = try childAttempt()
            expect(childStatus == 23, "Another process must observe contention")
            let independent = try SingleInstanceLock.acquire(at: root.appendingPathComponent("independent.lock"))
            expect(independent != nil, "Independent lock paths must not interfere")
            withExtendedLifetime(independent) {}
        }
        first = nil
        expect(FileManager.default.fileExists(atPath: path.path), "Release must not unlink the lock file")
        let after = try FileManager.default.attributesOfItem(atPath: path.path)
        expect((before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber),
               "Release must preserve the inode")
        let releasedStatus = try childAttempt()
        expect(releasedStatus == 0, "Another process must acquire after release")

        let link = root.appendingPathComponent("symlink.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        expectFailure(link, "Symlink lock files must be rejected")
        expectFailure(root, "Directories must not be accepted as lock files")

        // posix_spawn with default attributes inherits open descriptors except
        // those marked close-on-exec. If the lock leaked into this sleeping
        // process, closing the parent's object would leave flock held by it.
        var owned = try SingleInstanceLock.acquire(at: path)
        expect(owned != nil, "Close-on-exec test must acquire its lock")
        let executable = strdup("/bin/sleep")!
        let duration = strdup("3")!
        defer { free(executable); free(duration) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable, duration, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var sleeper: pid_t = 0
        let spawnStatus: Int32 = withExtendedLifetime(owned) {
            arguments.withUnsafeMutableBufferPointer { argv in
                environment.withUnsafeMutableBufferPointer { envp in
                    posix_spawn(&sleeper, executable, nil, nil, argv.baseAddress!, envp.baseAddress!)
                }
            }
        }
        precondition(spawnStatus == 0 && sleeper > 0, "Could not start the isolated descriptor-inheritance check")
        defer {
            _ = kill(sleeper, SIGTERM)
            var status: Int32 = 0
            while waitpid(sleeper, &status, 0) == -1 && errno == EINTR {}
        }
        var status: Int32 = 0
        expect(waitpid(sleeper, &status, WNOHANG) == 0, "The exec child must still be running")
        owned = nil
        let reacquired = try SingleInstanceLock.acquire(at: path)
        expect(reacquired != nil, "An exec child must not retain its parent's lock")
        withExtendedLifetime(reacquired) {}

        print("Single-instance policy: \(checked) checks passed")
    }
}
