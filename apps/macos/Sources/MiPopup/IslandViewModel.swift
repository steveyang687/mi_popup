import Foundation
import MiPopupCore

struct ProviderQuotaDisplayState: Identifiable, Equatable {
    let id: SubscriptionProviderID
    var snapshot: SubscriptionQuotaSnapshot?
    var errorMessage: String?
    var isLoading: Bool

    var displayName: String { id.displayName }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case quota
    case models

    var id: Self { self }

    var title: String {
        switch self {
        case .quota: "额度"
        case .models: "模型推荐"
        }
    }

    var icon: String {
        switch self {
        case .quota: "gauge.with.dots.needle.33percent"
        case .models: "brain.head.profile"
        }
    }
}

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var expanded = false
    @Published var selectedTab = IslandTab.quota
    @Published var statusTitle = "正在读取 AI 额度"
    @Published var statusDetail = "拖入或导入 JSONL 开始预览"
    @Published var eventCount = 0
    @Published var sourceText = "尚无来源"
    @Published var latestText = "配送状态解析将在采样后启用"
    @Published var latestDelivery: DeliveryUpdate?
    @Published var deliverySourceText = "Android 通知日志"
    @Published var hasError = false
    @Published var notchReservedWidth: CGFloat = 0
    @Published var collapsedHeight: CGFloat = 38
    @Published var quotaStates = SubscriptionProviderID.allCases.map {
        ProviderQuotaDisplayState(id: $0, snapshot: nil, errorMessage: nil, isLoading: true)
    }
    @Published var isRefreshingQuotas = false
    @Published var quotaRefreshDetail = "正在连接本机订阅服务"
    @Published var modelIntelligence: ModelIntelligenceSnapshot?
    @Published var modelIntelligenceError: String?
    @Published var isRefreshingModelIntelligence = false

    var headerTitle: String {
        if let delivery = latestDelivery {
            if let eta = delivery.etaText {
                return "\(delivery.provider.displayName) · \(eta)送达"
            }
            return "\(delivery.provider.displayName) · \(delivery.stage.displayName)"
        }
        guard expanded, selectedTab == .models else { return statusTitle }
        if let strongest = modelIntelligence?.strongest {
            return "推荐 \(shortModelName(strongest)) · IQ \(formatScore(strongest.score))"
        }
        return isRefreshingModelIntelligence ? "正在读取模型智力" : "模型推荐暂不可用"
    }

    var refreshDetail: String {
        switch selectedTab {
        case .quota:
            quotaRefreshDetail
        case .models:
            if let snapshot = modelIntelligence {
                "Codex Radar · \(snapshot.dataVersion)"
            } else if isRefreshingModelIntelligence {
                "正在连接 Codex Radar"
            } else {
                "点击刷新后重试"
            }
        }
    }

    var isRefreshingSelectedTab: Bool {
        selectedTab == .quota ? isRefreshingQuotas : isRefreshingModelIntelligence
    }

    func beginQuotaRefresh() {
        isRefreshingQuotas = true
        quotaRefreshDetail = "正在刷新订阅额度"
        for index in quotaStates.indices {
            quotaStates[index].isLoading = true
            quotaStates[index].errorMessage = nil
        }
        updateQuotaHeader()
    }

    func apply(snapshot: SubscriptionQuotaSnapshot) {
        guard let index = quotaStates.firstIndex(where: { $0.id == snapshot.provider }) else { return }
        quotaStates[index].snapshot = snapshot
        quotaStates[index].errorMessage = nil
        quotaStates[index].isLoading = false
        updateQuotaHeader()
    }

    func applyQuotaError(provider: SubscriptionProviderID, message: String) {
        guard let index = quotaStates.firstIndex(where: { $0.id == provider }) else { return }
        quotaStates[index].errorMessage = message
        quotaStates[index].isLoading = false
        updateQuotaHeader()
    }

    func finishQuotaRefresh() {
        isRefreshingQuotas = false
        let successCount = quotaStates.count { $0.snapshot != nil }
        quotaRefreshDetail = successCount > 0
            ? "已更新 · 每 3 分钟自动刷新"
            : "暂时无法读取额度，点击重试"
        updateQuotaHeader()
    }

    func beginModelIntelligenceRefresh() {
        isRefreshingModelIntelligence = true
        modelIntelligenceError = nil
    }

    func apply(modelIntelligence snapshot: ModelIntelligenceSnapshot) {
        modelIntelligence = snapshot
        modelIntelligenceError = nil
        isRefreshingModelIntelligence = false
    }

    func applyModelIntelligenceError(_ message: String) {
        modelIntelligenceError = message
        isRefreshingModelIntelligence = false
    }

    func apply(summary: NotificationImportSummary) {
        eventCount = summary.events.count
        sourceText = summary.sourceNames.joined(separator: "、")
        let skippedSuffix = summary.skippedLineCount == 0 ? "" : "，跳过 \(summary.skippedLineCount) 行"
        statusDetail = "\(summary.fileName)\(skippedSuffix)"
        if let delivery = summary.latestDeliveryUpdate {
            latestDelivery = delivery
            deliverySourceText = "Android 通知日志"
            statusTitle = "\(delivery.provider.displayName) · \(delivery.stage.displayName)"
            latestText = deliveryDescription(delivery)
        } else {
            latestDelivery = nil
            statusTitle = "已载入 \(summary.events.count) 条通知"
            latestText = latestDescription(summary.latestEvent)
        }
        hasError = false
        expanded = true
    }

    @discardableResult
    func apply(delivery update: DeliveryUpdate, source: String) -> Bool {
        if let current = latestDelivery, current.capturedAt > update.capturedAt {
            return false
        }
        latestDelivery = update
        deliverySourceText = source
        statusTitle = "\(update.provider.displayName) · \(update.stage.displayName)"
        statusDetail = source
        latestText = deliveryDescription(update)
        selectedTab = .quota
        hasError = false
        return true
    }

    func apply(error: Error) {
        latestDelivery = nil
        statusTitle = "日志导入失败"
        statusDetail = error.localizedDescription
        latestText = "请确认文件来自 MiPopup Android 采集器"
        hasError = true
        expanded = true
    }

    @discardableResult
    func dismissLatestDelivery() -> String? {
        guard let delivery = latestDelivery else { return nil }
        latestDelivery = nil
        latestText = "当前配送状态已隐藏，等待下一次更新"
        updateQuotaHeader()
        return delivery.eventId
    }

    private func latestDescription(_ event: CapturedNotification?) -> String {
        guard let event else { return "没有可显示的通知内容" }
        let content = [event.title, event.text, event.bigText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? event.eventKind
        return "\(event.appName): \(content)"
    }

    private func deliveryDescription(_ update: DeliveryUpdate) -> String {
        var parts = [update.statusDetail ?? update.statusText]
        if let eta = update.etaText, !parts.contains(where: { $0.contains(eta) }) {
            parts.append("预计 \(eta)")
        }
        return parts.reduce(into: [String]()) { result, part in
            if result.last != part { result.append(part) }
        }
        .joined(separator: " · ")
    }

    private func updateQuotaHeader() {
        let percentages = quotaStates
            .compactMap(\.snapshot)
            .flatMap(\.windows)
            .map(\.remainingPercent)
        if let mostConstrained = percentages.min() {
            statusTitle = "AI 额度剩余 \(mostConstrained)%"
            hasError = false
        } else if isRefreshingQuotas {
            statusTitle = "正在读取 AI 额度"
            hasError = false
        } else {
            statusTitle = "AI 额度暂不可用"
            hasError = true
        }
    }

    private func shortModelName(_ record: ModelIntelligenceRecord) -> String {
        record.displayName.replacingOccurrences(of: "GPT-5.6 ", with: "")
    }

    private func formatScore(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
