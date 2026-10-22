import Foundation

enum Vendor: String, CaseIterable, Codable {
    case claude, gemini, codex, grok

    var name: String { ["claude": "Claude", "gemini": "Gemini", "codex": "Codex", "grok": "Grok"][rawValue]! }
    /// The CLI limitbar asks, and what the panel suggests when it is missing or signed out.
    var cli: String { ["claude": "claude", "gemini": "agy", "codex": "codex", "grok": "grok"][rawValue]! }
    var product: String {
        ["claude": "Claude Code", "gemini": "Google Antigravity CLI", "codex": "Codex CLI", "grok": "Grok Build"][rawValue]!
    }
    var loginHint: String {
        ["claude": "run `claude`, then /login", "gemini": "run `agy` once and sign in",
         "codex": "run `codex login`", "grok": "run `grok login`"][rawValue]!
    }
    var mark: String { ["claude": "claude", "gemini": "gemini", "codex": "openai", "grok": "xai"][rawValue]! }
}

/// Why a vendor shows no numbers. `ok` = the CLI answered.
enum VendorState: String, Codable {
    case ok
    case missing        // CLI not found: hidden from the menu bar, listed in the panel
    case untrusted      // found, but owned by another account or group/world-writable: never run
    case signedOut      // the CLI says nobody is signed in
    case failed         // it ran and did not give limits (timeout, error, changed format)
}

/// One limit window as the vendor reports it. `used` is percent USED, 0–100.
struct Window: Codable, Equatable {
    var label: String            // "5-hour", "Week", "Weekly credits", …
    var short: String            // "5h" or "w" — the menu bar adds a superscript w for weekly windows
    var used: Double?
    var resetsAt: Date?
    /// Only confirmed window lengths get pacing. Optional so older caches still decode.
    var durationMinutes: Int? = nil

    /// Even spending across a fixed reset window, not a prediction of future activity.
    func pacing(at now: Date = Date()) -> Pacing? {
        guard let minutes = durationMinutes, minutes == 300 || minutes == 10_080,
              let used = used, used.isFinite, (0...100).contains(used),
              let reset = resetsAt else { return nil }
        let duration = Double(minutes) * 60
        let remaining = reset.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0, remaining <= duration else { return nil }
        return Pacing(elapsedFraction: 1 - remaining / duration, used: used, remaining: remaining)
    }

    /// The reset time has passed since we read it: the old percent is obsolete, not "0 %".
    var resetPassed: Bool { (resetsAt.map { $0 < Date() }) ?? false }
}

struct Pacing {
    let elapsedFraction: Double
    let used: Double
    let remaining: TimeInterval

    /// Percentage points of allowance used above/below the elapsed share of the window.
    var difference: Double { used - elapsedFraction * 100 }
    var roundedDifference: Int { Int(difference.rounded()) }
    var isOverPace: Bool { roundedDifference > 0 }
    var summary: String {
        let delta = roundedDifference
        if delta == 0 { return "On pace" }
        return "\(abs(delta)) pp \(delta > 0 ? "over" : "under") pace"
    }
    var remainingText: String {
        let minutes = Int(ceil(remaining / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h left" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        return "\(minutes)m left"
    }
}

struct Snapshot: Codable, Equatable {
    var vendor: Vendor
    var state: VendorState = .ok
    var plan: String = ""         // from the CLI's own answer: "Max", "ChatGPT Plus", "X Premium+"
    var bar: Window?              // the window the menu bar shows for this vendor
    var windows: [Window] = []    // everything shown in the panel, bar window first
    var notes: [String] = []      // e.g. "2 free full resets · next expires Fri 3 Jan"
    var measuredAt: Date?         // when the vendor's numbers were taken (not when we looked)
    var error: String?            // last failure, shown dimmed; previous numbers are kept

    /// Any window of this vendor at ≥ 90 % other than the one in the bar → "!" next to the digit.
    var otherHot: Bool {
        windows.contains { $0 != bar && !$0.resetPassed && ($0.used ?? 0) >= 90 }
    }

    static func status(_ v: Vendor, _ state: VendorState, _ error: String? = nil) -> Snapshot {
        Snapshot(vendor: v, state: state, error: error)
    }
}

/// A percentage from a CLI is only used when it is a finite number in 0…100.
func percent(_ any: Any?) -> Double? {
    let v: Double?
    switch any {
    case let d as Double: v = d
    case let i as Int: v = Double(i)
    case let n as NSNumber: v = n.doubleValue
    default: v = nil
    }
    guard let x = v, x.isFinite, x >= 0, x <= 100 else { return nil }
    return x
}

/// Bar digit: rounded, but 99.6 % must never read as 100 %.
func percentText(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    let r = v.rounded()
    return String(Int(r >= 100 && v < 100 ? 99 : r))
}
