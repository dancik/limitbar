import AppKit
import SwiftUI
import Foundation

let args = CommandLine.arguments

// `LimitBar --probe` asks every CLI once and prints what limitbar would show, as JSON:
// state (ok / missing / untrusted / signedOut / failed), plan, windows. Nothing else of the account.
if args.contains("--probe") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    var all: [String: Snapshot] = [:]
    for v in Vendor.allCases {
        switch v {
        case .claude:
            var s: Snapshot
            let (bin, why) = Fetch.binary(.claude)
            if bin == nil { s = why! }
            else if let acct = Fetch.claudeAccount(), !acct.signedIn { s = .status(.claude, .signedOut) }
            else { s = Fetch.claudeFile() ?? Fetch.claudeUsage(); s.plan = Fetch.claudeAccount()?.plan ?? s.plan }
            all[v.rawValue] = s
        case .gemini: all[v.rawValue] = Fetch.gemini()
        case .codex: all[v.rawValue] = Fetch.codexFromServer()
        case .grok: all[v.rawValue] = Fetch.grok()
        }
    }
    print(String(decoding: (try? enc.encode(all)) ?? Data(), as: UTF8.self))
    exit(0)
}

// `LimitBar --usage [--home <dir>]` reads the token logs once, the way the Usage view does, and prints per
// vendor the totals per day and per model for the last 7 days as JSON. Model names and numbers only.
// `--home` reads the logs under another folder instead (tests/usage.sh), with its own index next to them.
if args.contains("--usage") {
    var home = CLI.home, cache = "\(Paths.cache)/usage.json"
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count {
        home = args[i + 1]
        cache = "\(home)/limitbar-usage-index.json"
    }
    guard let sum = UsageScanner(home: home, cacheFile: cache).scan() else {
        FileHandle.standardError.write(Data("limitbar: the usage read was interrupted\n".utf8)); exit(1)
    }
    var out: [String: Any] = ["days": sum.keys]
    for (v, u) in sum.vendors {
        guard u.reported else { out[v.rawValue] = ["reported": false]; continue }
        let t = u.total(sum.keys), today = u.total([sum.keys.last!])
        out[v.rawValue] = ["reported": true, "tokens": t.tokens, "calls": t.calls, "today": ["tokens": today.tokens, "calls": today.calls],
                           "perDay": sum.keys.map { u.tokens(on: $0) },
                           "models": Dictionary(uniqueKeysWithValues: u.models(sum.keys).map { ($0.model, ["tokens": $0.total.tokens, "calls": $0.total.calls]) })]
    }
    let d = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    print(String(decoding: d, as: UTF8.self))
    exit(0)
}

// `LimitBar --statusline` — optional Claude Code status line (see README). Claude Code pipes a JSON blob
// with the current rate limits to it on every refresh; we keep only the limits, in
// ~/Library/Caches/limitbar/claude-status.json, and print one short line, e.g. "5h 23% · 7d 41%".
// The menu bar then reads Claude's numbers for free instead of running `claude -p /usage`.
if args.contains("--statusline") {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let blob = Fetch.json(input) ?? [:]
    let rl = (blob["rate_limits"] ?? blob["rateLimits"]) as? [String: Any] ?? [:]
    var limits: [String: Any] = [:]
    for (kind, value) in rl {
        guard let w = value as? [String: Any] else { continue }
        var pct = ["used_percentage", "used_percent", "percentUsed", "percent", "utilization"].lazy
            .compactMap { w[$0] as? Double }.first
        if let p = pct, p <= 1, w["utilization"] != nil { pct = p * 100 }
        guard let p = percent(pct) else { continue }
        limits[kind] = ["percent": p, "resets_at": w["resets_at"] ?? w["resetsAt"] ?? w["reset_at"] ?? NSNull()]
    }
    if !limits.isEmpty,   // only a refresh that carries limits replaces the last good file
       let d = try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "limits": limits]) {
        Paths.write(d, to: Fetch.claudeFilePath)
    }
    let parts = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { k, label -> String? in
        guard let p = (limits[k] as? [String: Any])?["percent"] as? Double else { return nil }
        return "\(label) \(percentText(p))%"
    }
    let model = ((blob["model"] as? [String: Any])?["display_name"] as? String) ?? "Claude"
    print(([model] + parts).joined(separator: " · "))
    exit(0)
}

#if DEBUG
// `LimitBar --render-panel <out.png> [limits|usage] [today|week]` (debug builds only): the panel drawn
// offscreen from the cached limits and the real usage logs, for checking layout without the menu bar.
if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
    let ui = PanelState()
    ui.page = args.contains("limits") ? .limits : .usage
    ui.range = args.contains("today") ? .today : .week
    if let j = args.firstIndex(of: "--max-height"), j + 1 < args.count, let h = Double(args[j + 1]) { ui.maxHeight = h; ui.scrolls = true }
    let usage = UsageStore()
    usage.refresh()
    while usage.summary == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    let view = PanelView(store: Store(live: false), usage: usage, ui: ui, onQuit: {})
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.17, green: 0.17, blue: 0.18)))
        .environment(\.colorScheme, .dark)
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
