import Foundation

/// Runs a short-lived tool and returns what it wrote. A timeout or a
/// cancelled request terminates it, so nothing outlives the request.
enum CommandRunner {
    /// The tool stopped early or with a failing status.
    struct Failure: Error {}

    static func output(of executable: URL, arguments: [String], timeout: Duration) async throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let timer = Task {
            try await Task.sleep(for: timeout)
            stop(process)
        }
        defer { timer.cancel() }

        // The output can pass the pipe's buffer, so it is read while the tool
        // runs, on a thread of its own; reading ends when the tool exits.
        let data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    exited.wait()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            stop(process)
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure()
        }
        return data
    }

    /// Asks the tool to quit, then kills one that doesn't, so reading its
    /// output always ends. A tool that already exited is left alone, since
    /// its PID may be another process's by now.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
