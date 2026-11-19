import AppKit
import SwiftUI

/// Aperçu hors écran : `NB_SNAPSHOT=1 NuitBlanche --snapshot <dossier> [dark|light]`.
/// Rend chaque écran du panneau dans un PNG sans toucher au système (modèle en dryRun).
@MainActor
enum Snapshot {
    static func run(directory: URL, dark: Bool) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = dark ? "sombre" : "clair"

        let idle = makeModel()
        idle.evaluate()
        render(idle, name: "1-repos-\(suffix)", to: directory)

        let busy = makeModel()
        busy.helperInstalled = true
        busy.hooks = HooksStatus(claude: true, codex: true, codexInstalled: true)
        busy.sessions = fakeSessions()
        busy.evaluate()
        render(busy, name: "2-agents-\(suffix)", to: directory)

        let manual = makeModel()
        manual.helperInstalled = true
        manual.hooks = HooksStatus(claude: true, codex: true, codexInstalled: true)
        manual.manualActive = true
        manual.manualUntil = Date().addingTimeInterval(5_520)
        manual.evaluate()
        render(manual, name: "3-manuel-\(suffix)", to: directory)

        for (screen, name) in [(Screen.awake, "4-detail-eveille"), (.lid, "5-detail-capot"),
                               (.agents, "6-detail-agents"), (.settings, "7-reglages")] {
            busy.screen = screen
            render(busy, name: "\(name)-\(suffix)", to: directory)
        }
    }

    private static func makeModel() -> AppModel {
        let model = AppModel()
        model.dryRun = true
        model.power = PowerInfo.snapshot()
        model.systemSleepDisabled = false
        model.helperInstalled = false
        model.hooks = HooksStatus()
        model.sessions = []
        return model
    }

    private static func fakeSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(id: "claude-a", agent: "claude", state: "working", cwd: "/Users/demo/Developer/nuit-blanche",
                         pid: 0, updated: now.addingTimeInterval(-95), until: nil, label: ""),
            AgentSession(id: "codex-b", agent: "codex", state: "idle", cwd: "/Users/demo/Developer/mon-site",
                         pid: 0, updated: now.addingTimeInterval(-1_260), until: nil, label: ""),
        ]
    }

    private static func render(_ model: AppModel, name: String, to directory: URL) {
        let root = RootView(model: model)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.0))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: M.width, height: 1_000)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = (NSApp.effectiveAppearance.name == .darkAqua
            ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        container.layer?.cornerRadius = 30
        container.addSubview(host)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        var height: CGFloat = 0
        model.onHeightChange = { height = $0 }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        if height < 50 { height = host.fittingSize.height }
        let frame = NSRect(x: 0, y: 0, width: M.width, height: height)
        window.setContentSize(frame.size)
        container.frame = frame
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appending(path: "\(name).png"))
        }
    }
}
