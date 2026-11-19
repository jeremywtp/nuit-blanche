import AppKit

@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let panel: PanelController
    private var lastSymbol = ""
    private var lastTitle: String?

    init(model: AppModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        super.init()
        item.autosaveName = "NuitBlanche"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityTitle("Nuit Blanche")
        }
        refresh()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // Clic droit (ou Contrôle + clic) : menu rapide.
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showQuickMenu()
            return
        }
        // Option + clic : bascule la caféine sans ouvrir le panneau.
        if event?.modifierFlags.contains(.option) == true {
            model.toggleManual()
            return
        }
        panel.toggle()
    }

    // MARK: Menu rapide (clic droit)

    private func showQuickMenu() {
        panel.close()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: model.manualActive ? "Caféine : \(model.awakeSubtitle.lowercased())" : "Caféine"))
        for (index, minutes) in AppModel.durations.enumerated() {
            let title = minutes == 0 ? "Jusqu’à ce que je l’arrête" : Self.longDuration(minutes)
            let entry = NSMenuItem(title: title, action: #selector(startCaffeine(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = model.manualActive && model.manualPreset && model.durationIndex == index ? .on : .off
            menu.addItem(entry)
        }
        if model.manualActive {
            let stop = NSMenuItem(title: "Arrêter la caféine", action: #selector(stopCaffeine), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let lid = NSMenuItem(title: "Capot fermé", action: #selector(toggleLid), keyEquivalent: "")
        lid.target = self
        lid.state = model.helperInstalled && model.lidModeEnabled ? .on : .off
        menu.addItem(lid)
        let agents = NSMenuItem(title: "Agents IA", action: #selector(toggleAgents), keyEquivalent: "")
        agents.target = self
        agents.state = model.agentsAuto ? .on : .off
        menu.addItem(agents)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Ouvrir le panneau", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Réglages…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter Nuit Blanche", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private static func longDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 heure" : "\(hours) heures"
    }

    @objc private func startCaffeine(_ sender: NSMenuItem) { model.startManual(durationIndex: sender.tag) }
    @objc private func stopCaffeine() { if model.manualActive { model.toggleManual() } }
    @objc private func toggleLid() { model.toggleLidMode() }
    @objc private func toggleAgents() { model.agentsAuto.toggle() }
    @objc private func openPanel() { panel.open() }
    @objc private func openSettings() { panel.open(screen: .settings) }
    @objc private func quit() { NSApp.terminate(nil) }

    func refresh() {
        guard let button = item.button else { return }
        let symbol = model.menuBarSymbol
        if symbol != lastSymbol {
            lastSymbol = symbol
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.statusTitle)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
        }
        let title = model.menuBarTitle
        if title != lastTitle {
            lastTitle = title
            button.title = title.map { " " + $0 } ?? ""
        }
        let tip = "Nuit Blanche : \(model.statusTitle.lowercased()) · \(model.statusDetail)"
        if button.toolTip != tip { button.toolTip = tip }
    }
}
