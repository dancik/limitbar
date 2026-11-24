import AppKit
import Combine
import Foundation

/// Keeps one Snapshot per account fresh at the lowest cost:
/// - one CLI at a time on a serial queue, hard 20–40 s deadlines, whole process group killed;
/// - a source is re-polled only when its own activity files moved since the last poll (or its reset time
///   passed), plus a slow safety interval; hovering refreshes anything older than 90 s;
/// - Claude's standard account reads the opt-in statusline file for free; every Claude account runs
///   `claude -p /usage` at most every 20 min when it has no fresh free reading;
/// - paused while the Mac sleeps, refreshed on wake; last good values cached on disk, never shown as 0;
/// - the same sign-in behind two folders is one account (fingerprint, in memory only): shown once, and the
///   copy is not polled again except for a slow re-check.
/// Every rule above applies per account.
final class Store: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var snaps: [String: Snapshot] = [:]
    @Published private(set) var busy: Set<String> = []
    /// Accounts that turned out to be a copy of an earlier one: id → the account that stays.
    @Published private(set) var duplicateOf: [String: String] = [:]
    /// Display name of a surviving account when one of its copies has a better one (user's own > T3 Code's).
    @Published private(set) var nameOverride: [String: String] = [:]

    /// State only the fetch (serial queue) touches.
    private final class Run {
        var lastClaudeUsage = Date.distantPast
        var lastAccountCheck = Date.distantPast
        var lastCodexServer = Date.distantPast
        var claude: (signedIn: Bool, plan: String)?
    }
    private var runs: [String: Run] = [:]
    private var fingerprints: [String: String] = [:]
    private var codexLogsOwn: [String: Bool] = [:]
    private var codexSessionsReal: [String: String] = [:]
    private var lastPoll: [String: Date] = [:]
    private var lastActivity: [String: Date] = [:]
    private var lastReload = Date.distantPast

    private let queue = DispatchQueue(label: "limitbar.fetch", qos: .utility)
    private var timer: Timer?
    private var asleep = false

    private var cacheFile: String { "\(Paths.cache)/state.json" }
    static var accountsFile: String { "\(Paths.cache)/accounts.json" }
    private let home = CLI.home

    /// Slow safety net per source even when nothing moved (another machine may spend the same quota).
    private let idleInterval: [Vendor: TimeInterval] = [.claude: 20 * 60, .gemini: 30 * 60, .codex: 30 * 60, .grok: 30 * 60]
    /// Minimum gap between polls when activity moved.
    private let busyInterval: [Vendor: TimeInterval] = [.claude: 60, .gemini: 5 * 60, .codex: 60, .grok: 5 * 60]
    /// A missing CLI is looked for again this often (it may have just been installed).
    private let missingInterval: TimeInterval = 5 * 60
    /// The accounts list (extra-accounts.json, T3 Code's settings) is read again this often.
    private let reloadInterval: TimeInterval = 5 * 60
    /// A copy of another account is only re-checked this often (its sign-in may have changed).
    private let duplicateInterval: TimeInterval = 30 * 60

    // MARK: what is shown

    struct Row: Identifiable {
        let account: Account
        let name: String
        let snap: Snapshot?
        var id: String { account.id }
    }

    /// Every account the panel lists: not missing, not a copy of another account, and a signed-out standard
    /// account only while no other account of that vendor works (it would only be clutter next to them).
    var shown: [Row] { rows(includeMissing: false) }

    private func rows(includeMissing: Bool) -> [Row] {
        accounts.compactMap { a in
            guard duplicateOf[a.id] == nil else { return nil }
            let s = snaps[a.id]
            if s?.state == .missing && !includeMissing { return nil }
            if a.isStandard, s?.state == .signedOut,
               accounts.contains(where: { $0.vendor == a.vendor && $0.id != a.id && duplicateOf[$0.id] == nil && snaps[$0.id]?.state == .ok }) {
                return nil
            }
            // One folder of session logs, one account: a standard Codex account yields to a named one
            if a.isStandard, a.vendor == .codex, let r = codexSessionsReal[a.id],
               accounts.contains(where: { $0.id != a.id && $0.vendor == .codex && !$0.isStandard && codexSessionsReal[$0.id] == r }) {
                return nil
            }
            // Antigravity: the standard account and T3 Code's entry are the same program. Show the working
            // standard account, else (signed out / not installed) the entry that carries the sign-in hint.
            if a.vendor == .gemini {
                let t3 = accounts.first { $0.vendor == .gemini && $0.unsupported != nil }
                if a.unsupported != nil, snaps[accounts.first { $0.vendor == .gemini && $0.isStandard }?.id ?? ""]?.state == .ok { return nil }
                if a.isStandard, t3 != nil, s?.state == .signedOut || s?.state == .missing { return nil }
            }
            return Row(account: a, name: nameOverride[a.id] ?? a.name, snap: s)
        }
    }

    /// What the menu bar shows: the same, without accounts that cannot be read at all.
    var bar: [Row] { shown.filter { $0.snap?.state != .unsupported } }

    /// Vendors with a readable account in the panel (the Usage page, which counts per vendor, lists these).
    var installed: [Vendor] {
        let have = Set(bar.map { $0.account.vendor })
        return Vendor.allCases.filter { have.contains($0) }
    }

    func plan(for v: Vendor) -> String { bar.first { $0.account.vendor == v }?.snap?.plan ?? "" }

    /// Vendors with no listed account at all, for the "Not installed" line.
    var missingVendors: [Vendor] {
        let have = Set(shown.map { $0.account.vendor })
        return Vendor.allCases.filter { !have.contains($0) }
    }

    /// `live: false` only loads the cached readings: no CLI runs, no timers (debug panel renders).
    init(live: Bool = true) {
        loadCache()
        reloadAccounts()
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

    /// Called by the timer (every 30 s, cheap checks only), on wake, on hover, on Cockpit's `refresh`
    /// message and from the panel.
    func refresh(force: Bool = false, olderThan: TimeInterval? = nil) {
        guard !asleep else { return }
        if force || Date().timeIntervalSince(lastReload) > reloadInterval { reloadAccounts() }
        for a in accounts where shouldPoll(a, force: force, olderThan: olderThan) {
            schedule(a, force: force)
        }
    }

    // MARK: account list

    private func reloadAccounts() {
        lastReload = Date()
        let list = Accounts.all()
        if list != accounts {
            let ids = Set(list.map { $0.id })
            for k in snaps.keys where !ids.contains(k) { snaps[k] = nil }
            for k in runs.keys where !ids.contains(k) { runs[k] = nil }
            for k in fingerprints.keys where !ids.contains(k) { fingerprints[k] = nil }
            accounts = list
            for a in list {
                if let why = a.unsupported { snaps[a.id] = .status(a.vendor, .unsupported, why) }
                else if snaps[a.id] == nil, a.isStandard, let c = cachedStandard[a.vendor] { snaps[a.id] = c }
                else if snaps[a.id] == nil, let c = cachedExtra[a.id] { snaps[a.id] = c }
            }
        }
        // Two Codex accounts that share one sessions folder share one set of session logs: those logs say
        // nothing about which of them wrote a line, so such accounts are asked through the app-server only.
        // Only accounts whose CLI exists count as writers of those logs.
        var owners: [String: [String]] = [:]
        codexSessionsReal = [:]
        for a in accounts where a.vendor == .codex && a.unsupported == nil {
            let r = realpathOrSelf(Store.codexSessions(a))
            codexSessionsReal[a.id] = r
            if Fetch.binary(a).0 != nil { owners[r, default: []].append(a.id) }
        }
        codexLogsOwn = [:]
        for a in accounts where a.vendor == .codex {
            let others = (owners[codexSessionsReal[a.id] ?? ""] ?? []).filter { $0 != a.id }
            codexLogsOwn[a.id] = others.isEmpty
        }
        recomputeDuplicates()
        saveAccountsFile()
    }

    private static func codexSessions(_ a: Account) -> String { "\(a.configDir ?? Accounts.standardDir(.codex)!)/sessions" }

    private func realpathOrSelf(_ p: String) -> String {
        guard let rp = realpath(p, nil) else { return p }
        defer { free(rp) }
        return String(cString: rp)
    }

    private func recomputeDuplicates() {
        var first: [String: String] = [:], best: [String: Int] = [:]
        var dup: [String: String] = [:], names: [String: String] = [:]
        for a in accounts where a.unsupported == nil {      // accounts are ordered: the standard account comes first
            guard let fp = fingerprints[a.id] else { continue }
            let key = a.vendor.rawValue + fp
            if let f = first[key] {
                dup[a.id] = f
                if a.source.rank > best[key]! { names[f] = a.name; best[key] = a.source.rank }
            } else { first[key] = a.id; best[key] = a.source.rank }
        }
        if dup != duplicateOf { duplicateOf = dup }
        if names != nameOverride { nameOverride = names }
    }

    // MARK: polling

    private func shouldPoll(_ a: Account, force: Bool, olderThan: TimeInterval?) -> Bool {
        if a.unsupported != nil || busy.contains(a.id) { return false }
        let last = lastPoll[a.id] ?? .distantPast
        let age = Date().timeIntervalSince(last)
        if duplicateOf[a.id] != nil { return age > duplicateInterval }
        if force { return true }
        if let s = snaps[a.id], s.state == .missing || s.state == .untrusted { return age > missingInterval }
        if a.vendor == .claude { return age > 30 }      // the file read is free; the expensive part is gated inside
        if let o = olderThan { return age > o }
        if let s = snaps[a.id], s.windows.contains(where: { $0.resetPassed }) { return age > 60 }
        let act = activity(a)
        var busyGap = busyInterval[a.vendor]!
        if a.vendor == .codex, codexLogsOwn[a.id] == false { busyGap = 5 * 60 }   // no free logs: every poll starts codex
        if let t = act, t > (lastActivity[a.id] ?? .distantPast), age > busyGap { return true }
        return age > idleInterval[a.vendor]!
    }

    /// Newest mtime among the files that move when this account's quota is being spent.
    private func activity(_ a: Account) -> Date? {
        let fm = FileManager.default
        var candidates: [String]
        switch a.vendor {
        case .claude: candidates = a.isStandard ? [Fetch.claudeFilePath] : []
        case .gemini: candidates = ["\(home)/.gemini/antigravity-cli/conversations"]
        case .codex:
            // <codex home>/sessions/YYYY/MM/DD: today's directory moves on every new session
            let c = Calendar.current, d = Date(), root = Store.codexSessions(a)
            candidates = [root, String(format: "%@/%04d/%02d/%02d", root, c.component(.year, from: d),
                                       c.component(.month, from: d), c.component(.day, from: d))]
        case .grok: candidates = ["\(home)/.grok/sessions"]
        }
        if a.vendor == .grok, let root = candidates.last, let subs = try? fm.contentsOfDirectory(atPath: root) {
            candidates += subs.map { "\(root)/\($0)" }       // one level down: per-project session folders
        }
        return candidates.compactMap { Fetch.mtime($0) }.max()
    }

    private struct Result {
        var snap: Snapshot
        var fingerprintChecked = false      // true: `fingerprint` is current (nil = signed out / unknown)
        var fingerprint: String?
    }

    private func run(_ a: Account) -> Run {
        if let r = runs[a.id] { return r }
        let r = Run(); runs[a.id] = r; return r
    }

    private func schedule(_ a: Account, force: Bool) {
        busy.insert(a.id)
        let act = activity(a)
        let prev = snaps[a.id]                     // read on main; fetch runs on the queue
        let r = run(a)
        let logsOwn = codexLogsOwn[a.id] ?? true
        queue.async { [weak self] in
            guard let self = self else { return }
            let res = self.fetch(a, run: r, prev: prev, force: force, logsOwn: logsOwn)
            DispatchQueue.main.async {
                self.busy.remove(a.id)
                self.lastPoll[a.id] = Date()
                if let t = act { self.lastActivity[a.id] = t }
                self.apply(a, res)
            }
        }
    }

    /// Runs on the serial queue.
    private func fetch(_ a: Account, run: Run, prev: Snapshot?, force: Bool, logsOwn: Bool) -> Result {
        switch a.vendor {
        case .claude:
            let (bin, why) = Fetch.binary(a)
            if bin == nil { return Result(snap: why!) }
            if let d = a.configDir, !FileManager.default.fileExists(atPath: d) {
                return Result(snap: .status(.claude, .missing, "account folder not found"))
            }
            var res = Result(snap: .status(.claude, .failed))
            if force || Date().timeIntervalSince(run.lastAccountCheck) > 30 * 60 {
                run.lastAccountCheck = Date()
                if let acc = Fetch.claudeAccount(a) {
                    run.claude = (acc.signedIn, acc.plan)
                    res.fingerprintChecked = true; res.fingerprint = acc.fingerprint
                }
            }
            if run.claude?.signedIn == false { res.snap = .status(.claude, .signedOut); return res }
            var s = a.isStandard ? Fetch.claudeFile() : nil     // the statusline file is the standard account's
            let fileAge = s?.measuredAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if fileAge > 20 * 60, force || Date().timeIntervalSince(run.lastClaudeUsage) > 20 * 60 {
                run.lastClaudeUsage = Date()
                s = Fetch.claudeUsage(a)
            }
            guard var out = s else { res.snap = prev ?? .status(.claude, .failed, "waiting for claude"); return res }
            out.plan = run.claude?.plan ?? out.plan
            res.snap = out
            return res
        case .gemini:
            return Result(snap: Fetch.gemini())
        case .codex:
            // Session logs are free and exact; the app-server adds the reset credits, covers idle hours and
            // tells a signed-out CLI apart.
            // Logs first (free, no credentials); the app-server only adds to them. Without a CLI, or when
            // it says signed out, a fresh log reading still counts (note "from session log").
            let (bin, why) = Fetch.binary(a)
            let logs = logsOwn ? Fetch.codexLogsRoot(a).flatMap { Fetch.codexFromLogs(root: $0, days: a.source == .t3code ? 30 : 2) } : nil
            let t3 = a.source == .t3code      // its sign-in lives in T3 Code, out of LimitBar's sight
            if bin == nil { return Result(snap: Fetch.fromSessionLog(logs, anyAge: t3) ?? (t3 ? Fetch.noReadingYet : why!)) }
            if !force, let l = logs, let m = l.measuredAt, Date().timeIntervalSince(m) < 10 * 60,
               Date().timeIntervalSince(run.lastCodexServer) < 30 * 60 {
                var s = l
                s.notes = prev?.notes ?? []
                return Result(snap: s)
            }
            run.lastCodexServer = Date()
            let (s, fp) = Fetch.codexFromServer(a)
            let known = s.state == .ok || s.state == .signedOut
            if s.state != .ok {
                if let l = Fetch.fromSessionLog(logs, anyAge: t3) { return Result(snap: l, fingerprintChecked: known, fingerprint: fp) }
                if t3 { return Result(snap: Fetch.noReadingYet, fingerprintChecked: known, fingerprint: fp) }
            }
            return Result(snap: s, fingerprintChecked: known, fingerprint: fp)
        case .grok:
            return Result(snap: Fetch.grok())
        }
    }

    private func apply(_ a: Account, _ res: Result) {
        var s = res.snap
        if s.state == .failed, var old = snaps[a.id], old.state == .ok, !old.windows.isEmpty {
            old.error = "Couldn't read — showing last known values" + (s.error.map { " (\($0))" } ?? "")   // our own fixed texts
            s = old
        }
        if s.plan.isEmpty, s.state == .ok { s.plan = snaps[a.id]?.plan ?? "" }
        snaps[a.id] = s
        if res.fingerprintChecked { fingerprints[a.id] = res.fingerprint }
        recomputeDuplicates()
        saveCache()
        saveAccountsFile()
    }

    // MARK: cache — percentages, reset times and plan names only

    private var cachedStandard: [Vendor: Snapshot] = [:]
    private var cachedExtra: [String: Snapshot] = [:]

    private func loadCache() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
           let s = try? dec.decode([String: Snapshot].self, from: d) {
            for (k, v) in s { if let vendor = Vendor(rawValue: k), v.state == .ok { cachedStandard[vendor] = v } }
        }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: Store.accountsFile)),
           let f = try? dec.decode(AccountsFile.self, from: d) {
            for e in f.accounts where e.source != AccountSource.standard.rawValue && e.state == VendorState.ok.rawValue {
                if let s = e.snapshot() { cachedExtra[e.id] = s }
            }
        }
    }

    /// state.json keeps its old shape (one entry per vendor, the standard accounts) for older readers.
    private func saveCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var dict: [String: Snapshot] = [:]
        for a in accounts where a.isStandard { if let s = snaps[a.id] { dict[a.vendor.rawValue] = s } }
        if let d = try? enc.encode(dict) { Paths.write(d, to: cacheFile) }
    }

    /// accounts.json: the interface to Cockpit (see README). Every account that has been read once, except copies
    /// of another account; CLIs that are not installed are in it as `missing`.
    private func saveAccountsFile() {
        let entries = rows(includeMissing: true).compactMap { r -> AccountsFile.Entry? in r.snap.map { AccountsFile.Entry(r.account, name: r.name, snap: $0) } }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(AccountsFile(version: 1, writtenAt: Date(), accounts: entries)) {
            Paths.write(d, to: Store.accountsFile)
        }
    }
}

/// The file Cockpit reads. Field names are fixed; nothing here identifies a person (no e-mail, token,
/// organisation or account number).
struct AccountsFile: Codable {
    var version: Int
    var writtenAt: Date
    var accounts: [Entry]

    struct Win: Codable {
        var label: String, short: String
        var used: Double?
        var resetsAt: Date?
        init(_ w: Window) {
            label = w.label; short = w.short
            used = w.resetPassed ? nil : w.used      // a window that has reset since the reading has no valid percent
            resetsAt = w.resetsAt
        }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: Keys.self)
            try c.encode(label, forKey: .label); try c.encode(short, forKey: .short)
            try c.encode(used, forKey: .used); try c.encode(resetsAt, forKey: .resetsAt)     // explicit null
        }
        enum Keys: String, CodingKey { case label, short, used, resetsAt }
        var window: Window { Window(label: label, short: short, used: used, resetsAt: resetsAt) }
    }

    struct Entry: Codable {
        var id: String, vendor: String, name: String, source: String, state: String
        var plan: String?
        var bar: Win?
        var windows: [Win]
        var notes: [String]
        var measuredAt: Date?
        var error: String?

        init(_ a: Account, name: String, snap s: Snapshot) {
            id = a.id; vendor = a.vendor.rawValue; self.name = name; source = a.source.rawValue; state = s.state.rawValue
            plan = s.plan.isEmpty ? nil : s.plan
            bar = s.bar.map(Win.init); windows = s.windows.map(Win.init); notes = s.notes
            measuredAt = s.measuredAt; error = s.error
        }

        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id); try c.encode(vendor, forKey: .vendor); try c.encode(name, forKey: .name)
            try c.encode(source, forKey: .source); try c.encode(state, forKey: .state)
            try c.encode(plan, forKey: .plan); try c.encode(bar, forKey: .bar); try c.encode(windows, forKey: .windows)
            try c.encode(notes, forKey: .notes); try c.encode(measuredAt, forKey: .measuredAt); try c.encode(error, forKey: .error)
        }
        enum Keys: String, CodingKey { case id, vendor, name, source, state, plan, bar, windows, notes, measuredAt, error }

        /// Back from the file into a Snapshot (the cache after a restart).
        func snapshot() -> Snapshot? {
            guard let v = Vendor(rawValue: vendor), let st = VendorState(rawValue: state) else { return nil }
            return Snapshot(vendor: v, state: st, plan: plan ?? "", bar: bar?.window, windows: windows.map { $0.window },
                            notes: notes, measuredAt: measuredAt, error: error)
        }
    }
}
