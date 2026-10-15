import Foundation
import Darwin

public protocol GitHubTransport: Sendable {
    func request(query: String, variables: [String: String]) async throws -> Data
}

/// Authentication stays with gh. The app never asks for, reads, or persists its token.
public struct GitHubCLITransport: GitHubTransport {
    public init() {}

    public func request(query: String, variables: [String: String]) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let result = try await Task.detached(priority: .utility) {
            try Self.run(input: input)
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func run(input: Data) throws -> Data {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ReviewError.cliMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["api", "graphql", "--hostname", "github.com", "--input", "-"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["GH_DEBUG"] = nil
        environment["DEBUG"] = nil
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let output = LockedData(), errors = LockedData()
        let readers = DispatchGroup()
        do { try process.run() } catch { throw ReviewError.cliMissing }
        for (pipe, storage) in [(stdout, output), (stderr, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                storage.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let timeoutFlag = LockedData()
        deadline.schedule(deadline: .now() + 45)
        deadline.setEventHandler {
            if process.isRunning {
                timeoutFlag.set(Data([1]))
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        deadline.resume()
        defer { deadline.cancel() }
        do { try stdin.fileHandleForWriting.write(contentsOf: input) } catch {
            if process.isRunning { process.terminate() }
        }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        readers.wait()
        if !timeoutFlag.get().isEmpty { throw ReviewError.timedOut }
        guard process.terminationStatus == 0 else {
            // Raw stderr can contain private repository names. Never propagate it into logs/UI.
            let message = String(data: errors.get(), encoding: .utf8)?.lowercased() ?? ""
            if message.contains("rate limit") { throw ReviewError.rateLimited }
            if message.contains("auth login") || message.contains("bad credentials") || message.contains("401") {
                throw ReviewError.authentication
            }
            if message.contains("connect") || message.contains("no such host") || message.contains("timeout") {
                throw ReviewError.network
            }
            throw ReviewError.api
        }
        return output.get()
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
