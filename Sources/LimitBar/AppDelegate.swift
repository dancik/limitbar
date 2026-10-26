import AppKit
import Combine
import SwiftUI

/// The status item and its hover panel. Hover opens the panel after 150 ms, leaving the item or the panel
/// closes it after 250 ms; a click pins it open (click again, or click elsewhere, to close). One
/// non-activating panel, so it never steals focus from the app you are in.
final class AppDelegate: NSResponder, NSApplicationDelegate {   // NSResponder: owns the tracking areas
    private var item: NSStatusItem!
    private var tray: PassThroughHostingView<TrayView>!
    private var panel: NSPanel!
    private var panelHost: NSHostingView<AnyView>!
    private let store = Store()
    private let usage = UsageStore()
    private let ui = PanelState()
    private var subs = Set<AnyCancellable>()
    private var pinned = false
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var outsideClick: Any?
    private var usageTimer: Timer?
    private var overItem = false
    private var overPanel = false

    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("not used") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        tray = PassThroughHostingView(rootView: TrayView(store: store))
        tray.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(tray)
        NSLayoutConstraint.activate([tray.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                     tray.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        button.target = self
        button.action = #selector(clicked)
        button.setAccessibilityLabel("AI subscription limits")
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: ["zone": "item"]))
        resizeItem()
        store.$snaps.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeItem(); self?.resizePanel() }
        }.store(in: &subs)
        store.$busy.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }.store(in: &subs)
        // The Usage page changes the panel's height: on every switch and whenever new totals arrive. Each
        // change measures the natural height again (scrolling off) before deciding whether it must scroll.
        Publishers.MergeMany(ui.$page.map { _ in () }.eraseToAnyPublisher(), ui.$range.map { _ in () }.eraseToAnyPublisher(),
                             usage.$summary.map { _ in () }.eraseToAnyPublisher(), usage.$reading.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.ui.scrolls = false; DispatchQueue.main.async { self?.resizePanel() } }
            }.store(in: &subs)
        ui.$scrolls.dropFirst().filter { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }.store(in: &subs)
        ui.$page.sink { [weak self] page in
            guard let self = self, self.panel?.isVisible == true else { return }
            if page == .usage { self.usage.refresh() } else { self.usage.pause() }
        }.store(in: &subs)
        buildPanel()
    }

    private func resizeItem() {
        tray.layoutSubtreeIfNeeded()
        item.length = ceil(tray.fittingSize.width)
        item.button?.toolTip = nil
    }

    // MARK: panel

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 400),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        panelHost = NSHostingView(rootView: AnyView(PanelView(store: store, usage: usage, ui: ui, onQuit: { NSApp.terminate(nil) })))
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(panelHost)
        NSLayoutConstraint.activate([panelHost.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                                     panelHost.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     panelHost.topAnchor.constraint(equalTo: fx.topAnchor),
                                     panelHost.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        panel.contentView = fx
        fx.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: ["zone": "panel"]))
    }

    private func resizePanel() {
        guard panel != nil else { return }
        panelHost.layoutSubtreeIfNeeded()
        let size = panelHost.fittingSize
        guard size.height > 0, let button = item.button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = (win.screen ?? NSScreen.main)?.visibleFrame else { return }   // no display attached
        // Taller than the screen (many models on Usage): the middle scrolls instead. The natural height is
        // measured without scrolling; the flag change re-renders and calls this again.
        let room = screen.height - 16
        if ui.maxHeight != room { ui.maxHeight = room }
        if !ui.scrolls, size.height > room { ui.scrolls = true; return }
        let height = min(size.height, room)
        var x = r.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = max(r.minY - height - 5, screen.minY + 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: height), display: panel.isVisible)
    }

    private func show() {
        guard !panel.isVisible else { return }
        store.refresh(olderThan: 90)      // hover refresh: only sources older than 90 s
        if ui.page == .usage { usage.refresh() }   // logs are read only for someone looking at them
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible, self.ui.page == .usage else { return }
            self.usage.refresh()
        }
        resizePanel()
        panel.orderFrontRegardless()
        item.button?.highlight(true)
    }

    private func hide() {
        guard !pinned else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        usageTimer?.invalidate(); usageTimer = nil
        usage.pause()
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
    }

    @objc private func clicked() {
        showTimer?.invalidate()
        if pinned {
            pinned = false
            hide()
        } else {
            pinned = true
            show()
            item.button?.highlight(true)
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self = self else { return }
                self.pinned = false
                self.hide()
            }
        }
    }

    // MARK: hover

    override func mouseEntered(with event: NSEvent) {
        let zone = (event.trackingArea?.userInfo?["zone"] as? String) ?? ""
        if zone == "item" { overItem = true } else { overPanel = true }
        hideTimer?.invalidate()
        if zone == "item" && !panel.isVisible {
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in self?.show() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        let zone = (event.trackingArea?.userInfo?["zone"] as? String) ?? ""
        if zone == "item" { overItem = false; showTimer?.invalidate() } else { overPanel = false }
        guard !pinned else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self, !self.overItem, !self.overPanel else { return }
            self.hide()
        }
    }
}

/// The tray's SwiftUI view must not swallow clicks meant for the status bar button underneath it.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
