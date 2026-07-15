import Darwin
import Foundation
import MiPopupCore

protocol SubscriptionQuotaProviding: Sendable {
    var providerID: SubscriptionProviderID { get }
    func fetch() async throws -> SubscriptionQuotaSnapshot
}

protocol ModelIntelligenceProviding: Sendable {
    func fetch() async throws -> ModelIntelligenceSnapshot
}

enum SubscriptionQuotaProviderError: LocalizedError {
    case executableNotFound(String)
    case processFailed(String)
    case timedOut(String)
    case serviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name): "未找到 \(name)，请先安装并登录。"
        case .processFailed(let message): message
        case .timedOut(let name): "读取 \(name) 额度超时，请稍后重试。"
        case .serviceUnavailable(let message): message
        }
    }
}

struct CodexRadarProvider: ModelIntelligenceProviding {
    private let endpoint = URL(string: "https://codexradar.com/current.json")!

    func fetch() async throws -> ModelIntelligenceSnapshot {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 20
        request.setValue("MiPopup/0.1 (+https://codexradar.com)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw SubscriptionQuotaProviderError.serviceUnavailable("Codex Radar 暂时不可用。")
            }
            return try CodexRadarParser.parse(data)
        } catch let error as CodexRadarParseError {
            throw error
        } catch let error as SubscriptionQuotaProviderError {
            throw error
        } catch {
            throw SubscriptionQuotaProviderError.serviceUnavailable(
                "模型智力数据读取失败：\(error.localizedDescription)"
            )
        }
    }
}

struct CodexSubscriptionQuotaProvider: SubscriptionQuotaProviding {
    let providerID = SubscriptionProviderID.openAI

    func fetch() async throws -> SubscriptionQuotaSnapshot {
        guard let binary = ExecutableLocator.firstExecutable(
            environmentKey: "CODEX_CLI_PATH",
            candidates: [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "~/.local/bin/codex",
            ]
        ) else {
            throw SubscriptionQuotaProviderError.executableNotFound("Codex CLI")
        }

        return try await Task.detached(priority: .utility) {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errorOutput = Pipe()
            let collector = CodexResponseCollector()

            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorOutput
            process.terminationHandler = { process in
                collector.processExited(status: process.terminationStatus)
            }

            output.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData)
            }
            errorOutput.fileHandleForReading.readabilityHandler = { handle in
                collector.appendDiagnostic(handle.availableData)
            }
            defer {
                process.terminationHandler = nil
                output.fileHandleForReading.readabilityHandler = nil
                errorOutput.fileHandleForReading.readabilityHandler = nil
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
                let request = """
                {"id":1,"method":"initialize","params":{"clientInfo":{"name":"MiPopup","version":"0.1"},"capabilities":{"experimentalApi":true}}}
                {"id":2,"method":"account/rateLimits/read","params":null}

                """
                try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))

                let response = try collector.wait(timeout: 12)
                return try CodexSubscriptionQuotaParser.parse(responseLine: response)
            } catch let error as SubscriptionQuotaProviderError {
                throw error
            } catch {
                throw SubscriptionQuotaProviderError.processFailed(
                    "Codex 额度读取失败：\(error.localizedDescription)"
                )
            }
        }.value
    }
}

struct AntigravitySubscriptionQuotaProvider: SubscriptionQuotaProviding {
    let providerID = SubscriptionProviderID.google

    func fetch() async throws -> SubscriptionQuotaSnapshot {
        var lastError: Error?
        let candidates = (try? await AntigravityProcessDetector.runningProcesses()) ?? []
        for candidate in candidates {
            do {
                return try await fetch(process: candidate)
            } catch {
                lastError = error
            }
        }

        guard let agy = ExecutableLocator.firstExecutable(
            environmentKey: "ANTIGRAVITY_CLI_PATH",
            candidates: [
                "~/.local/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
            ]
        ) else {
            if let lastError { throw lastError }
            throw SubscriptionQuotaProviderError.executableNotFound("Antigravity CLI")
        }

        let session: AgyPTYSession
        do {
            session = try AgyPTYSession(binary: agy)
        } catch {
            throw SubscriptionQuotaProviderError.processFailed(
                "无法启动 Antigravity CLI：\(error.localizedDescription)"
            )
        }
        defer { session.stop() }

        let candidate = AntigravityProcessInfo(pid: session.pid, csrfToken: nil, extraEndpoints: [])
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            do {
                return try await fetch(process: candidate)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(450))
            }
        }

        throw lastError ?? SubscriptionQuotaProviderError.timedOut("Google Antigravity")
    }

    private func fetch(process: AntigravityProcessInfo) async throws -> SubscriptionQuotaSnapshot {
        let ports = try await AntigravityProcessDetector.listeningPorts(pid: process.pid)
        let httpsEndpoints = ports.map {
            AntigravityEndpoint(scheme: "https", port: $0, csrfToken: process.csrfToken)
        }
        let endpoints = httpsEndpoints + process.extraEndpoints
        guard !endpoints.isEmpty else {
            throw SubscriptionQuotaProviderError.serviceUnavailable("Antigravity 本地服务尚未就绪。")
        }

        var lastError: Error?
        for endpoint in endpoints {
            do {
                let summaryData = try await AntigravityHTTPClient.request(
                    endpoint: endpoint,
                    path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                    body: Self.quotaSummaryBody,
                    timeout: 4
                )
                let identityData = try? await AntigravityHTTPClient.request(
                    endpoint: endpoint,
                    path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
                    body: Self.metadataBody,
                    timeout: 2
                )
                let planName = identityData.flatMap {
                    AntigravitySubscriptionQuotaParser.planName(fromUserStatus: $0)
                }
                return try AntigravitySubscriptionQuotaParser.parseSummary(
                    summaryData,
                    planName: planName
                )
            } catch {
                lastError = error
            }

            do {
                let statusData = try await AntigravityHTTPClient.request(
                    endpoint: endpoint,
                    path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
                    body: Self.metadataBody,
                    timeout: 5
                )
                return try AntigravitySubscriptionQuotaParser.parseUserStatus(statusData)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SubscriptionQuotaProviderError.serviceUnavailable(
            "Antigravity 没有返回可用额度，请确认已登录。"
        )
    }

    private static let quotaSummaryBody = Data(#"{"forceRefresh":true}"#.utf8)
    private static let metadataBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"zh-CN"}}"#.utf8)
}

private enum ExecutableLocator {
    static func firstExecutable(environmentKey: String, candidates: [String]) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let allCandidates = [environment[environmentKey]].compactMap { $0 } + candidates
        return allCandidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private final class CodexResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var response: Data?
    private var errorMessage: String?
    private var diagnosticBuffer = Data()
    private var finished = false

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2
            else { continue }

            if object["result"] != nil {
                response = line
            } else {
                let error = object["error"] as? [String: Any]
                errorMessage = error?["message"] as? String ?? "Codex app-server 返回错误。"
            }
            finished = true
            signal.signal()
            return
        }
    }

    func appendDiagnostic(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        diagnosticBuffer.append(data)
        if diagnosticBuffer.count > 4_096 {
            diagnosticBuffer = diagnosticBuffer.suffix(4_096)
        }
    }

    func processExited(status: Int32) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let diagnostic = String(decoding: diagnosticBuffer, as: UTF8.self).lowercased()
        if diagnostic.contains("sqlite state runtime") ||
            diagnostic.contains("permission denied") ||
            diagnostic.contains("operation not permitted")
        {
            errorMessage = "Codex 本地状态库无法访问，请检查 ~/.codex 目录权限。"
        } else {
            errorMessage = "Codex app-server 已提前退出（状态 \(status)）。"
        }
        finished = true
        lock.unlock()
        signal.signal()
    }

    func wait(timeout: TimeInterval) throws -> Data {
        guard signal.wait(timeout: .now() + timeout) == .success else {
            throw SubscriptionQuotaProviderError.timedOut("OpenAI Codex")
        }
        lock.lock()
        defer { lock.unlock() }
        if let response { return response }
        throw SubscriptionQuotaProviderError.processFailed(errorMessage ?? "Codex app-server 返回错误。")
    }
}

private struct AntigravityProcessInfo: Sendable {
    let pid: Int32
    let csrfToken: String?
    let extraEndpoints: [AntigravityEndpoint]
}

private struct AntigravityEndpoint: Sendable {
    let scheme: String
    let port: Int
    let csrfToken: String?
}

private enum AntigravityProcessDetector {
    static func runningProcesses() async throws -> [AntigravityProcessInfo] {
        let output = try await ProcessOutput.run(
            binary: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="]
        )
        var results: [AntigravityProcessInfo] = []
        for line in output.split(separator: "\n") {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let pid = Int32(parts[0])
            else { continue }
            let command = String(parts[1])
            let lower = command.lowercased()

            let isDesktopServer = lower.contains("language_server") &&
                (lower.contains("antigravity.app/") ||
                    lower.contains("antigravity ide.app/") ||
                    lower.contains("--app_data_dir antigravity") ||
                    lower.contains("--app_data_dir=antigravity"))
            let isCLI = lower.range(of: #"(^|/)agy(\s|$)"#, options: .regularExpression) != nil
            guard isDesktopServer || isCLI else { continue }

            let csrfToken = isCLI ? nil : extractFlag("--csrf_token", command: command)
            guard isCLI || csrfToken != nil else { continue }

            var extraEndpoints: [AntigravityEndpoint] = []
            if let portValue = extractFlag("--extension_server_port", command: command),
               let port = Int(portValue)
            {
                // The CSRF token is copied only into the in-memory localhost request header.
                // Do not persist or log it; Antigravity remains the owner of the login state.
                let extensionToken = extractFlag("--extension_server_csrf_token", command: command) ?? csrfToken
                extraEndpoints.append(
                    AntigravityEndpoint(scheme: "http", port: port, csrfToken: extensionToken)
                )
            }
            results.append(
                AntigravityProcessInfo(pid: pid, csrfToken: csrfToken, extraEndpoints: extraEndpoints)
            )
        }
        return results
    }

    static func listeningPorts(pid: Int32) async throws -> [Int] {
        let output = try await ProcessOutput.run(
            binary: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            allowNonZeroExit: true
        )
        let regex = try NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports = Set<Int>()
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match,
                  let valueRange = Range(match.range(at: 1), in: output),
                  let value = Int(output[valueRange])
            else { return }
            ports.insert(value)
        }
        return ports.sorted()
    }

    private static func extractFlag(_ flag: String, command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        guard let regex = try? NSRegularExpression(pattern: "\(escaped)[=\\s]+([^\\s]+)") else {
            return nil
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let valueRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[valueRange])
    }
}

private enum ProcessOutput {
    static func run(binary: String, arguments: [String], allowNonZeroExit: Bool = false) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard allowNonZeroExit || process.terminationStatus == 0 else {
                throw SubscriptionQuotaProviderError.processFailed("本地命令执行失败。")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

private final class AgyPTYSession: @unchecked Sendable {
    private let process: Process
    private let primaryHandle: FileHandle
    private let secondaryHandle: FileHandle

    var pid: Int32 { process.processIdentifier }

    init(binary: String) throws {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var windowSize = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &windowSize) == 0 else {
            throw SubscriptionQuotaProviderError.processFailed("无法创建 Antigravity PTY。")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        try process.run()

        primaryHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    func stop() {
        primaryHandle.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? primaryHandle.close()
        try? secondaryHandle.close()
    }
}

private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trustResult(challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trustResult(challenge)
    }

    private func trustResult(_ challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              ["127.0.0.1", "localhost"].contains(space.host.lowercased()),
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

private enum AntigravityHTTPClient {
    static func request(
        endpoint: AntigravityEndpoint,
        path: String,
        body: Data,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw SubscriptionQuotaProviderError.serviceUnavailable("Antigravity 本地地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token = endpoint.csrfToken {
            request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(
            configuration: configuration,
            delegate: LocalhostTrustDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (responseData, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200
        else {
            throw SubscriptionQuotaProviderError.serviceUnavailable("Antigravity 本地接口不可用。")
        }
        return responseData
    }
}
