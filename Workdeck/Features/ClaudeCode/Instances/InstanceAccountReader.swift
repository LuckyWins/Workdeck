import Foundation

/// The signed-in account from Claude Code's `.claude.json`: its email and plan; nothing else is read (spec §4).
nonisolated enum InstanceAccountReader {
    struct Account: Equatable, Sendable {
        var email: String?
        /// "Pro", "Max 20x", "Team 5x"; `nil` when the fields are missing or unknown.
        var plan: String?
    }

    static func account(in file: URL) -> Account? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any] else { return nil }
        let email = (oauth["emailAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plan = planLabel(
            organizationType: oauth["organizationType"] as? String,
            rateLimitTier: oauth["userRateLimitTier"] as? String ?? oauth["organizationRateLimitTier"] as? String
        )
        return Account(email: email, plan: plan)
    }

    static func email(in file: URL) -> String? {
        account(in: file)?.email
    }

    /// Claude Code's undocumented plan fields as a short label; unknown values give no label.
    static func planLabel(organizationType: String?, rateLimitTier: String?) -> String? {
        let name: String
        switch organizationType {
        case "claude_pro": name = "Pro"
        case "claude_max": name = "Max"
        case "claude_team": name = "Team"
        case "claude_enterprise": name = "Enterprise"
        default: return nil
        }
        let multiplier = ["20x", "5x"].first { rateLimitTier?.hasSuffix("_max_\($0)") == true }
        return multiplier.map { "\(name) \($0)" } ?? name
    }
}
