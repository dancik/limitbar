import AppKit
import ServiceManagement
import SwiftUI


enum Marks {
    private static var cache: [String: NSImage] = [:]

    static func image(_ v: Vendor) -> NSImage {
        if let i = cache[v.mark] { return i }
        let url = Bundle.main.resourceURL?.appendingPathComponent("marks/\(v.mark).svg")
        let img = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        img.size = NSSize(width: 16, height: 16)
        img.isTemplate = true
        cache[v.mark] = img
        return img
    }
}

extension Color {
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let hot = Color(nsColor: .systemRed)
    static let geminiGradient = LinearGradient(colors: [Color(red: 0x3D / 255, green: 0x8B / 255, blue: 1),
                                                       Color(red: 0xB0 / 255, green: 0x6B / 255, blue: 0xDB / 255)],
                                              startPoint: .leading, endPoint: .trailing)
}

private let staleAfter: TimeInterval = 45 * 60

private func isStale(_ s: Snapshot?) -> Bool {
    guard let m = s?.measuredAt else { return true }
    return Date().timeIntervalSince(m) > staleAfter
}

// MARK: - Tray: mark + % used, no "%" sign, superscript w for weekly, red ≥ 90, "!"

struct TrayView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 8) {
            if store.installed.isEmpty {
                Image(systemName: "gauge").font(.system(size: 13))
                Text("LimitBar").font(.system(size: 12))
            }
            ForEach(store.installed, id: \.self) { v in
                let s = store.snaps[v]
                HStack(spacing: 3) {
                    Image(nsImage: Marks.image(v)).renderingMode(.template).resizable()
                        .interpolation(.high).frame(width: 13, height: 13)
                    digit(s)
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .fixedSize()
    }

    private func digit(_ s: Snapshot?) -> some View {
        let w = s?.state == .ok ? s?.bar : nil
        let shown: Double? = (w == nil || w!.resetPassed) ? nil : w!.used
        let crit = (shown ?? 0) >= 90
        let weekly = w?.short == "w"
        let bang = s?.otherHot ?? false
        var t = Text(percentText(shown))
            .font(.system(size: 13, weight: crit ? .semibold : .regular).monospacedDigit())
        if weekly || bang {
            var sup = Text(weekly ? "w" : "").font(.system(size: 8.5, weight: .medium))
            if bang { sup = sup + Text("!").font(.system(size: 8.5, weight: .heavy)) }
            t = t + sup.baselineOffset(5)
        }
        return t.foregroundStyle(crit ? Color.hot : Color.primary)
            .opacity(isStale(s) && shown != nil ? 0.5 : 1)
            .fixedSize()
    }
}

// MARK: - Panel: 328 pt glass, one section per vendor, bars in brand colours

struct PanelView: View {
    @ObservedObject var store: Store
    var onQuit: () -> Void
    var onResize: () -> Void = {}
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var showProviders = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                ForEach(Array(store.installed.enumerated()), id: \.element) { i, v in
                    if i > 0 { Hairline() }
                    VendorSection(vendor: v, snap: store.snaps[v], busy: store.busy.contains(v), now: context.date)
                }
                if store.enabled.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No providers selected").font(.system(size: 12, weight: .medium))
                        Text("Choose providers below to show limits.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                let missing = store.enabled.filter { !store.installed.contains($0) }
                if !missing.isEmpty {
                    if !store.installed.isEmpty { Hairline() }
                    MissingRow(vendors: missing)
                }
                Hairline()
                footer
            }
            .frame(width: 328)
        }
        .onChange(of: showProviders) { _, _ in onResize() }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            HStack {
                Button { showProviders.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Providers")
                        Image(systemName: showProviders ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose providers")
                .accessibilityValue(showProviders ? "Expanded" : "Collapsed")
                Spacer()
                Text("\(store.enabled.count) of \(Vendor.allCases.count) selected")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            if showProviders {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(Vendor.allCases, id: \.self) { vendor in
                        Toggle(vendor.name, isOn: Binding(
                            get: { !store.hiddenVendors.contains(vendor) },
                            set: { store.setEnabled(vendor, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 7)
            }
            HStack(spacing: 6) {
                FooterButton(title: store.visibleBusy ? "Refreshing…" : "Refresh") { store.refresh(force: true) }
                    .disabled(store.visibleBusy || store.enabled.isEmpty)
                Spacer()
                HStack(spacing: 6) {
                    Text("Launch at Login").font(.system(size: 12))
                    Toggle("", isOn: Binding(get: { login }, set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {}
                        login = SMAppService.mainApp.status == .enabled
                    })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                Spacer()
                FooterButton(title: "Quit", action: onQuit)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct VendorSection: View {
    let vendor: Vendor
    let snap: Snapshot?
    let busy: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                markView.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vendor.name).font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                    Text(planLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ageText).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 1)
            }
            let windows = snap?.windows ?? []
            ForEach(Array(windows.enumerated()), id: \.offset) { i, w in
                MeterRow(window: w, vendor: vendor, now: now,
                         style: i == 0 ? .primary : (w.label == "5-hour" || w.label == "Week" ? .normal : .quiet))
                    .padding(.top, 7)
                    .opacity(isStale(snap) ? 0.48 : 1)
            }
            if snap?.state == .signedOut {
                Text("Signed out — \(vendor.loginHint)").font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 7)
            } else if windows.isEmpty {
                Text(busy ? "Reading…" : "—").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 7)
            }
            ForEach(snap?.notes ?? [], id: \.self) { n in
                Text(n).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
            }
            if let e = snap?.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
    }

    @ViewBuilder private var markView: some View {
        let img = Image(nsImage: Marks.image(vendor)).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: 16, height: 16)
        switch vendor {
        case .claude: img.foregroundStyle(Color.claude)
        case .gemini: img.foregroundStyle(Color.geminiGradient)
        default: img.foregroundStyle(Color.primary)
        }
    }

    private var planLine: String {
        let plan = snap?.plan ?? ""
        return plan.isEmpty ? vendor.product : "\(vendor.product) · \(plan)"
    }

    private var ageText: String {
        if busy && snap?.measuredAt == nil { return "reading…" }
        guard let m = snap?.measuredAt else { return "" }
        let s = Int(Date().timeIntervalSince(m))
        let t = s < 60 ? "just now" : s < 3600 ? "\(s / 60) min ago" : s < 86400 ? "\(s / 3600) h ago" : "\(s / 86400) d ago"
        return "updated " + t
    }
}

/// CLIs that aren't installed: one quiet line, so the panel says what limitbar can read once they are.
private struct MissingRow: View {
    let vendors: [Vendor]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Not installed").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(vendors.map { "\($0.name) (\($0.product))" }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
    }
}

private struct MeterRow: View {
    enum Style { case primary, normal, quiet }
    let window: Window
    let vendor: Vendor
    let now: Date
    let style: Style

    var body: some View {
        let due = window.resetsAt.map { $0 <= now } ?? false
        let hot = !due && (window.used ?? 0) >= 90
        let pace = window.pacing(at: now)
        VStack(alignment: .leading, spacing: 4) {
            if !["5-hour", "Week", "Weekly credits"].contains(window.label) {
                Text(window.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 32)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(compactLabel).lineLimit(1)
                    .font(.system(size: style == .quiet ? 11 : 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                    .help(window.label)
                if !due {
                    VStack(spacing: 3) {
                        Track(fraction: (window.used ?? 0) / 100,
                              height: 4, vendor: vendor, hot: hot)
                        if let pace = pace {
                            TimeTrack(fraction: pace.elapsedFraction,
                                      segments: window.durationMinutes == 300 ? 5 : 7, vendor: vendor)
                        }
                    }
                } else {
                    Spacer()
                }
                Text(due || window.used == nil ? "—" : percentText(window.used) + "%")
                    .font(.system(size: style == .quiet ? 12 : 13,
                                  weight: hot ? .bold : style == .primary ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(hot ? Color.hot : (style == .quiet || due ? Color.secondary : Color.primary))
                    .fixedSize()
                    .frame(width: 40, alignment: .trailing)
            }
            Text(pace?.remainingText ?? resetText(due))
                .foregroundStyle(.secondary)
                .help(resetText(due))
                .font(.system(size: 10).monospacedDigit())
                .padding(.leading, 32)
        }
        .help(pace.map {
            "Top: usage. Bottom: time elapsed, one segment per \(window.durationMinutes == 300 ? "hour" : "day"). \(percentText($0.elapsedFraction * 100))% time elapsed. \($0.summary). pp = percentage points. \(resetText(due))."
        } ?? resetText(due))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.label)
        .accessibilityValue(pace.map { "\(percentText(window.used)) percent used, \(percentText($0.elapsedFraction * 100)) percent of time elapsed, \($0.summary)" } ?? "")
    }

    private var compactLabel: String {
        if window.short == "5h" { return "5h" }
        if window.short == "w" { return "1w" }
        return ""
    }

    private func resetText(_ due: Bool) -> String {
        if due { return "reset — awaiting update" }
        // Gemini rows are named after the model group, so the window length goes on this line.
        let kind = vendor == .gemini ? (window.short == "5h" ? "5-hour · " : "week · ") : ""
        guard let r = window.resetsAt else { return kind.isEmpty ? "" : String(kind.dropLast(3)) }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(r) ? "HH:mm" : "EEE HH:mm"
        return kind + (vendor == .grok ? "ends " : "resets ") + f.string(from: r)
    }
}

private struct Track: View {
    let fraction: Double
    let height: CGFloat
    let vendor: Vendor
    let hot: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16)).frame(height: height)
                fill.frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))), height: height)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private var fill: some View {
        if hot { Capsule().fill(Color.hot) }
        else {
            switch vendor {
            case .claude: Capsule().fill(Color.claude)
            case .gemini: Capsule().fill(Color.geminiGradient)
            default: Capsule().fill(Color.primary)
            }
        }
    }
}

/// Five hours or seven days, aligned to the usage bar above. A partial segment shows the current period.
private struct TimeTrack: View {
    let fraction: Double
    let segments: Int
    let vendor: Vendor
    private let gap: CGFloat = 3
    private let height: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            let width = max(0, (g.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { index in
                    let used = min(width, max(0, g.size.width * fraction - CGFloat(index) * (width + gap)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(tint.opacity(0.6)).frame(width: used)
                    }
                    .frame(width: width, height: height)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch vendor {
        case .claude: return .claude
        case .gemini: return Color(red: 0x3D / 255, green: 0x8B / 255, blue: 1)
        default: return .primary
        }
    }
}
