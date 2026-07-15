import MiPopupCore
import SwiftUI
import UniformTypeIdentifiers

struct IslandView: View {
    @ObservedObject var model: IslandViewModel
    let onToggle: () -> Void
    let onHoverChange: (Bool) -> Void
    let onTabChange: (IslandTab) -> Void
    let onRefresh: () -> Void
    let onImport: () -> Void
    let onDropFile: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.expanded {
                Divider().overlay(Color.white.opacity(0.1))
                VStack(alignment: .leading, spacing: 8) {
                    tabBar

                    Group {
                        switch model.selectedTab {
                        case .quota:
                            quotaContent
                        case .models:
                            modelIntelligenceContent
                        }
                    }

                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(islandBackground)
        .clipShape(islandShape)
        .overlay(islandShape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.expanded)
        .onHover(perform: onHoverChange)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                if let url {
                    DispatchQueue.main.async { onDropFile(url) }
                }
            }
            return true
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            Group {
                if model.notchReservedWidth > 0 {
                    HStack(spacing: 0) {
                        statusContent(showTitle: model.expanded)
                            .padding(.leading, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(width: model.notchReservedWidth)
                        Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.trailing, 16)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: 10) {
                        statusContent(showTitle: true)
                        Spacer(minLength: 4)
                        Image(systemName: model.expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 16)
                }
            }
            .frame(height: model.expanded ? 38 : model.collapsedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusContent(showTitle: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.hasError ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: (model.hasError ? Color.red : Color.orange).opacity(0.7), radius: 5)
            if showTitle {
                Text(model.headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases) { tab in
                Button {
                    model.selectedTab = tab
                    onTabChange(tab)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                        Text(tab.title)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.selectedTab == tab ? .white : .white.opacity(0.48))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        model.selectedTab == tab ? Color.white.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var quotaContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.quotaStates) { state in
                    quotaCard(state)
                }
            }

            if model.eventCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge")
                    Text("Android 日志 \(model.eventCount) 条 · \(model.sourceText)")
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
            }
        }
    }

    @ViewBuilder
    private var modelIntelligenceContent: some View {
        if let snapshot = model.modelIntelligence, let strongest = snapshot.strongest {
            VStack(spacing: 8) {
                recommendationCard(strongest: strongest, balanced: snapshot.balanced)
                VStack(spacing: 5) {
                    ForEach(Array(snapshot.models.prefix(4).enumerated()), id: \.element.id) { index, record in
                        intelligenceRow(rank: index + 1, record: record, balanced: snapshot.balanced?.id == record.id)
                    }
                }
            }
        } else if model.isRefreshingModelIntelligence {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white.opacity(0.7))
                Text("正在读取最新模型智力水平…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 7) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text(model.modelIntelligenceError ?? "暂时无法读取模型智力数据")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recommendationCard(
        strongest: ModelIntelligenceRecord,
        balanced: ModelIntelligenceRecord?
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("当前最强")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                Text(shortModelName(strongest))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("通过 \(strongest.passed)/\(strongest.tasks) · 实测 $\(formatCost(strongest.costUSD))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatScore(strongest.score))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text("IQ 指数")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if let balanced, balanced.id != strongest.id {
                Divider().overlay(Color.white.opacity(0.08)).frame(height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("均衡推荐")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.blue)
                    Text(shortModelName(balanced))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text("IQ \(formatScore(balanced.score)) · $\(formatCost(balanced.costUSD))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                .frame(maxWidth: 110, alignment: .leading)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func intelligenceRow(rank: Int, record: ModelIntelligenceRecord, balanced: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 14)
            Text(shortModelName(record))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if balanced {
                Text("均衡")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.13), in: Capsule())
            }
            Spacer(minLength: 4)
            Text("\(record.passed)/\(record.tasks)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
            Text(formatScore(record.score))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(intelligenceColor(record.score))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.selectedTab == .models, let snapshot = model.modelIntelligence {
                Link(destination: snapshot.sourceURL) {
                    HStack(spacing: 4) {
                        Text("数据来自 Codex 雷达")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .help(snapshot.attribution)
            } else {
                Text(model.refreshDetail)
            }
            Spacer(minLength: 4)
            Button(action: onRefresh) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshingSelectedTab)

            if model.selectedTab == .quota {
                Button(action: onImport) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(6)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("导入 Android 通知日志")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
    }

    private func quotaCard(_ state: ProviderQuotaDisplayState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: state.id == .openAI ? "sparkles" : "g.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.id == .openAI ? Color.white : Color.blue)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.displayName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text(state.snapshot?.planName ?? state.snapshot?.productName ?? "订阅额度")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 2)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.65))
                }
            }

            if let snapshot = state.snapshot {
                ForEach(Array(snapshot.windows.prefix(4))) { window in
                    quotaWindow(window)
                }
                if state.errorMessage != nil {
                    Text("更新失败，显示上次结果")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            } else if let error = state.errorMessage {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.id == .openAI ? "正在读取 Codex 订阅额度…" : "正在读取 Google 订阅额度…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func quotaWindow(_ window: SubscriptionQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(quotaColor(window.remainingPercent))
                    .fixedSize()
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .progressViewStyle(.linear)
                .tint(quotaColor(window.remainingPercent))
                .controlSize(.mini)
                .frame(height: 5)
            if let resetsAt = window.resetsAt {
                Text(resetDescription(resetsAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaColor(_ remaining: Int) -> Color {
        switch remaining {
        case 0..<20: .red
        case 20..<50: .orange
        default: .green
        }
    }

    private func intelligenceColor(_ score: Double) -> Color {
        switch score {
        case 120...: .green
        case 90..<120: .orange
        default: .red
        }
    }

    private func shortModelName(_ record: ModelIntelligenceRecord) -> String {
        record.displayName.replacingOccurrences(of: "GPT-5.6 ", with: "")
    }

    private func formatScore(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    private func resetDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm 重置"
        } else if Calendar.current.isDateInTomorrow(date) {
            formatter.dateFormat = "明日 HH:mm 重置"
        } else {
            formatter.dateFormat = "M月d日 HH:mm 重置"
        }
        return formatter.string(from: date)
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: model.expanded ? 24 : 19,
            bottomTrailingRadius: model.expanded ? 24 : 19,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var islandBackground: some View {
        LinearGradient(
            colors: [Color.black, Color(red: 0.055, green: 0.059, blue: 0.07)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
