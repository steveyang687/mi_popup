import Foundation

enum IslandDensity: String, CaseIterable {
    case minimal, compact, full

    var title: String {
        switch self {
        case .minimal: "极简 · 仅状态点"
        case .compact: "紧凑 · 配送摘要"
        case .full: "完整 · 详细状态"
        }
    }
}

enum IslandPosition: String, CaseIterable {
    case center, left, custom

    var title: String {
        switch self {
        case .center: "居中 · 刘海位置"
        case .left: "刘海左侧"
        case .custom: "自定义 · Command 拖动"
        }
    }
}

enum IslandActivation: String, CaseIterable {
    case hover, deliberate, click

    var title: String {
        switch self {
        case .hover: "悬停 0.6 秒"
        case .deliberate: "悬停 1 秒"
        case .click: "仅点击展开"
        }
    }

    var delay: Duration {
        self == .deliberate ? .seconds(1) : .milliseconds(600)
    }
}
