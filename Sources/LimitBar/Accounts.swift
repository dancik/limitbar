import CryptoKit
import Foundation

/// Where an account comes from. The raw value is what `accounts.json` (the Cockpit interface) says.
enum AccountSource: String, Codable {
    case standard = "default"    // the CLI's own standard folder, found on PATH
    case config                  // ~/Library/Application Support/limitbar/extra-accounts.json
    case t3code                  // a provider instance of T3 Code (~/.t3/userdata/settings.json)

    /// Whose display name wins when two entries turn out to be the same account.
    var rank: Int { self == .config ? 2 : self == .t3code ? 1 : 0 }
    var order: Int { self == .standard ? 0 : self == .config ? 1 : 2 }
}

/// One account = a vendor, a display name and the CLI's configuration folder (`CLAUDE_CONFIG_DIR` for Claude,
/// `CODEX_HOME` for Codex), optionally its own executable. LimitBar still asks only the official CLIs.
struct Account: Equatable {
    var id: String               // "claude:work" — vendor:slug; no e-mail, no personal name by construction
    var vendor: Vendor
    var name: String
    var source: AccountSource
    var configDir: String? = nil     // nil = the CLI's standard folder
    var binary: String? = nil        // nil = found on the fixed search path
    var unsupported: String? = nil   // set = known but cannot be read; never queried

    var isStandard: Bool { source == .standard }
}

/// Finding accounts: the four standard ones, the user's own list, and the profiles of T3 Code.
/// Everything here only reads names and folder paths. A key that looks like a secret is never looked at.
enum Accounts {
    static let home = CLI.home

    static func standardDir(_ v: Vendor) -> String? {
        switch v {
        case .claude: return "\(home)/.claude"
        case .codex: return "\(home)/.codex"
        default: return nil
        }
    }

    static func standardAccount(_ v: Vendor) -> Account {
        Account(id: "\(v.rawValue):default", vendor: v, name: v.name, source: .standard)
    }

    static func standard() -> [Account] {
        Vendor.allCases.map { Account(id: "\($0.rawValue):default", vendor: $0, name: $0.name, source: .standard) }
    }

    /// ~/Library/Application Support/limitbar/extra-accounts.json (overridable with `defaults write
    /// io.github.dancik.limitbar extraAccountsFile /abs/path`). Format: see README.
    static var extraFile: String {
        UserDefaults.standard.string(forKey: "extraAccountsFile").flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? "\(home)/Library/Application Support/limitbar/extra-accounts.json"
    }

    /// T3 Code's data folder (overridable for tests with `-t3Dir`).
    static var t3Root: String {
        UserDefaults.standard.string(forKey: "t3Dir").flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.t3"
    }

    static func all() -> [Account] {
        merge(standard() + configured(at: extraFile) + t3Code(root: t3Root))
    }

    // MARK: paths

    /// "~/x" or "/x", normalised. Anything else (relative, "~user") is refused.
    static func expand(_ p: String) -> String? {
        let t = p.trimmingCharacters(in: .whitespaces)
        let full = t == "~" ? home : t.hasPrefix("~/") ? home + String(t.dropFirst(1)) : t
        guard full.hasPrefix("/"), !full.contains("\0") else { return nil }
        return (full as NSString).standardizingPath
    }

    private static let deniedUnderHome: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config", ".local", ".cache", ".Trash", ".git",
        ".npm", ".1password", ".op", ".password-store", ".zsh_sessions", ".terraform.d", ".gcloud",
    ]

    /// A folder is accepted as an account folder only when it is a dot-folder of this user's home (like
    /// `~/.claude-work`), not a folder with other people's or other tools' secrets, owned by this user and
    /// not writable by others. The Codex sandbox opens this folder for the CLI, so a setting that said
    /// "~" or "~/.ssh" must never widen it. Returns the resolved path.
    static func checkedDir(_ path: String) -> String? {
        guard let rp = realpath(path, nil), let rh = realpath(home, nil) else { return nil }
        let real = String(cString: rp), realHome = String(cString: rh)
        free(rp); free(rh)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue,
              real.hasPrefix(realHome + "/"), CLI.safeNode(real, isLink: false) else { return nil }
        let parts = real.dropFirst(realHome.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first, first.hasPrefix("."), first.count > 1, !deniedUnderHome.contains(first) else { return nil }
        if first == ".t3" && parts.count < 4 { return nil }       // T3's data folder itself holds its secrets
        return real
    }

    // MARK: the user's own list

    struct Entry: Decodable { var vendor: String; var name: String?; var configDir: String?; var binary: String? }
    struct File: Decodable { var accounts: [Entry] }

    static func configured(at file: String) -> [Account] {
        guard let d = FileManager.default.contents(atPath: file), let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.accounts.compactMap { e in
            guard let v = Vendor(rawValue: e.vendor), v == .claude || v == .codex, let cd = e.configDir.flatMap(expand) else { return nil }
            let name = cleanName(e.name) ?? v.name
            let bin = e.binary.flatMap(expand)
            return Account(id: "", vendor: v, name: name, source: .config, configDir: cd, binary: bin)
        }
    }

    // MARK: T3 Code

    /// Reads `providerInstances` of T3 Code's settings.json. Of each instance only `driver`, `displayName`,
    /// `enabled` and `config.{homePath, setupMode, binaryPath}` are read; nothing else is looked at.
    static func t3Code(root: String) -> [Account] {
        guard let d = FileManager.default.contents(atPath: "\(root)/userdata/settings.json"),
              let top = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let inst = top["providerInstances"] as? [String: Any] else { return [] }
        var out: [Account] = []
        for key in inst.keys.sorted() {
            guard let o = inst[key] as? [String: Any], let driver = o["driver"] as? String,
                  (o["enabled"] as? Bool) != false else { continue }
            let cfg = o["config"] as? [String: Any] ?? [:]
            let name = cleanName(o["displayName"] as? String)
            let homePath = (cfg["homePath"] as? String).flatMap(expand)
            let binaryPath = (cfg["binaryPath"] as? String).flatMap(expand)
            switch driver {
            case "claudeAgent":
                guard let dir = homePath else { continue }        // no own folder = the standard account
                out.append(Account(id: "", vendor: .claude, name: name ?? Vendor.claude.name, source: .t3code,
                                   configDir: dir, binary: binaryPath))
            case "codex":
                var dir = homePath, bin = binaryPath
                if dir == nil, (cfg["setupMode"] as? String) == "managed", safeComponent(key) {
                    dir = "\(root)/userdata/providers/codex/\(key)/shadow"
                    bin = bin ?? t3CodexBinary(root)
                }
                guard let dir = dir else { continue }
                out.append(Account(id: "", vendor: .codex, name: name ?? Vendor.codex.name, source: .t3code,
                                   configDir: dir, binary: bin))
            case "antigravity":
                // T3 Code runs Antigravity as an ACP server with its own sign-in. The CLI's `/quota` reads
                // ~/.gemini only (`--gemini-dir` exists for `acp` alone) and the ACP server has no quota
                // method, so there is no token-free way to ask it. Listed, never queried.
                var why = "T3 Code's Antigravity has no quota query for LimitBar"
                if let b = t3AntigravityBinary(root) {
                    let shown = b.hasPrefix(home + "/") ? "~" + b.dropFirst(home.count) : b
                    why += ". Sign in once with its own program, then LimitBar can read it: run \(shown) in Terminal"
                }
                out.append(Account(id: "", vendor: .gemini, name: name ?? "Antigravity", source: .t3code,
                                   unsupported: why))
            default: continue
            }
        }
        return out
    }

    /// `<t3>/tools/antigravity-acp/<platform>/active.json` names the release; the program is
    /// `<t3>/tools/antigravity-acp/<platform>/versions/<release>/antigravity` (the same program as `agy`).
    static func t3AntigravityBinary(_ root: String) -> String? {
        #if arch(arm64)
        let platforms = ["darwin-arm64"]
        #else
        let platforms = ["darwin-x64", "darwin-amd64"]
        #endif
        for pl in platforms {
            let base = "\(root)/tools/antigravity-acp/\(pl)"
            guard let d = FileManager.default.contents(atPath: "\(base)/active.json"),
                  let id = Fetch.json(d)?["releaseId"] as? String, safeComponent(id) else { continue }
            let p = "\(base)/versions/\(id)/antigravity"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func safeComponent(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// `<t3>/tools/codex/active.json` names the installed version; its binary is `<t3>/tools/codex/<v>/bin/codex`.
    static func t3CodexBinary(_ root: String) -> String? {
        guard let d = FileManager.default.contents(atPath: "\(root)/tools/codex/active.json"),
              let v = (Fetch.json(d))?["version"] as? String, safeComponent(v) else { return nil }
        let p = "\(root)/tools/codex/\(v)/bin/codex"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// A display name from someone's settings: trimmed, printable, short.
    static func cleanName(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(40))
    }

    // MARK: merging and ids

    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let t = folded.lowercased().unicodeScalars.map { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) ? Character($0) : "-" }
        return String(t).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    /// Standard accounts first, then the user's list, then T3 Code; ordered by vendor. Accounts that share
    /// one folder are one account: the first stays and takes over the name with the highest rank (the
    /// user's own name > T3 Code's > the generic one). Ids are vendor:slug-of-name, made unique.
    static func merge(_ list: [Account]) -> [Account] {
        var kept: [Account] = []
        var rank: [Int] = []
        var realDirs: [Int: String] = [:]
        func real(_ a: Account) -> String? {
            guard let d = a.configDir ?? standardDir(a.vendor), let rp = realpath(d, nil) else { return a.configDir ?? standardDir(a.vendor) }
            defer { free(rp) }
            return String(cString: rp)
        }
        for a in list {
            var dup: Int?
            if a.unsupported == nil, let r = real(a) {
                dup = kept.indices.first { kept[$0].vendor == a.vendor && kept[$0].unsupported == nil && realDirs[$0] == r }
                if dup == nil { realDirs[kept.count] = r }
            }
            if let i = dup {
                if a.source.rank > rank[i] { kept[i].name = a.name; rank[i] = a.source.rank }
                if kept[i].binary == nil, kept[i].isStandard == false { kept[i].binary = a.binary }
                continue
            }
            kept.append(a); rank.append(a.source.rank)
        }
        var order = Array(kept.indices)
        order.sort { l, r in
            let a = kept[l], b = kept[r]
            let va = Vendor.allCases.firstIndex(of: a.vendor)!, vb = Vendor.allCases.firstIndex(of: b.vendor)!
            return (va, a.source.order, l) < (vb, b.source.order, r)
        }
        var seen = Set<String>()
        var out: [Account] = []
        for i in order {
            var a = kept[i]
            let base = a.isStandard ? "\(a.vendor.rawValue):default" : "\(a.vendor.rawValue):\(slug(a.name).isEmpty ? a.vendor.rawValue : slug(a.name))"
            var id = base, n = 2
            while seen.contains(id) { id = "\(base)-\(n)"; n += 1 }
            seen.insert(id); a.id = id
            out.append(a)
        }
        return out
    }

    /// SHA-256 over what makes two sign-ins the same account. Kept in memory only, never written or shown.
    static func fingerprint(_ parts: [String?]) -> String? {
        let p = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard p.count == parts.count, !p.isEmpty else { return nil }
        return SHA256.hash(data: Data(p.joined(separator: "\u{1f}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Short tags that tell accounts of one vendor apart in the menu bar ("privat" → "p", "pr" if needed).
    static func shortTags(_ list: [(account: Account, name: String)]) -> [String: String] {
        var tags: [String: String] = [:]
        for v in Vendor.allCases {
            let group = list.filter { $0.account.vendor == v }
            guard group.count > 1 else { continue }
            let bases = group.map { g -> String in
                let a = g.account
                var n = g.name
                if n.lowercased().hasPrefix(v.name.lowercased()) { n = String(n.dropFirst(v.name.count)) }
                let t = n.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                return t.isEmpty ? (a.isStandard ? "std" : g.name) : t
            }
            for len in 1...4 {
                let c = bases.map { String($0.prefix(len)).lowercased() }
                if Set(c).count == c.count || len == 4 {
                    for (g, t) in zip(group, c) { tags[g.account.id] = t }
                    break
                }
            }
        }
        return tags
    }
}
