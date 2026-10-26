import AppKit
import Combine
import Foundation

/// Keeps one Snapshot per vendor fresh at the lowest cost:
/// - one CLI at a time on a serial queue, hard 20–40 s deadlines, whole process group killed;
/// - a source is re-polled only when its own activity files moved since the last poll (or its reset time
///   passed), plus a slow safety interval; hovering refreshes anything older than 90 s;
/// - Claude reads the opt-in statusline file for free and runs `claude -p /usage` at most every 20 min
///   when that file is missing or stale;
/// - paused while the Mac sleeps, refreshed on wake; last good values cached on disk, never shown as 0.
final class Store: ObservableObject {
    @Published private(set) var snaps: [Vendor: Snapshot] = [:]
    @Published private(set) var busy: Set<Vendor> = []

    private let queue = DispatchQueue(label: "limitbar.fetch", qos: .utility)
    private var timer: Timer?
    private var asleep = false
    private var lastPoll: [Vendor: Date] = [:]
    private var lastActivity: [Vendor: Date] = [:]
    private var lastClaudeUsage = Date.distantPast
    private var lastAccountCheck = Date.distantPast
    private var lastCodexServer = Date.distantPast
    private var claudeAccount: (signedIn: Bool, plan: String)?

    private var cacheFile: String { "\(Paths.cache)/state.json" }
    private let home = CLI.home

    /// Slow safety net per source even when nothing moved (another machine may spend the same quota).
    private let idleInterval: [Vendor: TimeInterval] = [.claude: 20 * 60, .gemini: 30 * 60, .codex: 30 * 60, .grok: 30 * 60]
    /// Minimum gap between polls when activity moved.
    private let busyInterval: [Vendor: TimeInterval] = [.claude: 60, .gemini: 5 * 60, .codex: 60, .grok: 5 * 60]
    /// A missing CLI is looked for again this often (it may have just been installed).
    private let missingInterval: TimeInterval = 5 * 60

    /// Vendors the menu bar shows: everything whose CLI exists. Missing ones are listed in the panel only.
    var installed: [Vendor] {
        Vendor.allCases.filter { v in
            guard let s = snaps[v] else { return true }
            return s.state != .missing
        }
    }

    /// `live: false` only loads the cached readings: no CLI runs, no timers (debug panel renders).
    init(live: Bool = true) {
        loadCache()
        guard live else { return }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.refresh(force: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
        refresh(force: true)
    }

    /// Called by the timer (every 30 s, cheap checks only), on wake, on hover and from the panel.
    func refresh(force: Bool = false, olderThan: TimeInterval? = nil) {
        guard !asleep else { return }
        for v in Vendor.allCases where shouldPoll(v, force: force, olderThan: olderThan) {
            schedule(v, force: force)
        }
    }

    private func shouldPoll(_ v: Vendor, force: Bool, olderThan: TimeInterval?) -> Bool {
        if busy.contains(v) { return false }
        let last = lastPoll[v] ?? .distantPast
        let age = Date().timeIntervalSince(last)
        if force { return true }
        if let s = snaps[v], s.state == .missing || s.state == .untrusted { return age > missingInterval }
        if v == .claude { return age > 30 }      // the file read is free; the expensive part is gated inside
        if let o = olderThan { return age > o }
        if let s = snaps[v], s.windows.contains(where: { $0.resetPassed }) { return age > 60 }
        let act = activity(v)
        if let a = act, a > (lastActivity[v] ?? .distantPast), age > busyInterval[v]! { return true }
        return age > idleInterval[v]!
    }

    /// Newest mtime among the files that move when this vendor's quota is being spent.
    private func activity(_ v: Vendor) -> Date? {
        let fm = FileManager.default
        var candidates: [String]
        switch v {
        case .claude: candidates = [Fetch.claudeFilePath]
        case .gemini: candidates = ["\(home)/.gemini/antigravity-cli/conversations"]
        case .codex:
            // ~/.codex/sessions/YYYY/MM/DD: today's directory moves on every new session
            let c = Calendar.current, d = Date(), root = "\(home)/.codex/sessions"
            candidates = [root, String(format: "%@/%04d/%02d/%02d", root, c.component(.year, from: d),
                                       c.component(.month, from: d), c.component(.day, from: d))]
        case .grok: candidates = ["\(home)/.grok/sessions"]
        }
        if v == .grok, let root = candidates.last, let subs = try? fm.contentsOfDirectory(atPath: root) {
            candidates += subs.map { "\(root)/\($0)" }       // one level down: per-project session folders
        }
        return candidates.compactMap { Fetch.mtime($0) }.max()
    }

    private func schedule(_ v: Vendor, force: Bool) {
        busy.insert(v)
        let act = activity(v)
        let prev = snaps[v]                        // read on main; fetch runs on the queue
        queue.async { [weak self] in
            guard let self = self else { return }
            let s = self.fetch(v, prev: prev, force: force)
            DispatchQueue.main.async {
                self.busy.remove(v)
                self.lastPoll[v] = Date()
                if let a = act { self.lastActivity[v] = a }
                self.apply(v, s)
            }
        }
    }

    /// Runs on the serial queue.
    private func fetch(_ v: Vendor, prev: Snapshot?, force: Bool) -> Snapshot {
        switch v {
        case .claude:
            if case .missing = CLI.find("claude") { return .status(.claude, .missing) }
            if case .untrusted = CLI.find("claude") { return .status(.claude, .untrusted, "claude could be replaced by another account — not run") }
            if force || Date().timeIntervalSince(lastAccountCheck) > 30 * 60 {
                lastAccountCheck = Date()
                claudeAccount = Fetch.claudeAccount() ?? claudeAccount
            }
            if claudeAccount?.signedIn == false { return .status(.claude, .signedOut) }
            var s = Fetch.claudeFile()
            let fileAge = s?.measuredAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if fileAge > 20 * 60, force || Date().timeIntervalSince(lastClaudeUsage) > 20 * 60 {
                lastClaudeUsage = Date()
                s = Fetch.claudeUsage()
            }
            guard var out = s else { return prev ?? .status(.claude, .failed, "waiting for claude") }
            out.plan = claudeAccount?.plan ?? out.plan
            return out
        case .gemini:
            return Fetch.gemini()
        case .codex:
            // Session logs are free and exact; the app-server adds the reset credits, covers idle hours and
            // tells a signed-out CLI apart.
            if case .ok = CLI.find("codex"), !force, let logs = Fetch.codexFromLogs(),
               let m = logs.measuredAt, Date().timeIntervalSince(m) < 10 * 60,
               Date().timeIntervalSince(lastCodexServer) < 30 * 60 {
                var s = logs
                s.notes = prev?.notes ?? []
                return s
            }
            lastCodexServer = Date()
            let s = Fetch.codexFromServer()
            if s.state == .failed, let logs = Fetch.codexFromLogs() { return logs }
            return s
        case .grok:
            return Fetch.grok()
        }
    }

    private func apply(_ v: Vendor, _ s: Snapshot) {
        var s = s
        if s.state == .failed, var old = snaps[v], old.state == .ok, !old.windows.isEmpty {
            old.error = "Couldn't read — showing last known values" + (s.error.map { " (\($0))" } ?? "")   // our own fixed texts
            s = old
        }
        if s.plan.isEmpty, s.state == .ok { s.plan = snaps[v]?.plan ?? "" }
        snaps[v] = s
        saveCache()
    }

    // MARK: cache — percentages, reset times and plan names only

    private func loadCache() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode([String: Snapshot].self, from: d) {
            for (k, v) in s { if let vendor = Vendor(rawValue: k), v.state == .ok { snaps[vendor] = v } }
        }
    }

    private func saveCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dict = Dictionary(uniqueKeysWithValues: snaps.map { ($0.key.rawValue, $0.value) })
        if let d = try? enc.encode(dict) { Paths.write(d, to: cacheFile) }
    }
}
