import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private let hotKey = HotKey()
    private var signalSources: [DispatchSourceSignal] = []
    /// URL reçues avant la fin du démarrage (lancement par `open nuitblanche://…`) : traitées ensuite.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
            let dark = !args.contains("light")
            Snapshot.run(directory: URL(fileURLWithPath: args[index + 1]), dark: dark)
            exit(0)
        }
        // Désinstallation (install.sh --uninstall) : retire l’élément d’ouverture avant que l’app soit supprimée.
        if args.contains("--unregister-login-item") {
            exit(Setup.setLaunchAtLogin(false) ? 0 : 1)
        }

        // Une seule instance : une deuxième se retirerait en laissant deux lunes et deux moteurs concurrents.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            exit(0)
        }

        Setup.deployScripts()
        UNUserNotificationCenter.current().delegate = self

        model = AppModel()
        panel = PanelController(model: model)
        statusItem = StatusItemController(model: model, panel: panel)
        panel.statusButton = statusItem.item.button
        model.onChange = { [weak self] in self?.statusItem.refresh() }

        HotKey.action = { [weak self] in
            MainActor.assumeIsolated { self?.model.toggleManual() }
        }
        model.onHotkeyChange = { [weak self] enabled in
            guard let self else { return }
            self.model.hotkeyAvailable = self.hotKey.set(enabled)
        }
        model.hotkeyAvailable = hotKey.set(model.hotkeyEnabled)

        model.start()
        observeSleepWake()
        handleTerminationSignals()
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            DispatchQueue.main.async { [weak self] in self?.handle(urls) }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--open") {
            let name = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : "main"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.panel.open(screen: Self.screen(named: name))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    /// nuitblanche://panel/<écran>, nuitblanche://hold?minutes=30, nuitblanche://release, nuitblanche://toggle
    func application(_ application: NSApplication, open urls: [URL]) {
        // AppKit peut livrer l’URL de lancement avant applicationDidFinishLaunching.
        guard model != nil, panel != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        handle(urls)
    }

    private func handle(_ urls: [URL]) {
        for url in urls where url.scheme == "nuitblanche" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.host() {
            case "panel":
                let name = url.pathComponents.dropFirst().first ?? "main"
                panel.open(screen: Self.screen(named: name))
            case "close":
                panel.close()
            case "toggle":
                model.toggleManual()
            case "hold":
                // N’importe quelle app ou page peut ouvrir cette URL : durée bornée (1 h par défaut, 12 h au plus).
                let asked = items.first { $0.name == "minutes" }?.value.flatMap(Int.init) ?? 60
                model.setManualHold(minutes: min(max(asked, 1), 720))
            case "release":
                model.stopEverything()
            case "debug":
                // Réservé au développement (n’importe quelle app ou page peut ouvrir une URL nuitblanche://) :
                // defaults write com.jeremywtp.NuitBlanche allowDebugURLs -bool YES
                guard UserDefaults.standard.bool(forKey: "allowDebugURLs") else { break }
                // Réglage du verre en direct pour calibrer par captures : nuitblanche://debug/glass?clear=1&dim=0.3&radius=28
                let value = { (name: String) in items.first { $0.name == name }?.value }
                var style = panel.style
                if let clear = value("clear") { style.clear = clear == "1" }
                if let dim = value("dim").flatMap(Double.init) { style.dimming = CGFloat(dim) }
                if let radius = value("radius").flatMap(Double.init) { style.cornerRadius = CGFloat(radius) }
                if let modules = value("modules") { model.liquidGlass = modules == "clear" }
                // Affiche la n-ième bulle d’explication (ordre de lecture) sans souris : tip=0, tip=1…
                if let index = value("tip").flatMap(Int.init) { model.tips.showRegistered(index: index) }
                // Apparence forcée pour vérifier le mode clair sans toucher au réglage système : appearance=light|dark|system
                if let mode = value("appearance") {
                    NSApp.appearance = mode == "light" ? NSAppearance(named: .aqua)
                        : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
                }
                panel.style = style
            default:
                break
            }
        }
    }

    private static func screen(named name: String) -> Screen {
        switch name {
        case "awake": .awake
        case "lid": .lid
        case "agents": .agents
        case "display": .display
        case "settings": .settings
        default: .main
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.didWake() }
        }
    }

    /// `pkill NuitBlanche` (ou une mise à jour) doit aussi rétablir la veille proprement.
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                // Arrêt demandé par le système ou une mise à jour : la caféine en cours reprendra à la relance.
                self?.model?.relaunchExpected = true
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
