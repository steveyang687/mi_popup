import Foundation

public struct ModelIntelligenceRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let model: String
    public let reasoningEffort: String
    public let score: Double
    public let passed: Int
    public let tasks: Int
    public let status: String
    public let costUSD: Double?

    public init(
        id: String,
        displayName: String,
        model: String,
        reasoningEffort: String,
        score: Double,
        passed: Int,
        tasks: Int,
        status: String,
        costUSD: Double?
    ) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.score = score
        self.passed = passed
        self.tasks = tasks
        self.status = status
        self.costUSD = costUSD
    }
}

public struct ModelIntelligenceSnapshot: Sendable, Equatable {
    public let models: [ModelIntelligenceRecord]
    public let dataVersion: String
    public let attribution: String
    public let sourceURL: URL
    public let fetchedAt: Date

    public init(
        models: [ModelIntelligenceRecord],
        dataVersion: String,
        attribution: String,
        sourceURL: URL,
        fetchedAt: Date
    ) {
        self.models = models
        self.dataVersion = dataVersion
        self.attribution = attribution
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
    }

    public var strongest: ModelIntelligenceRecord? { models.first }

    public var balanced: ModelIntelligenceRecord? {
        guard let strongest else { return nil }
        let threshold = strongest.score * 0.9
        return models
            .filter { $0.score >= threshold && $0.costUSD != nil }
            .min { left, right in
                if left.costUSD == right.costUSD { return left.score > right.score }
                return (left.costUSD ?? .greatestFiniteMagnitude) < (right.costUSD ?? .greatestFiniteMagnitude)
            }
    }
}

public enum CodexRadarParseError: LocalizedError, Equatable {
    case invalidResponse
    case noModelData

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Codex Radar 返回了无法识别的数据。"
        case .noModelData: "Codex Radar 暂无可用的模型智力数据。"
        }
    }
}

public enum CodexRadarParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws
        -> ModelIntelligenceSnapshot
    {
        let summary: PublicSummary
        do {
            summary = try JSONDecoder().decode(PublicSummary.self, from: data)
        } catch {
            throw CodexRadarParseError.invalidResponse
        }

        guard let modelIQ = summary.modelIQ else { throw CodexRadarParseError.noModelData }
        var records: [ModelIntelligenceRecord] = []
        if let latest = modelIQ.latest {
            records.append(record(from: latest, label: nil))
        }
        records.append(contentsOf: modelIQ.comparisons.values.compactMap { comparison in
            comparison.latest.map { record(from: $0, label: comparison.label) }
        })

        var unique: [String: ModelIntelligenceRecord] = [:]
        for record in records {
            unique[record.id] = record
        }
        let sorted = unique.values.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return (left.costUSD ?? .greatestFiniteMagnitude) < (right.costUSD ?? .greatestFiniteMagnitude)
        }
        guard !sorted.isEmpty else { throw CodexRadarParseError.noModelData }

        let source = URL(string: summary.apiAccess?.requirements?.site ?? "https://codexradar.com/")
            ?? URL(string: "https://codexradar.com/")!
        return ModelIntelligenceSnapshot(
            models: sorted,
            dataVersion: sortedDataVersion(modelIQ: modelIQ),
            attribution: summary.apiAccess?.requirements?.attributionText
                ?? "数据来自 Codex 雷达 codexradar.com",
            sourceURL: source,
            fetchedAt: fetchedAt
        )
    }

    private static func record(from value: Latest, label: String?) -> ModelIntelligenceRecord {
        let effort = value.reasoningEffort ?? "max"
        let model = value.model ?? "codex"
        return ModelIntelligenceRecord(
            id: "\(model)-\(effort)",
            displayName: label ?? displayName(model: model, effort: effort),
            model: model,
            reasoningEffort: effort,
            score: value.score,
            passed: value.passed,
            tasks: value.tasks,
            status: value.status,
            costUSD: value.costUSD
        )
    }

    private static func displayName(model: String, effort: String) -> String {
        let name = model
            .replacingOccurrences(of: "gpt-", with: "GPT-")
            .replacingOccurrences(of: "-sol", with: " Sol")
            .replacingOccurrences(of: "-terra", with: " Terra")
            .replacingOccurrences(of: "-luna", with: " Luna")
        return "\(name) \(effort)"
    }

    private static func sortedDataVersion(modelIQ: ModelIQ) -> String {
        let dates = ([modelIQ.latest?.date] + modelIQ.comparisons.values.map { $0.latest?.date })
            .compactMap { $0 }
        return dates.sorted().last ?? "最新"
    }
}

private struct PublicSummary: Decodable {
    let modelIQ: ModelIQ?
    let apiAccess: APIAccess?

    enum CodingKeys: String, CodingKey {
        case modelIQ = "model_iq"
        case apiAccess = "api_access"
    }
}

private struct ModelIQ: Decodable {
    let latest: Latest?
    let comparisons: [String: Comparison]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try container.decodeIfPresent(Latest.self, forKey: .latest)
        comparisons = try container.decodeIfPresent([String: Comparison].self, forKey: .comparisons) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case latest
        case comparisons
    }
}

private struct Comparison: Decodable {
    let label: String
    let latest: Latest?
}

private struct Latest: Decodable {
    let date: String?
    let score: Double
    let status: String
    let passed: Int
    let tasks: Int
    let model: String?
    let reasoningEffort: String?
    let costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case score
        case status
        case passed
        case tasks
        case model
        case reasoningEffort = "reasoning_effort"
        case costUSD = "cost_usd"
    }
}

private struct APIAccess: Decodable {
    let requirements: Requirements?
}

private struct Requirements: Decodable {
    let attributionText: String?
    let site: String?

    enum CodingKeys: String, CodingKey {
        case attributionText = "attribution_text"
        case site
    }
}
