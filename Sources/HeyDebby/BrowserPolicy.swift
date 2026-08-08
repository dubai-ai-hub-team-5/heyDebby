import Foundation

enum BrowserPolicyDecision: Equatable {
    case allow
    case deny(String)

    var isDenied: Bool {
        if case .deny = self { return true }
        return false
    }
}

/// Executable boundary for browser automation. Prompt text tells the model what to do;
/// this policy decides what the Playwright process is actually allowed to do.
enum BrowserPolicy {
    private static let prefix = "mcp__playwright__"

    private static let observationTools: Set<String> = [
        "browser_snapshot", "browser_take_screenshot", "browser_console_messages",
        "browser_network_requests",
    ]

    private static let deniedTools: Set<String> = [
        "browser_evaluate", "browser_run_code", "browser_file_upload",
        "browser_handle_dialog", "browser_pdf_save", "browser_install",
    ]

    private static let sensitiveTerms = [
        "password", "passcode", "one-time", "one time", "otp", "pin",
        "card number", "credit card", "debit card", "security code", "cvv", "cvc",
        "captcha", "verification code", "authenticator code",
    ]

    private static let irreversibleTerms = [
        "submit", "pay", "purchase", "buy", "place order", "confirm", "authorize",
        "sign", "delete", "send", "publish", "book", "reserve", "complete application",
        "finish application",
    ]

    static func evaluate(toolName: String, input: [String: Any]) -> BrowserPolicyDecision {
        guard toolName.hasPrefix(prefix) else { return deny("Unknown browser tool") }
        let tool = String(toolName.dropFirst(prefix.count))
        if observationTools.contains(tool) { return .allow }
        if deniedTools.contains(tool) { return deny("This browser operation is not automated") }

        switch tool {
        case "browser_navigate":
            guard let raw = input["url"] as? String,
                  let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return deny("Only HTTP or HTTPS navigation is allowed") }
            return .allow

        case "browser_navigate_back":
            return .allow

        case "browser_resize":
            guard let width = integer(input["width"]), let height = integer(input["height"]),
                  width > 0, height > 0 else { return deny("Invalid browser size") }
            return .allow

        case "browser_wait_for":
            let keys = Set(input.keys)
            guard !keys.isEmpty, keys.isSubset(of: ["time", "text", "textGone"])
            else { return deny("Invalid wait request") }
            return .allow

        case "browser_tabs":
            guard let action = input["action"] as? String,
                  ["list", "new", "select"].contains(action) else {
                return deny("Closing browser tabs is left to the user")
            }
            if action == "select", integer(input["index"]) == nil {
                return deny("Invalid tab selection")
            }
            return .allow

        case "browser_hover":
            return validTarget(input) ? .allow : deny("Invalid browser target")

        case "browser_select_option":
            guard validTarget(input), safeLabel(input["element"]),
                  let values = input["values"] as? [String], !values.isEmpty
            else { return deny("Unsafe or invalid option selection") }
            return .allow

        case "browser_click":
            guard validTarget(input), safeLabel(input["element"]),
                  (input["button"] == nil || (input["button"] as? String) == "left"),
                  input["modifiers"] == nil else {
                return deny("This click must be completed by the user")
            }
            return .allow

        case "browser_type":
            guard validTarget(input), safeLabel(input["element"]),
                  let text = input["text"] as? String, safeValue(text),
                  (input["submit"] as? Bool) != true,
                  input["slowly"] == nil || input["slowly"] is Bool else {
                return deny("Sensitive or submitting input must be completed by the user")
            }
            return .allow

        case "browser_fill_form":
            guard let fields = input["fields"] as? [[String: Any]], !fields.isEmpty,
                  fields.allSatisfy(validField) else {
                return deny("Sensitive or invalid form fields must be completed by the user")
            }
            return .allow

        case "browser_press_key":
            guard let key = input["key"] as? String,
                  ["Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
                   "PageUp", "PageDown", "Home", "End", "Space"].contains(key) else {
                return deny("This key could submit or mutate the form")
            }
            return .allow

        default:
            return deny("Unknown browser operation")
        }
    }

    /// Claude hooks are JSON over stdio. Never include the rejected input in the result:
    /// it can contain passwords or identity data, and callers may log hook output.
    static func evaluateHookJSON(_ data: Data) -> Data {
        let decision: BrowserPolicyDecision
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["hook_event_name"] as? String == "PreToolUse",
           let tool = object["tool_name"] as? String,
           let input = object["tool_input"] as? [String: Any] {
            decision = evaluate(toolName: tool, input: input)
        } else {
            decision = deny("Malformed browser policy request")
        }

        let permission: String
        let reason: String
        switch decision {
        case .allow:
            permission = "allow"
            reason = "Allowed by HeyDebby browser policy"
        case .deny(let message):
            permission = "deny"
            reason = "\(message). Stop here and leave the visible browser open for the user."
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": permission,
                "permissionDecisionReason": reason,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    static func settingsJSON(executablePath: String) throws -> Data {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "mcp__playwright__.*",
                    "hooks": [[
                        "type": "command",
                        "command": "\(shellQuote(executablePath)) --browser-policy-hook",
                    ]],
                ]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    private static func deny(_ message: String) -> BrowserPolicyDecision { .deny(message) }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func validTarget(_ input: [String: Any]) -> Bool {
        guard let element = input["element"] as? String, !element.trimmingCharacters(in: .whitespaces).isEmpty,
              let ref = input["ref"] as? String, !ref.isEmpty else { return false }
        return true
    }

    private static func safeLabel(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        let normalized = value.lowercased()
        return !sensitiveTerms.contains(where: normalized.contains)
            && !irreversibleTerms.contains(where: normalized.contains)
    }

    private static func validField(_ field: [String: Any]) -> Bool {
        guard Set(field.keys) == ["name", "type", "ref", "value"],
              let name = field["name"] as? String, safeLabel(name),
              let type = field["type"] as? String,
              ["textbox", "checkbox", "radio", "combobox", "slider"].contains(type),
              let ref = field["ref"] as? String, !ref.isEmpty,
              let value = field["value"] as? String, safeValue(value) else { return false }
        return true
    }

    private static func safeValue(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        guard (13...19).contains(digits.count),
              value.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" })
        else { return true }
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 != 0
    }
}
