import Foundation

public enum SubscriptionProviderID: String, CaseIterable, Sendable {
    case openAI
    case google

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .google: "Google"
        }
    }
}

public struct SubscriptionQuotaWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let remainingPercent: Int
    public let resetsAt: Date?

    public init(id: String, label: String, remainingPercent: Int, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public struct SubscriptionQuotaSnapshot: Sendable, Equatable {
    public let provider: SubscriptionProviderID
    public let productName: String
    public let planName: String?
    public let windows: [SubscriptionQuotaWindow]
    public let fetchedAt: Date

    public init(
        provider: SubscriptionProviderID,
        productName: String,
        planName: String?,
        windows: [SubscriptionQuotaWindow],
        fetchedAt: Date
    ) {
        self.provider = provider
        self.productName = productName
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

public enum SubscriptionQuotaParseError: LocalizedError, Equatable {
    case invalidResponse
    case noQuotaWindows

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "额度接口返回了无法识别的数据。"
        case .noQuotaWindows: "额度接口没有返回可显示的订阅额度。"
        }
    }
}

public enum CodexSubscriptionQuotaParser {
    public static func parse(responseLine data: Data, fetchedAt: Date = Date()) throws
        -> SubscriptionQuotaSnapshot
    {
        let response: CodexRateLimitResponse
        do {
            response = try JSONDecoder().decode(CodexRateLimitResponse.self, from: data)
        } catch {
            throw SubscriptionQuotaParseError.invalidResponse
        }

        guard let limits = response.result?.rateLimits else {
            throw SubscriptionQuotaParseError.invalidResponse
        }

        let windows = [limits.primary, limits.secondary]
            .compactMap { $0 }
            .enumerated()
            .map { index, window in
                SubscriptionQuotaWindow(
                    id: "codex-\(index)-\(window.windowDurationMins ?? 0)",
                    label: windowLabel(minutes: window.windowDurationMins, index: index),
                    remainingPercent: 100 - window.usedPercent,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }

        guard !windows.isEmpty else {
            throw SubscriptionQuotaParseError.noQuotaWindows
        }

        return SubscriptionQuotaSnapshot(
            provider: .openAI,
            productName: "Codex",
            planName: formatPlan(limits.planType),
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func windowLabel(minutes: Int?, index: Int) -> String {
        guard let minutes else { return index == 0 ? "主要额度" : "次要额度" }
        switch minutes {
        case 280...320: return "5 小时"
        case 9_000...11_000: return "每周"
        case 1_400...1_500: return "每天"
        default:
            if minutes.isMultiple(of: 60) {
                return "\(minutes / 60) 小时"
            }
            return "\(minutes) 分钟"
        }
    }

    private static func formatPlan(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "business": return "ChatGPT Business"
        case "enterprise": return "ChatGPT Enterprise"
        case "edu": return "ChatGPT Edu"
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public enum AntigravitySubscriptionQuotaParser {
    public static func parseSummary(
        _ data: Data,
        planName: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> SubscriptionQuotaSnapshot {
        let response: AntigravityQuotaSummaryResponse
        do {
            response = try JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: data)
        } catch {
            throw SubscriptionQuotaParseError.invalidResponse
        }

        let payload = response.response ?? response.summary ?? response.rootPayload
        guard let payload else { throw SubscriptionQuotaParseError.invalidResponse }

        let windows: [SubscriptionQuotaWindow] = payload.groups.flatMap { group -> [SubscriptionQuotaWindow] in
            guard isGeminiGroup(group.displayName) else { return [] }
            return group.buckets.compactMap { bucket -> SubscriptionQuotaWindow? in
                guard bucket.disabled != true,
                      let fraction = bucket.remainingFraction ?? bucket.remaining?.remainingFraction
                else { return nil }
                let groupLabel = normalizedGroupName(group.displayName)
                let bucketLabel = normalizedBucketName(bucket.displayName ?? bucket.bucketId)
                return SubscriptionQuotaWindow(
                    id: "antigravity-\(bucket.bucketId)",
                    label: "\(groupLabel) · \(bucketLabel)",
                    remainingPercent: Int((fraction * 100).rounded()),
                    resetsAt: parseDate(bucket.resetTime)
                )
            }
        }

        guard !windows.isEmpty else { throw SubscriptionQuotaParseError.noQuotaWindows }
        return snapshot(planName: planName, windows: windows, fetchedAt: fetchedAt)
    }

    public static func planName(fromUserStatus data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data),
              let status = response.userStatus
        else { return nil }
        return firstNonEmpty([
            status.userTier?.name,
            status.planStatus?.planInfo?.planDisplayName,
            status.planStatus?.planInfo?.displayName,
            status.planStatus?.planInfo?.productName,
            status.planStatus?.planInfo?.planName,
            status.planStatus?.planInfo?.planShortName,
        ])
    }

    public static func parseUserStatus(_ data: Data, fetchedAt: Date = Date()) throws
        -> SubscriptionQuotaSnapshot
    {
        let response: AntigravityUserStatusResponse
        do {
            response = try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)
        } catch {
            throw SubscriptionQuotaParseError.invalidResponse
        }
        guard let status = response.userStatus else {
            throw SubscriptionQuotaParseError.invalidResponse
        }

        struct WorstWindow {
            let fraction: Double
            let resetTime: String?
        }
        var worstByGroup: [String: WorstWindow] = [:]
        for config in status.cascadeModelConfigData?.clientModelConfigs ?? [] {
            let identity = config.label + " " + config.modelOrAlias.model
            guard isGeminiGroup(identity) else { continue }
            guard let fraction = config.quotaInfo?.remainingFraction else { continue }
            let group = normalizedGroupName(identity)
            if let current = worstByGroup[group], fraction >= current.fraction { continue }
            worstByGroup[group] = WorstWindow(
                fraction: fraction,
                resetTime: config.quotaInfo?.resetTime
            )
        }

        let windows = worstByGroup.keys.sorted().compactMap { group -> SubscriptionQuotaWindow? in
            guard let window = worstByGroup[group] else { return nil }
            return SubscriptionQuotaWindow(
                id: "antigravity-legacy-\(group)",
                label: "\(group) · 当前周期",
                remainingPercent: Int((window.fraction * 100).rounded()),
                resetsAt: parseDate(window.resetTime)
            )
        }
        guard !windows.isEmpty else { throw SubscriptionQuotaParseError.noQuotaWindows }

        return snapshot(
            planName: planName(fromUserStatus: data),
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func snapshot(
        planName: String?,
        windows: [SubscriptionQuotaWindow],
        fetchedAt: Date
    ) -> SubscriptionQuotaSnapshot {
        SubscriptionQuotaSnapshot(
            provider: .google,
            productName: "Antigravity",
            planName: planName,
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private static func normalizedGroupName(_ value: String?) -> String {
        let lower = value?.lowercased() ?? ""
        if lower.contains("gemini") { return "Gemini" }
        return firstNonEmpty([value]) ?? "模型"
    }

    private static func isGeminiGroup(_ value: String?) -> Bool {
        value?.localizedCaseInsensitiveContains("gemini") == true
    }

    private static func normalizedBucketName(_ value: String?) -> String {
        let lower = value?.lowercased() ?? ""
        if lower.contains("week") { return "每周" }
        if lower.contains("five") || lower.contains("5h") || lower.contains("session") { return "5 小时" }
        return firstNonEmpty([value]) ?? "额度"
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}

private struct CodexRateLimitResponse: Decodable {
    let result: Result?

    struct Result: Decodable {
        let rateLimits: RateLimits?
    }

    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    struct Window: Decodable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int64?
    }
}

private struct AntigravityQuotaSummaryResponse: Decodable {
    let response: Payload?
    let summary: Payload?
    let description: String?
    let groups: [Group]?

    var rootPayload: Payload? {
        groups.map { Payload(description: description, groups: $0) }
    }

    struct Payload: Decodable {
        let description: String?
        let groups: [Group]
    }

    struct Group: Decodable {
        let displayName: String?
        let buckets: [Bucket]
    }

    struct Bucket: Decodable {
        let bucketId: String
        let displayName: String?
        let disabled: Bool?
        let remainingFraction: Double?
        let remaining: Remaining?
        let resetTime: String?
    }

    struct Remaining: Decodable {
        let remainingFraction: Double?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction
            case oneofCase = "case"
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                remainingFraction = value
            } else if try container.decodeIfPresent(String.self, forKey: .oneofCase) == "remainingFraction" {
                remainingFraction = try container.decodeIfPresent(Double.self, forKey: .value)
            } else {
                remainingFraction = nil
            }
        }
    }
}

private struct AntigravityUserStatusResponse: Decodable {
    let userStatus: UserStatus?

    struct UserStatus: Decodable {
        let planStatus: PlanStatus?
        let userTier: UserTier?
        let cascadeModelConfigData: ModelConfigData?
    }

    struct UserTier: Decodable {
        let name: String?
    }

    struct PlanStatus: Decodable {
        let planInfo: PlanInfo?
    }

    struct PlanInfo: Decodable {
        let planName: String?
        let planDisplayName: String?
        let displayName: String?
        let productName: String?
        let planShortName: String?
    }

    struct ModelConfigData: Decodable {
        let clientModelConfigs: [ModelConfig]
    }

    struct ModelConfig: Decodable {
        let label: String
        let modelOrAlias: ModelAlias
        let quotaInfo: QuotaInfo?
    }

    struct ModelAlias: Decodable {
        let model: String
    }

    struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }
}
