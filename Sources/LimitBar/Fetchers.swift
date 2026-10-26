import Foundation

/// Where each vendor's limits come from. Error texts are fixed strings of ours — a CLI's own error message
/// is only matched against, never stored or shown, so nothing it says can end up in the cache.
/// Every source is the vendor's own CLI (or a file limitbar's own
/// statusline helper writes), so sign-in and token refresh stay inside the CLI — limitbar never opens a
/// credential file, cookie or keychain item, and keeps nothing of an account but the plan name.
enum Fetch {
    static let home = CLI.home
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func date(_ any: Any?) -> Date? {
        if let n = any as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let n = any as? Int { return Date(timeIntervalSince1970: Double(n)) }
        if let s = any as? String {
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
                ?? ISO8601DateFormatter().date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
        }
        return nil
    }
    static func json(_ d: Data?) -> [String: Any]? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    static func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

    /// The CLI for a vendor, or the snapshot that explains why there is none.
    static func binary(_ v: Vendor) -> (String?, Snapshot?) {
        switch CLI.find(v.cli) {
        case .ok(let p):
            guard CLI.launch(p) != nil else {
                return (nil, .status(v, .untrusted, "\(v.cli)'s interpreter could be replaced by another account — not run"))
            }
            return (p, nil)
        case .missing: return (nil, .status(v, .missing))
        case .untrusted: return (nil, .status(v, .untrusted, "\(v.cli) could be replaced by another account — not run"))
        }
    }

    static func signedOutText(_ s: String) -> Bool {
        let t = s.lowercased()
        return ["not logged in", "not signed in", "please log in", "please sign in", "login required",
                "unauthenticated", "unauthorized", "no credentials", "not authenticated", "authentication required"].contains { t.contains($0) }
    }

    // MARK: Claude — the statusline file (free) first; `claude -p /usage` only when it is stale.

    /// Written by `LimitBar --statusline` when the user opted in (see README). Holds only the limits.
    static let claudeFilePath = "\(Paths.cache)/claude-status.json"

    static func claudeFile() -> Snapshot? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: claudeFilePath)),
              let o = json(d), let limits = o["limits"] as? [String: Any] else { return nil }
        func win(_ k: String, _ label: String, _ short: String) -> Window? {
            guard let w = limits[k] as? [String: Any], let p = percent(w["percent"]) else { return nil }
            return Window(label: label, short: short, used: p, resetsAt: date(w["resets_at"]))
        }
        let five = win("five_hour", "5-hour", "5h"), week = win("seven_day", "Week", "w")
        guard five != nil || week != nil else { return nil }
        return Snapshot(vendor: .claude, bar: five ?? week, windows: [five, week].compactMap { $0 }, measuredAt: date(o["at"]))
    }

    /// Isolation for every `claude` call: user/project settings files ignored (so no hook from them),
    /// hooks off, no MCP server, no transcript saved, private empty cwd, allowlisted environment. `/usage`
    /// makes no model call. Verified by tests/claude-canary.sh: hooks and MCP servers fire without these
    /// flags and stay silent with them.
    static let claudeIsolation = ["--restricted", "--strict-mcp-config", "--no-session-persistence",
                                  "--settings", #"{"disableAllHooks":true,"language":"English"}"#]

    /// `claude -p "/usage"` — no model call, but a full CLI start (~3 s CPU). Called at most every 20 min.
    static func claudeUsage() -> Snapshot {
        let (b, why) = binary(.claude)
        guard let bin = b else { return why! }
        guard let out = CLI.run(bin, ["-p", "/usage", "--output-format", "json", "--max-turns", "1"] + claudeIsolation,
                                timeout: 40) else { return .status(.claude, .failed, "claude timed out") }
        guard let o = json(out.data), let text = o["result"] as? String else {
            let raw = String(decoding: out.data.prefix(2000), as: UTF8.self)
            return .status(.claude, signedOutText(raw) ? .signedOut : .failed, signedOutText(raw) ? nil : "claude gave no usage (exit \(out.code))")
        }
        if signedOutText(text) { return .status(.claude, .signedOut) }
        func line(_ title: String, _ label: String, _ short: String) -> Window? {
            let pat = NSRegularExpression.escapedPattern(for: title) + #":\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+([^(\n]+?)\s*\(([^)]+)\))?"#
            guard let re = try? NSRegularExpression(pattern: pat),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r1 = Range(m.range(at: 1), in: text), let used = percent(Double(text[r1])) else { return nil }
            var reset: Date?
            if let r2 = Range(m.range(at: 2), in: text), let r3 = Range(m.range(at: 3), in: text) {
                reset = parseClaudeReset(String(text[r2]), tz: String(text[r3]))
            }
            return Window(label: label, short: short, used: used, resetsAt: reset)
        }
        let five = line("Current session", "5-hour", "5h")
        let week = line("Current week (all models)", "Week", "w")
        // Per-model weekly lines ("Current week (Opus)", …) appear on some plans; show each one.
        var extra: [Window] = []
        if let re = try? NSRegularExpression(pattern: #"Current week \(([^)]+)\)"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let model = String(text[r])
                if model != "all models", let w = line("Current week (\(model))", "\(model) week", "w") { extra.append(w) }
            }
        }
        guard five != nil || week != nil else { return .status(.claude, .failed, "no plan limits in claude /usage (API key account?)") }
        return Snapshot(vendor: .claude, bar: five ?? week, windows: [five, week].compactMap { $0 } + extra, measuredAt: Date())
    }

    /// "Oct 21 at 9:10pm" / "Oct 24 at 11pm" in the given zone; the year is the next occurrence.
    static func parseClaudeReset(_ s: String, tz: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz) ?? .current
        let year = Calendar.current.component(.year, from: Date())
        let clean = s.replacingOccurrences(of: " at ", with: " ").uppercased()
        for fmt in ["MMM d h:mma yyyy", "MMM d ha yyyy", "MMM d H:mm yyyy"] {
            f.dateFormat = fmt
            for y in [year, year + 1] {
                if let d = f.date(from: "\(clean) \(y)"), d > Date().addingTimeInterval(-86400) { return d }
            }
        }
        return nil
    }

    /// `claude auth status --json`: whether someone is signed in, and the plan ("Max", "Pro").
    /// Its answer also carries the email and organisation; those are never kept or shown.
    static func claudeAccount() -> (signedIn: Bool, plan: String)? {
        guard case .ok(let bin) = CLI.find("claude"),
              let out = CLI.run(bin, ["auth", "status", "--json"], timeout: 20), let o = json(out.data) else { return nil }
        let plan = (o["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        return ((o["loggedIn"] as? Bool) == true, plan)
    }

    // MARK: Gemini — Antigravity CLI `agy -p /quota`: Google's own per-group buckets, zero tokens.

    /// The bar shows the most-used bucket across the Gemini model groups (the one that stops you first);
    /// the panel lists that group always and every other one only once used (Claude/GPT inside Antigravity too).
    static func gemini() -> Snapshot {
        let (b, why) = binary(.gemini)
        guard let bin = b else { return why! }
        guard let box = Sandbox.wrap(.gemini, bin, ["-p", "/quota", "--output-format", "json", "--print-timeout", "30s"]) else {
            return .status(.gemini, .failed, "sandbox unavailable — agy not run")
        }
        guard let out = CLI.run(box.argv[0], Array(box.argv.dropFirst()), timeout: 40, extraEnv: box.env, envFor: box.binary)
        else { return .status(.gemini, .failed, "agy timed out") }
        guard let o = json(out.data), let data = (o["command"] as? [String: Any])?["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]] else {
            let raw = String(decoding: out.data.prefix(2000), as: UTF8.self)
            return .status(.gemini, signedOutText(raw) ? .signedOut : .failed, signedOutText(raw) ? nil : "agy gave no quota (exit \(out.code))")
        }
        var gemini: [Window] = [], other: [Window] = []
        for g in groups {
            let name = g["name"] as? String ?? "Models"
            for bucket in g["buckets"] as? [[String: Any]] ?? [] {
                guard let rf = bucket["remaining_fraction"] as? Double, rf.isFinite, rf >= 0, rf <= 1 else { continue }
                let five = (bucket["window"] as? String) == "5h"
                let w = Window(label: name, short: five ? "5h" : "w",
                               used: (1 - rf) * 100, resetsAt: date(bucket["reset_time"]))
                if name.localizedCaseInsensitiveContains("Gemini") { gemini.append(w) } else if rf < 1 { other.append(w) }
            }
        }
        guard !gemini.isEmpty else { return .status(.gemini, .failed, "no Gemini quota in agy's answer") }
        // Most used first; on a tie agy's own order stands (Swift's sort is not stable, so sort the indices).
        gemini = gemini.indices.sorted { (gemini[$0].used ?? 0, -$0) > (gemini[$1].used ?? 0, -$1) }.map { gemini[$0] }
        // A Gemini group nobody uses (0 %) is noise next to the one that binds: the panel lists the bar
        // window always and every other one only once it has been used, like the non-Gemini groups.
        let shown = [gemini[0]] + gemini.dropFirst().filter { ($0.used ?? 0) > 0 }
        return Snapshot(vendor: .gemini, bar: gemini.first, windows: shown + other, measuredAt: Date())
    }

    // MARK: Codex — the CLI writes rate_limits into its own session logs for free; app-server when old.

    static func codexFromLogs() -> Snapshot? {
        let fm = FileManager.default
        let root = "\(home)/.codex/sessions"
        let cal = Calendar.current
        var files: [(String, Date)] = []
        for back in 0..<2 {      // today and yesterday are enough: the 5-hour window is all we need fresh
            let d = cal.date(byAdding: .day, value: -back, to: Date())!
            let dir = String(format: "%@/%04d/%02d/%02d", root, cal.component(.year, from: d), cal.component(.month, from: d), cal.component(.day, from: d))
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let p = "\(dir)/\(f)"; if let m = mtime(p) { files.append((p, m)) }
            }
        }
        guard let newest = files.max(by: { $0.1 < $1.1 }), let h = FileHandle(forReadingAtPath: newest.0) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let o = json(Data(line.utf8)), let p = o["payload"] as? [String: Any],
                  let rl = p["rate_limits"] as? [String: Any] else { continue }
            return codexSnapshot(rl, used: "used_percent", reset: "resets_at", measured: date(o["timestamp"]))
        }
        return nil
    }

    static func codexFromServer() -> Snapshot {
        let (b, why) = binary(.codex)
        guard let bin = b else { return why! }
        guard let box = Sandbox.wrap(.codex, bin, ["app-server"]) else {
            return .status(.codex, .failed, "sandbox unavailable — codex not run")
        }
        switch CLI.rpc(box.argv, binary: box.binary, initialize: ["clientInfo": ["name": "limitbar", "version": "1"]],
                       notify: "initialized", method: "account/rateLimits/read", extraEnv: box.env) {
        case .failed(let e):
            if let lbox = Sandbox.wrap(.codex, bin, ["login", "status"]),
               let out = CLI.run(lbox.argv[0], Array(lbox.argv.dropFirst()), timeout: 15, extraEnv: lbox.env, envFor: lbox.binary),
               signedOutText(String(decoding: out.data, as: UTF8.self)) { return .status(.codex, .signedOut) }
            return .status(.codex, signedOutText(e) ? .signedOut : .failed, signedOutText(e) ? nil : "codex gave no limits")
        case .ok(let r):
            guard let rl = r["rateLimits"] as? [String: Any] else { return .status(.codex, .failed, "codex gave no limits") }
            var s = codexSnapshot(rl, used: "usedPercent", reset: "resetsAt", measured: Date())
            let credits = ((r["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]] ?? [])
                .filter { ($0["status"] as? String) == "available" }
                .compactMap { date($0["expiresAt"]) }.sorted()
            if let next = credits.first {
                s.notes.append("\(credits.count) free full reset\(credits.count == 1 ? "" : "s") · next expires \(relativeDay(next))")
            }
            return s
        }
    }

    private static func codexSnapshot(_ rl: [String: Any], used: String, reset: String, measured: Date?) -> Snapshot {
        func win(_ k: String) -> Window? {
            guard let w = rl[k] as? [String: Any], let u = percent(w[used]) else { return nil }
            let mins = (w["window_minutes"] ?? w["windowDurationMins"]) as? Int ?? 0
            return Window(label: mins <= 300 ? "5-hour" : "Week", short: mins <= 300 ? "5h" : "w", used: u, resetsAt: date(w[reset]))
        }
        let five = win("primary"), week = win("secondary")
        let plan = ((rl["plan_type"] ?? rl["planType"]) as? String).map { "ChatGPT " + $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        return Snapshot(vendor: .codex, plan: plan, bar: five ?? week, windows: [five, week].compactMap { $0 }, measuredAt: measured)
    }

    // MARK: Grok — Grok Build's ACP extension `_x.ai/billing` (what its /usage screen reads).

    static func grok() -> Snapshot {
        let (b, why) = binary(.grok)
        guard let link = b else { return why! }
        guard let box = Sandbox.wrap(.grok, link, ["agent", "stdio"]) else {
            return .status(.grok, .failed, "sandbox unavailable — grok not run")
        }
        switch CLI.rpc(box.argv, binary: box.binary, initialize: ["protocolVersion": 1, "clientCapabilities": [String: Any]()],
                       method: "_x.ai/billing",
                       extraEnv: box.env.merging(["GROK_SUBAGENTS": "0", "GROK_MEMORY": "0", "GROK_WEB_FETCH": "0"]) { $1 }) {
        case .failed(let e):
            return .status(.grok, signedOutText(e) ? .signedOut : .failed, signedOutText(e) ? nil : "grok gave no billing answer")
        case .ok(let r):
            guard let c = r["config"] as? [String: Any] else { return .status(.grok, .failed, "grok gave no billing") }
            let period = c["currentPeriod"] as? [String: Any]
            let weekly = (period?["type"] as? String)?.contains("WEEKLY") ?? true
            // creditUsagePercent is a 0–100 percentage (1.0 = 1 %).
            let w = Window(label: weekly ? "Weekly credits" : "Credits", short: weekly ? "w" : "",
                           used: percent(c["creditUsagePercent"]), resetsAt: date(period?["end"] ?? c["billingPeriodEnd"]))
            return Snapshot(vendor: .grok, plan: (r["subscription_tier"] as? String) ?? "", bar: w, windows: [w],
                            measuredAt: Date())
        }
    }

    static func relativeDay(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today " + f.string(from: d) }
        if cal.isDateInTomorrow(d) { return "tomorrow " + f.string(from: d) }
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }
}

enum Paths {
    /// ~/Library/Caches/limitbar — 0700; everything limitbar writes lives here.
    static let cache: String = {
        let d = "\(CLI.home)/Library/Caches/limitbar"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(d, 0o700)
        return d
    }()

    /// Atomic write, readable only by this user.
    static func write(_ data: Data, to path: String) {
        let tmp = path + ".\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp, path) != 0 { unlink(tmp) }
    }
}

/// The kernel sandbox (Resources/cli.sb, applied with sandbox-exec) every CLI except `claude` runs in
/// the CLI may start only programs from its own install folder, may read and write nothing in your home
/// folder but its own state folder, and nothing in other users' folders, mounted volumes or shared temp.
/// So no MCP server, hook or plugin configured anywhere can start, and nothing else of yours is readable.
/// `claude` runs with its own isolation flags instead (Fetch.claudeIsolation, tests/claude-canary.sh).
enum Sandbox {
    struct Box { let argv: [String]; let binary: String; let env: [String: String] }

    static func real(_ p: String) -> String? {
        guard let rp = realpath(p, nil) else { return nil }
        defer { free(rp) }
        return String(cString: rp)
    }

    /// nil when the profile or sandbox-exec is missing — then the CLI is not run at all.
    static func wrap(_ v: Vendor, _ link: String, _ args: [String]) -> Box? {
        guard let profile = Bundle.main.url(forResource: "cli", withExtension: "sb")?.path,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              let bin = real(link), let tmp = real(CLI.workDir), let home = real(CLI.home) else { return nil }
        let dir = (bin as NSString).deletingLastPathComponent
        let state: String, execDir: String
        switch v {
        case .grok: state = "\(home)/.grok"; execDir = dir
        case .codex:
            // Homebrew: <Caskroom>/codex/<version>/bin/codex → the version folder. npm: <node_modules>/@openai/codex/
            // bin/codex.js starts a native binary from the sibling package @openai/codex-<platform> → the whole
            // @openai scope folder.
            state = "\(home)/.codex"
            let pkg = (dir as NSString).deletingLastPathComponent
            let parent = (pkg as NSString).deletingLastPathComponent
            execDir = (parent as NSString).lastPathComponent.hasPrefix("@") ? parent : pkg
        case .gemini: state = "\(home)/.gemini"; execDir = "\(home)/.gemini/antigravity-cli/bin"
        case .claude: return nil
        }
        // A script CLI (npm's `#!/usr/bin/env node`) is started through its checked interpreter, explicitly.
        guard let start = CLI.launch(bin), let interp = start.first else { return nil }
        // agy signs in through /usr/bin/security and the keychain and talks to its helper over /tmp; every
        // other CLI gets none of that.
        let none = "/nonexistent-limitbar"
        let agy = v == .gemini
        let argv = ["/usr/bin/sandbox-exec", "-f", profile, "-D", "HOME=\(home)", "-D", "EXEC=\(bin)",
                    "-D", "INTERP=\(interp)", "-D", "EXECDIR=\(execDir)", "-D", "STATE=\(state)", "-D", "PTMP=\(tmp)",
                    "-D", "HELPER=\(agy ? "/usr/bin/security" : none)",
                    "-D", "KEYCHAINS=\(agy ? "\(home)/Library/Keychains" : none)",
                    "-D", "SHAREDTMP=\(agy ? "/private/tmp" : none)",
                    ] + start + args
        return Box(argv: argv, binary: bin, env: ["TMPDIR": tmp + "/"])
    }
}
