import Foundation

/// Runs a short-lived tool and returns what it wrote. A timeout or a
/// cancelled request terminates it, so nothing outlives the request.
enum CommandRunner {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

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
            process.terminate()
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
            process.terminate()
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure(description: "\(executable.lastPathComponent) stopped with status \(process.terminationStatus).")
        }
        return data
    }
}
