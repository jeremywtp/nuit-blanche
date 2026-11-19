import AppKit
import ServiceManagement

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appending(path: "Library/Application Support/NuitBlanche", directoryHint: .isDirectory)
    static let sessions = support.appending(path: "sessions", directoryHint: .isDirectory)
    static let bin = support.appending(path: "bin", directoryHint: .isDirectory)
    static let ownedMarker = support.appending(path: "sleep-disabled-by-app")
    static let heartbeat = support.appending(path: "heartbeat")
    static let stateJSON = support.appending(path: "state.json")
    static let stateText = support.appending(path: "state.txt")
    static let history = support.appending(path: "history.json")
    static let cli = home.appending(path: ".local/bin/nuitblanche")
    static let sudoers = "/etc/sudoers.d/nuitblanche"
    static let watchdogLabel = "com.jeremywtp.NuitBlanche.watchdog"
    static let watchdogPlist = home.appending(path: "Library/LaunchAgents/\(watchdogLabel).plist")
}

struct HooksStatus: Equatable {
    var claude = false
    var codex = false
    var codexInstalled = false
}

enum Setup {
    // MARK: Scripts embarqués

    /// Copie le CLI, le watchdog et l’installeur de hooks hors du bundle (chemins stables pour les hooks).
    static func deployScripts() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
        guard let resources = Bundle.main.resourceURL else { return }
        for name in ["nuitblanche", "nuitblanche-watchdog", "install-hooks.py"] {
            let source = resources.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            copyIfDifferent(source, to: Paths.bin.appending(path: name))
        }
        // Les hooks appellent ~/.local/bin/nuitblanche : le dossier est créé s’il n’existe pas.
        try? fm.createDirectory(at: Paths.cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        copyIfDifferent(resources.appending(path: "nuitblanche"), to: Paths.cli)
    }

    /// Remplacement atomique et déjà exécutable : un hook lancé au même instant ne trouve jamais
    /// un fichier à moitié écrit ou non exécutable. Un lien symbolique est suivi (sa cible est mise à jour).
    private static func copyIfDifferent(_ source: URL, to destination: URL) {
        let fm = FileManager.default
        let target = destination.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: source) else { return }
        if let existing = try? Data(contentsOf: target), existing == data { return }
        let temp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).\(getpid()).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o755]) else { return }
        if rename(temp.path, target.path) != 0 { try? fm.removeItem(at: temp) }
    }

    // MARK: Assistant capot fermé (règle sudoers limitée à pmset disablesleep)

    /// Règle présente. (`sudo -l` ne peut pas servir de vérification : sur un compte administrateur il répond
    /// « autorisé » même pour une commande qui exigerait le mot de passe. Un échec réel est signalé à l’usage.)
    static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.sudoers)
    }

    static func installHelper() -> Result<Void, HelperError> {
        let user = NSUserName()
        // Nom d’utilisateur macOS : lettres, chiffres, point, tiret, soulignement. Rien d’autre n’entre dans la règle.
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            return .failure(.message("Nom d’utilisateur inattendu : \(user)"))
        }
        let command = helperInstallCommand(user: user)
        let prompt = "Nuit Blanche a besoin de votre mot de passe pour gérer la veille quand l’écran est rabattu."
        if let error = runAsAdmin(command, prompt: prompt) { return .failure(error) }
        installWatchdog()
        return .success(())
    }

    /// Commande exécutée en root par l’assistant (testable sans root : dossier et propriétaire paramétrables).
    static func helperInstallCommand(user: String, tempDirectory: String = "/var/root",
                                     target: String = Paths.sudoers, ownership: String = "-o root -g wheel") -> String {
        let lines = [
            "# Nuit Blanche : autorise uniquement l’activation et la désactivation de la veille système.",
            "# Pour retirer cette autorisation : « Désinstaller l’assistant » dans Nuit Blanche, ou supprimer ce fichier.",
            "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
        ]
        // Tout se passe dans le shell root : fichier temporaire créé par root (mktemp, 0600), validé par visudo
        // puis installé. Aucun fichier appartenant à l’utilisateur ne peut être échangé entre les deux.
        let printf = lines.map { "printf '%s\\n' \(Shell.quote($0))" }.joined(separator: "; ")
        return [
            "set -e",
            "T=$(/usr/bin/mktemp \(Shell.quote(tempDirectory))/nuitblanche.XXXXXX)",
            "trap '/bin/rm -f \"$T\"' EXIT",
            "{ \(printf); } > \"$T\"",
            "/usr/sbin/visudo -cf \"$T\" >/dev/null",
            "/usr/bin/install -m 0440 \(ownership) \"$T\" \(Shell.quote(target))",
        ].joined(separator: "; ")
    }

    static func uninstallHelper() -> Result<Void, HelperError> {
        let command = "\(SleepControl.pmset) -a disablesleep 0; /bin/rm -f \(Paths.sudoers)"
        let prompt = "Nuit Blanche a besoin de votre mot de passe pour retirer son autorisation."
        if let error = runAsAdmin(command, prompt: prompt) { return .failure(error) }
        try? FileManager.default.removeItem(at: Paths.ownedMarker)
        uninstallWatchdog()
        return .success(())
    }

    enum HelperError: Error {
        case cancelled
        case message(String)

        var text: String? {
            switch self {
            case .cancelled: nil
            case .message(let text): text
            }
        }
    }

    private static func runAsAdmin(_ command: String, prompt: String) -> HelperError? {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .message(errorInfo[NSAppleScript.errorMessage] as? String ?? "L’installation a échoué.")
    }

    // MARK: Watchdog (LaunchAgent utilisateur)

    /// Rétablit la veille si Nuit Blanche plante ou se fige alors qu’elle l’avait désactivée.
    static func installWatchdog() {
        let script = Paths.bin.appending(path: "nuitblanche-watchdog").path
        let plist: [String: Any] = [
            "Label": Paths.watchdogLabel,
            "ProgramArguments": ["/bin/bash", script],
            "RunAtLoad": true,
            "StartInterval": 60,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        try? FileManager.default.createDirectory(
            at: Paths.watchdogPlist.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let domain = "gui/\(getuid())"
        let loaded = Shell.run("/bin/launchctl", ["print", "\(domain)/\(Paths.watchdogLabel)"], timeout: 5).status == 0
        let unchanged = (try? Data(contentsOf: Paths.watchdogPlist)) == data
        // Déjà chargé et identique : rien à faire (le recharger le relancerait au démarrage de l’app).
        guard !(loaded && unchanged) else { return }
        try? data.write(to: Paths.watchdogPlist, options: .atomic)
        if loaded { Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Paths.watchdogLabel)"]) }
        if Shell.run("/bin/launchctl", ["bootstrap", domain, Paths.watchdogPlist.path]).status != 0 {
            // bootout est asynchrone : une seconde tentative après un court délai.
            usleep(500_000)
            Shell.run("/bin/launchctl", ["bootstrap", domain, Paths.watchdogPlist.path])
        }
    }

    static func uninstallWatchdog() {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Paths.watchdogLabel)"])
        try? FileManager.default.removeItem(at: Paths.watchdogPlist)
    }

    static var watchdogInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.watchdogPlist.path)
    }

    // MARK: Hooks Claude Code / Codex

    static func hooksStatus() -> HooksStatus {
        var status = HooksStatus()
        let cliReady = FileManager.default.isExecutableFile(atPath: Paths.cli.path)
        status.claude = cliReady && claudeSettingsFiles().contains { contains($0, "nuitblanche hook claude") }
        let codexDir = Paths.home.appending(path: ".codex")
        status.codexInstalled = FileManager.default.fileExists(atPath: codexDir.path)
        status.codex = cliReady && contains(codexDir.appending(path: "hooks.json"), "nuitblanche hook codex")
        return status
    }

    /// Profils Claude Code : ~/.claude* contenant settings.json ET projects/ (exclut ~/.claude-mem, etc.).
    static func claudeSettingsFiles() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Paths.home.path) else { return [] }
        return entries
            .filter { $0.hasPrefix(".claude") }
            .map { Paths.home.appending(path: $0, directoryHint: .isDirectory) }
            .filter { fm.fileExists(atPath: $0.appending(path: "projects").path) }
            .map { $0.appending(path: "settings.json") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private static func contains(_ url: URL, _ needle: String) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(needle)
    }

    /// /usr/bin/python3 n’est qu’un lanceur tant que les outils Xcode ne sont pas installés (il ouvrirait
    /// la fenêtre d’installation) : on vérifie d’abord qu’un dossier de développeur existe.
    static var pythonAvailable: Bool {
        Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5).status == 0
    }

    /// `target` : "claude" ou "codex". `install` : faux pour retirer les hooks.
    static func setHooks(_ target: String, install: Bool) -> Bool {
        let script = Paths.bin.appending(path: "install-hooks.py").path
        let result = Shell.run("/usr/bin/python3", ["-I", script, install ? "install" : "uninstall", target])
        return result.status == 0
    }

    // MARK: Ouverture au démarrage

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}
