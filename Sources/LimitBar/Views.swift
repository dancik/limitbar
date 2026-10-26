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
    static let codex = Color(red: 0x45 / 255, green: 0xA8 / 255, blue: 0x82 / 255)
    static let grokBar = Color(red: 0xEB / 255, green: 0xEB / 255, blue: 0xF0 / 255)
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

// MARK: - Panel: 328 pt glass, Limits | Usage, one section per vendor, bars in brand colours

/// Which page and range the panel shows; remembered across launches.
final class PanelState: ObservableObject {
    enum Page: String { case limits, usage }
    enum Range: String { case today, week }

    @Published var page: Page { didSet { UserDefaults.standard.set(page.rawValue, forKey: "panelPage") } }
    @Published var range: Range { didSet { UserDefaults.standard.set(range.rawValue, forKey: "usageRange") } }
    /// The tallest the panel may be on this screen, and whether its content needs to scroll to fit;
    /// both set by the app delegate.
    @Published var maxHeight: CGFloat = .greatestFiniteMagnitude
    @Published var scrolls = false

    init() {
        page = Page(rawValue: UserDefaults.standard.string(forKey: "panelPage") ?? "") ?? .limits
        range = Range(rawValue: UserDefaults.standard.string(forKey: "usageRange") ?? "") ?? .week
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var usage: UsageStore
    @ObservedObject var ui: PanelState
    var onQuit: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                Segmented(items: [(PanelState.Page.limits, "Limits", "gauge.medium"),
                                  (PanelState.Page.usage, "Usage", "chart.bar.fill")],
                          selection: $ui.page, height: 22, font: 12)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: ui.page == .limits ? 8 : 0, trailing: 10))
                // The switch and the footer stay put; only the middle scrolls, and only on a screen too short
                // for it (many models on Usage).
                if ui.scrolls {
                    ScrollView(.vertical) { middle }.frame(height: max(120, ui.maxHeight - 80))
                } else {
                    middle
                }
                Hairline()
                footer
            }
            .frame(width: 328)
        }
    }

    private var middle: some View {
        VStack(spacing: 0) {
            if ui.page == .usage { UsagePage(store: store, usage: usage, ui: ui) } else { limits }
        }
    }

    @ViewBuilder private var limits: some View {
        Hairline()
        ForEach(Array(store.installed.enumerated()), id: \.element) { i, v in
            if i > 0 { Hairline() }
            VendorSection(vendor: v, snap: store.snaps[v], busy: store.busy.contains(v))
        }
        let missing = Vendor.allCases.filter { !store.installed.contains($0) }
        if !missing.isEmpty {
            if !store.installed.isEmpty { Hairline() }
            MissingRow(vendors: missing)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if ui.page == .usage {
                FooterButton(title: usage.reading ? "Refreshing…" : "Refresh") { usage.refresh(force: true) }
                    .disabled(usage.reading)
            } else {
                FooterButton(title: store.busy.isEmpty ? "Refresh" : "Refreshing…") { store.refresh(force: true) }
                    .disabled(!store.busy.isEmpty)
            }
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
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }
}

/// A small segmented control drawn like the macOS one, so it sits right on the popover glass.
private struct Segmented<T: Hashable>: View {
    let items: [(T, String, String?)]
    @Binding var selection: T
    let height: CGFloat
    let font: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title, symbol in
                let on = value == selection
                Button { selection = value } label: {
                    HStack(spacing: 4) {
                        if let s = symbol { Image(systemName: s).font(.system(size: font - 2, weight: .semibold)) }
                        Text(title).font(.system(size: font, weight: .medium))
                    }
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(maxWidth: symbol == nil ? nil : .infinity)
                    .padding(.horizontal, symbol == nil ? 8 : 0)
                    .frame(height: height)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(on ? 0.14 : 0))
                        .shadow(color: .black.opacity(on ? 0.3 : 0), radius: 0.5, y: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Usage page: tokens per vendor and model, today or the last 7 days

private struct UsagePage: View {
    @ObservedObject var store: Store
    @ObservedObject var usage: UsageStore
    @ObservedObject var ui: PanelState

    var body: some View {
        let window = UsageDays.window(), days = window.map(\.key)
        let shown = ui.range == .week ? days : [days.last!]
        VStack(spacing: 0) {
            HStack {
                Text(usage.summary == nil && usage.reading ? "Reading logs…" : rangeText(window))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Segmented(items: [(PanelState.Range.today, "Today", nil), (PanelState.Range.week, "7 days", nil)],
                          selection: $ui.range, height: 18, font: 11)
            }
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 5, trailing: 12))
            ForEach(store.installed, id: \.self) { v in
                Hairline()
                UsageSection(vendor: v, plan: store.snaps[v]?.plan ?? "", usage: usage.summary?.vendors[v],
                             window: window, shown: shown, week: ui.range == .week, reading: usage.reading)
            }
            if store.installed.isEmpty {
                Hairline()
                Text("No AI coding CLI installed").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    private func rangeText(_ window: [UsageDay]) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        if ui.range == .today { return "Today · " + f.string(from: window.last!.date) }
        return f.string(from: window[0].date) + " – today"
    }
}

private struct UsageSection: View {
    let vendor: Vendor
    let plan: String
    let usage: VendorUsage?
    let window: [UsageDay]
    let shown: [String]
    let week: Bool
    let reading: Bool

    var body: some View {
        let total = usage?.total(shown) ?? ModelTotal()
        let models = usage?.models(shown) ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VendorMark(vendor: vendor).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vendor.name).font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                    Text(plan.isEmpty ? vendor.product : "\(vendor.product) · \(plan)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if usage?.reported == false {
                    Text("—").font(.system(size: 16, weight: .semibold)).foregroundStyle(.tertiary)
                } else if let u = usage {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(compactTokens(total.tokens)).font(.system(size: 16, weight: .semibold).monospacedDigit())
                            .tracking(-0.4)
                        Text("\(total.calls.formatted()) call\(total.calls == 1 ? "" : "s")")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .opacity(u.buckets.isEmpty && reading ? 0.5 : 1)
                }
            }
            if usage?.reported == false {
                Text("Tokens not reported by \(vendor.cli) — it keeps no readable usage log")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)
                    .fixedSize(horizontal: false, vertical: true)
            } else if usage != nil {
                if week { DayBars(values: window.map { usage!.tokens(on: $0.key) }, days: window, vendor: vendor).padding(.top, 8) }
                ForEach(models, id: \.model) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(m.model).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(compactTokens(m.total.tokens)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Text(m.total.calls.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .padding(.top, 5)
                }
                if models.isEmpty {
                    Text(week ? "Not used in the last 7 days" : "Not used today")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, week ? 5 : 7)
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
    }
}

/// Seven columns, oldest first; the last one is today. Days without use show a thin stub.
private struct DayBars: View {
    let values: [Int]
    let days: [UsageDay]
    let vendor: Vendor
    private let height: CGFloat = 32

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Group {
                        if v > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(fill)
                                .frame(height: max(2, height * CGFloat(v) / CGFloat(top)))
                        } else {
                            Color.clear.frame(height: 0)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(compactTokens(v)) tokens")
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 5) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    Text(i == days.count - 1 ? "today" : weekday(d.date))
                        .font(.system(size: 8))
                        .foregroundStyle(i == days.count - 1 ? Color.primary.opacity(0.8) : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var fill: AnyShapeStyle {
        switch vendor {
        case .claude: AnyShapeStyle(Color.claude)
        case .gemini: AnyShapeStyle(LinearGradient(colors: [Color(red: 0x6A / 255, green: 0xA8 / 255, blue: 1),
                                                            Color(red: 0xB0 / 255, green: 0x6B / 255, blue: 0xDB / 255)],
                                                   startPoint: .top, endPoint: .bottom))
        case .codex: AnyShapeStyle(Color.codex)
        case .grok: AnyShapeStyle(Color.grokBar)
        }
    }

    private func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: d)
    }
}

/// The vendor's mark in its colours: Claude orange, Gemini's gradient, Codex and Grok in the text colour.
private struct VendorMark: View {
    let vendor: Vendor
    var body: some View {
        let img = Image(nsImage: Marks.image(vendor)).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: 16, height: 16)
        switch vendor {
        case .claude: img.foregroundStyle(Color.claude)
        case .gemini: img.foregroundStyle(Color.geminiGradient)
        default: img.foregroundStyle(Color.primary)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VendorMark(vendor: vendor).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vendor.name).font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                    Text(planLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ageText).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 1)
            }
            let windows = snap?.windows ?? []
            ForEach(Array(windows.enumerated()), id: \.offset) { i, w in
                MeterRow(window: w, vendor: vendor,
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
    let style: Style

    var body: some View {
        let due = window.resetPassed
        let hot = !due && (window.used ?? 0) >= 90
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: style == .quiet ? 11 : 12, weight: style == .primary ? .semibold : .regular))
                    .foregroundStyle(style == .quiet ? .secondary : .primary)
                Text(resetText(due)).font(.system(size: 11)).foregroundStyle(due ? .secondary : .tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)    // the reset time is never cut off
            }
            .frame(width: 118, alignment: .leading)
            if !due {
                Track(fraction: (window.used ?? 0) / 100, height: style == .quiet ? 4 : 5, vendor: vendor, hot: hot)
            } else {
                Spacer()
            }
            Text(due || window.used == nil ? "—" : percentText(window.used) + "%")
                .font(.system(size: style == .quiet ? 12 : 13,
                              weight: hot ? .bold : style == .primary ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(hot ? Color.hot : (style == .quiet || due ? Color.secondary : Color.primary))
                .frame(width: 40, alignment: .trailing)
        }
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
                Capsule().fill(Color.primary.opacity(0.16))
                fill.frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))))
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

