import Foundation
import os

struct CommandFailure: Error, Equatable, CustomStringConvertible {
    let message: String

    var description: String { message }
}

protocol CommandRunner: Sendable {
    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> String
}

struct ProcessRunner: CommandRunner {
    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CommandFailure(message: "not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let timedOut = OSAllocatedUnfairLock(initialState: false)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    let stdout = output.fileHandleForReading.readDataToEndOfFile()
                    let stderr = errors.fileHandleForReading.readDataToEndOfFile()

                    if timedOut.withLock({ $0 }) {
                        continuation.resume(
                            throwing: CommandFailure(message: "timed out after \(Int(timeout))s"))
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: String(decoding: stdout, as: UTF8.self))
                    } else {
                        continuation.resume(
                            throwing: Self.failure(stderr, status: process.terminationStatus))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }

                    timedOut.withLock { $0 = true }
                    stopProcess(process)
                }
            }
        } onCancel: {
            stopProcess(process)
        }
    }

    private static func failure(_ stderr: Data, status: Int32) -> CommandFailure {
        let text = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CommandFailure(message: text.isEmpty ? "exited with \(status)" : text)
    }
}

private let killGrace: TimeInterval = 1

/// Sends SIGTERM to a running process, then SIGKILL if it still runs after a short grace.
func stopProcess(_ process: Process) {
    guard process.isRunning else { return }

    process.terminate()

    let pid = process.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
        if process.isRunning { kill(pid, SIGKILL) }
    }
}
