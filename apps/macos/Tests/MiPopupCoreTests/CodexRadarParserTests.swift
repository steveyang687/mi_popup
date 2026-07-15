import Foundation
import Testing
@testable import MiPopupCore

struct CodexRadarParserTests {
    @Test func parsesAndRanksPublicModelIQSummary() throws {
        let data = Data(
            """
            {
              "api_access": {
                "requirements": {
                  "attribution_text": "数据来自 Codex 雷达 codexradar.com",
                  "site": "https://codexradar.com"
                }
              },
              "model_iq": {
                "latest": {
                  "date": "2026-07-15-am", "score": 120, "status": "green",
                  "passed": 8, "tasks": 10, "model": "gpt-5.6-sol",
                  "reasoning_effort": "max", "cost_usd": 60.1
                },
                "comparisons": {
                  "xhigh": {
                    "label": "GPT-5.6 Sol xhigh",
                    "latest": {
                      "date": "2026-07-15-am", "score": 150, "status": "green",
                      "passed": 10, "tasks": 10, "model": "gpt-5.6-sol",
                      "reasoning_effort": "xhigh", "cost_usd": 34.8
                    }
                  },
                  "medium": {
                    "label": "GPT-5.6 Sol medium",
                    "latest": {
                      "date": "2026-07-15-am", "score": 135, "status": "green",
                      "passed": 9, "tasks": 10, "model": "gpt-5.6-sol",
                      "reasoning_effort": "medium", "cost_usd": 17.8
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let snapshot = try CodexRadarParser.parse(data)

        #expect(snapshot.models.map(\.reasoningEffort) == ["xhigh", "medium", "max"])
        #expect(snapshot.strongest?.score == 150)
        #expect(snapshot.balanced?.reasoningEffort == "medium")
        #expect(snapshot.attribution == "数据来自 Codex 雷达 codexradar.com")
    }

    @Test func rejectsSummaryWithoutModelIQ() {
        #expect(throws: CodexRadarParseError.noModelData) {
            try CodexRadarParser.parse(Data("{\"schema_version\":\"2.0\"}".utf8))
        }
    }
}
