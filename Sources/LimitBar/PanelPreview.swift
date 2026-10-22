import AppKit
import SwiftUI

/// Screenshots of the real panel, using sample limits and no account access.
enum PanelPreview {
    private enum RenderError: Error { case imageUnavailable }
    @MainActor static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        func window(_ label: String, _ short: String, _ used: Double, _ minutes: Int, _ elapsed: Double) -> Window {
            Window(label: label, short: short, used: used,
                   resetsAt: now.addingTimeInterval(Double(minutes) * 60 * (1 - elapsed)), durationMinutes: minutes)
        }
        let claude = [window("5-hour", "5h", 60, 300, 0.4), window("Week", "w", 35, 10_080, 0.6)]
        let codex = [window("5-hour", "5h", 25, 300, 0.25), window("Week", "w", 82, 10_080, 0.5)]
        let store = Store(previewSnapshots: [
            .claude: Snapshot(vendor: .claude, plan: "Max", bar: claude[0], windows: claude, measuredAt: now),
            .codex: Snapshot(vendor: .codex, plan: "ChatGPT Pro", bar: codex[0], windows: codex, measuredAt: now),
            .gemini: .status(.gemini, .missing), .grok: .status(.grok, .missing)
        ], preferences: nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: PanelView(store: store, onQuit: {}))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            let panel = NSView(frame: NSRect(origin: .zero, size: size))
            panel.appearance = host.appearance
            panel.wantsLayer = true
            panel.layer?.backgroundColor = (name == "dark" ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
            host.frame = panel.bounds
            panel.addSubview(host)
            panel.layoutSubtreeIfNeeded()
            guard let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { throw RenderError.imageUnavailable }
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.imageUnavailable }
            let url = directory.appendingPathComponent("pacing-\(name).png")
            try png.write(to: url)
            print("Rendered \(url.lastPathComponent): \(Int(size.width)) × \(Int(size.height)) pt")
        }
    }
}
