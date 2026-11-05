import Foundation
import Darwin

@main
enum WorkerPipeChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--closed-reader") {
            signal(SIGPIPE, SIG_DFL)
            let pipe = Pipe()
            try pipe.fileHandleForReading.close()
            do {
                try WorkerPipe.write(Data([1]), to: pipe.fileHandleForWriting)
                exit(2)
            } catch {
                // Surviving this write, with a reported error, is the regression.
                exit(0)
            }
        }

        let pipe = Pipe()
        let expected = Data("worker request\n".utf8)
        try WorkerPipe.write(expected, to: pipe.fileHandleForWriting)
        precondition(pipe.fileHandleForReading.readData(ofLength: expected.count) == expected)
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--closed-reader"]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationReason == .exit && child.terminationStatus == 0,
                     "A closed worker pipe terminated the sender or did not report its error")
        print("Worker IPC: 2 checks passed")
    }
}
