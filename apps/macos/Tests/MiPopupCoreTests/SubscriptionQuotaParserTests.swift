import Foundation
import Testing
@testable import MiPopupCore

struct SubscriptionQuotaParserTests {
    @Test
    func parsesCodexSubscriptionWindow() throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1784610708},"secondary":null,"planType":"plus"}}}"#.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 100)

        let snapshot = try CodexSubscriptionQuotaParser.parse(responseLine: data, fetchedAt: fetchedAt)

        #expect(snapshot.provider == .openAI)
        #expect(snapshot.planName == "ChatGPT Plus")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "每周")
        #expect(snapshot.windows[0].remainingPercent == 80)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_784_610_708))
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test
    func parsesAntigravityQuotaSummaryGroups() throws {
        let data = Data(#"""
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {"bucketId":"gemini-session","displayName":"Five-hour limit","remaining":{"case":"remainingFraction","value":0.72},"resetTime":"2026-07-14T18:00:00Z"},
                  {"bucketId":"gemini-weekly","displayName":"Weekly limit","remainingFraction":0.48}
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {"bucketId":"other-session","displayName":"Session","remainingFraction":0.91}
                ]
              }
            ]
          }
        }
        """#.utf8)

        let snapshot = try AntigravitySubscriptionQuotaParser.parseSummary(
            data,
            planName: "Google AI Pro",
            fetchedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(snapshot.provider == .google)
        #expect(snapshot.planName == "Google AI Pro")
        #expect(snapshot.windows.map(\.label) == [
            "Gemini · 5 小时",
            "Gemini · 每周",
        ])
        #expect(snapshot.windows.map(\.remainingPercent) == [72, 48])
    }

    @Test
    func fallsBackToAntigravityModelQuotas() throws {
        let data = Data(#"""
        {
          "userStatus": {
            "userTier": {"name":"Google AI Ultra"},
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {"label":"Gemini Pro","modelOrAlias":{"model":"gemini-3.1-pro"},"quotaInfo":{"remainingFraction":0.65,"resetTime":"2026-07-15T00:00:00Z"}},
                {"label":"Gemini Flash","modelOrAlias":{"model":"gemini-3.5-flash"},"quotaInfo":{"remainingFraction":0.82}},
                {"label":"Claude Sonnet","modelOrAlias":{"model":"claude-sonnet"},"quotaInfo":{"remainingFraction":0.44}}
              ]
            }
          }
        }
        """#.utf8)

        let snapshot = try AntigravitySubscriptionQuotaParser.parseUserStatus(data)

        #expect(snapshot.planName == "Google AI Ultra")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first { $0.label.hasPrefix("Gemini") }?.remainingPercent == 65)
        #expect(snapshot.windows.allSatisfy { !$0.label.contains("Claude") && !$0.label.contains("GPT") })
    }
}
