import SwiftUI
import Observation
import UserNotifications

enum Screen: Hashable {
    case main, awake, lid, agents, display, settings
}

enum AgentsMode: String {
    /// Le Mac reste éveillé pendant que l’agent répond, puis après le délai choisi.
    case working
    /// Le Mac reste éveillé tant qu’une session est ouverte (pratique avec Remote Control).
    case open
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var trigger: String
    var endReason: String
    var lidClosedSeconds: Double
    var batteryStart: Int?
    var batteryEnd: Int?
}

struct Chip: Equatable {
    enum Action { case installHelper, openLid, openAgents, none }
    var symbol: String
    var color: Color
    var text: String
    var action: Action
}

@MainActor
@Observable
final class AppModel {
    static let durations = [30, 60, 120, 240, 480, 0]
    static let graces = [0, 1, 2, 5, 10, 15]
    static let batteryFloors = Array(stride(from: 5, through: 50, by: 5))

    private enum Keys {
        static let duration = "durationIndex"
        static let keepDisplay = "keepDisplayOn"
        static let lidMode = "lidModeEnabled"
        static let agentsAuto = "agentsAuto"
        static let agentsMode = "agentsMode"
        static let grace = "graceIndex"
        static let batteryFloor = "batteryFloor"
        static let acOnly = "acOnly"
        static let thermalGuard = "thermalGuard"
        static let showTime = "showTimeInMenuBar"
        static let notifications = "notificationsEnabled"
        static let hotkey = "hotkeyEnabled"
        static let firstLaunch = "didFirstLaunch"
        static let resume = "resumeManualHold"
    }

    // MARK: Dépendances et état interne

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let assertions = Assertions()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onHeightChange: ((CGFloat) -> Void)?
    @ObservationIgnored var onHotkeyChange: ((Bool) -> Void)?
    @ObservationIgnored var closePanel: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSystemCheck = Date.distantPast
    @ObservationIgnored private var lastApplyFailure = Date.distantPast
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var lastAgentActivity: Date?
    @ObservationIgnored private var holdStart: Date?
    @ObservationIgnored private var holdTrigger = ""
    @ObservationIgnored private var holdBatteryStart: Int?
    @ObservationIgnored private var holdLidSeconds: Double = 0
    /// Raison d’arrêt notée par une action, appliquée si le maintien s’arrête dans la foulée (lisible par les tests).
    @ObservationIgnored private(set) var pendingEndReason: String?
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var lastStateText = ""
    @ObservationIgnored private var lastStateJSON = Data()
    @ObservationIgnored private var thermalNotified = false
    @ObservationIgnored private var batteryNotified = false
    /// Un blocage batterie a eu lieu : l’alerte reste visible jusqu’au branchement ou à la recharge.
    @ObservationIgnored private var batteryLatched = false
    /// Veille à demander dès que pmset confirme la veille rétablie (écran rabattu, sans écran externe).
    @ObservationIgnored private var forceSleepPending = false
    /// Arrêt par signal (mise à jour, relance) : la caféine en cours reprendra au redémarrage de l’app.
    @ObservationIgnored var relaunchExpected = false
    /// Caféine lancée avec l’une des durées proposées (coche du menu rapide), et non par URL avec une durée libre.
    @ObservationIgnored var manualPreset = true
    @ObservationIgnored private var persistedManual = ""
    @ObservationIgnored private var lastDesiredSleepDisabled = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// Mode aperçu : calcule l’état sans toucher au système (assertions, pmset, fichiers, notifications).
    @ObservationIgnored var dryRun = false
    /// Détection d’écran externe (remplaçable par les tests, qui ne doivent pas dépendre de l’écran branché).
    @ObservationIgnored var externalDisplayProbe: () -> Bool = { DisplayInfo.externalDisplayActive() }

    /// Bulles d’explication au survol (fermées au changement d’écran).
    @ObservationIgnored let tips = TipCenter()
    var screen: Screen = .main {
        didSet { if oldValue != screen { tips.reset() } }
    }
    /// Variante de verre des modules (réglable en direct pour calibrer : nuitblanche://debug/glass?modules=clear).
    var liquidGlass = true

    // MARK: Réglages (persistés)

    var durationIndex: Int {
        didSet {
            guard oldValue != durationIndex else { return }
            defaults.set(durationIndex, forKey: Keys.duration)
            if manualActive { restartManualTimer() }
            evaluate()
        }
    }
    var keepDisplayOn: Bool { didSet { defaults.set(keepDisplayOn, forKey: Keys.keepDisplay); evaluate() } }
    var lidModeEnabled: Bool { didSet { defaults.set(lidModeEnabled, forKey: Keys.lidMode); evaluate() } }
    var agentsAuto: Bool {
        didSet {
            defaults.set(agentsAuto, forKey: Keys.agentsAuto)
            if !agentsAuto {
                lastAgentActivity = nil
                if holding && !manualActive { pendingEndReason = "Agents désactivés" }
            }
            evaluate()
        }
    }
    var agentsMode: AgentsMode { didSet { defaults.set(agentsMode.rawValue, forKey: Keys.agentsMode); evaluate() } }
    var graceIndex: Int { didSet { defaults.set(graceIndex, forKey: Keys.grace); evaluate() } }
    var batteryFloor: Int { didSet { defaults.set(batteryFloor, forKey: Keys.batteryFloor); evaluate() } }
    var acOnly: Bool { didSet { defaults.set(acOnly, forKey: Keys.acOnly); evaluate() } }
    var thermalGuard: Bool { didSet { defaults.set(thermalGuard, forKey: Keys.thermalGuard); evaluate() } }
    var showTimeInMenuBar: Bool { didSet { defaults.set(showTimeInMenuBar, forKey: Keys.showTime); onChange?() } }
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notifications)
            if notificationsEnabled { Self.requestNotificationAuthorization() }
        }
    }
    var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Keys.hotkey); onHotkeyChange?(hotkeyEnabled) }
    }
    var launchAtLogin: Bool
    /// Raccourci ⌃⌥⌘N réellement enregistré (faux s’il est déjà pris par une autre app).
    var hotkeyAvailable = true
    /// Notifications bloquées par macOS alors que l’option est activée.
    var notificationsDenied = false

    // MARK: État d’exécution

    /// Horloge de la logique : non observée, pour ne pas redessiner l’interface à chaque passage du minuteur.
    @ObservationIgnored var now = Date()
    /// Horloge d’affichage : avance seulement quand le panneau est visible.
    var displayNow = Date()
    /// Panneau ouvert : active l’horloge d’affichage et les animations de symboles.
    var panelVisible = false {
        didSet { if panelVisible { displayNow = Date() } else { tips.reset() } }
    }
    var manualActive = false
    var manualUntil: Date?
    var sessions: [AgentSession] = []
    var power = PowerSnapshot()
    var systemSleepDisabled: Bool?
    var helperInstalled = false
    var hooks = HooksStatus()
    var holding = false
    var lidEffective = false
    var inGrace = false
    var graceRemaining: TimeInterval {
        guard inGrace, let last = lastAgentActivity else { return 0 }
        return max(0, (Double(Self.graces[graceIndex] * 60) - clock.timeIntervalSince(last)).rounded(.up))
    }
    var batteryBlocked = false
    var thermalBlocked = false
    var acBlocked = false
    var lastError: String?
    /// Écran qui explique l’erreur en cours (capot fermé par défaut, agents pour les hooks).
    @ObservationIgnored var lastErrorScreen: Screen = .lid
    var history: [HistoryEntry] = []
    var busy = false

    init() {
        defaults.register(defaults: [
            Keys.duration: 5,
            Keys.keepDisplay: false,
            Keys.lidMode: true,
            Keys.agentsAuto: true,
            Keys.agentsMode: AgentsMode.working.rawValue,
            Keys.grace: 2,
            Keys.batteryFloor: 20,
            Keys.acOnly: false,
            Keys.thermalGuard: true,
            Keys.showTime: true,
            Keys.notifications: true,
            Keys.hotkey: true,
        ])
        durationIndex = min(max(defaults.integer(forKey: Keys.duration), 0), Self.durations.count - 1)
        keepDisplayOn = defaults.bool(forKey: Keys.keepDisplay)
        lidModeEnabled = defaults.bool(forKey: Keys.lidMode)
        agentsAuto = defaults.bool(forKey: Keys.agentsAuto)
        agentsMode = AgentsMode(rawValue: defaults.string(forKey: Keys.agentsMode) ?? "") ?? .working
        graceIndex = min(max(defaults.integer(forKey: Keys.grace), 0), Self.graces.count - 1)
        batteryFloor = defaults.integer(forKey: Keys.batteryFloor)
        acOnly = defaults.bool(forKey: Keys.acOnly)
        thermalGuard = defaults.bool(forKey: Keys.thermalGuard)
        showTimeInMenuBar = defaults.bool(forKey: Keys.showTime)
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        hotkeyEnabled = defaults.bool(forKey: Keys.hotkey)
        launchAtLogin = Setup.launchAtLogin
        history = Self.loadHistory()
    }

    // MARK: Cycle de vie

    func start() {
        if !defaults.bool(forKey: Keys.firstLaunch) {
            defaults.set(true, forKey: Keys.firstLaunch)
            if Setup.setLaunchAtLogin(true) { launchAtLogin = Setup.launchAtLogin }
        }
        if notificationsEnabled { Self.requestNotificationAuthorization() }
        // Âge du battement laissé par l’instance précédente (lu avant d’écrire le nôtre) : une coupure récente
        // (plantage, relance) autorise la reprise de la caféine.
        let previousHeartbeat = (try? FileManager.default.attributesOfItem(atPath: Paths.heartbeat.path))?[.modificationDate] as? Date
        writeHeartbeat(force: true) // avant tout : le watchdog ne doit pas prendre la nouvelle instance pour figée
        restoreManualHold(previousHeartbeat: previousHeartbeat)
        refreshSystem()
        // Instance précédente plantée pendant un maintien capot fermé : on hérite de son état, pour rendormir
        // le Mac fermé si le maintien a pris fin pendant la coupure.
        if FileManager.default.fileExists(atPath: Paths.ownedMarker.path) && systemSleepDisabled == true {
            lastDesiredSleepDisabled = true
        }
        if helperInstalled { Setup.installWatchdog() }
        tick()
        // Une app sans fenêtre peut être mise en sieste (App Nap) écran rabattu : la surveillance
        // prendrait des minutes de retard. Cette activité l’empêche sans bloquer la veille.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Surveillance des agents et de la veille"
        )
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func shutdown() {
        timer?.invalidate()
        // « Quitter » ou fermeture de session : la caféine ne doit pas revenir. Relance : elle reprend (si rapide).
        if !relaunchExpected {
            defaults.removeObject(forKey: Keys.resume)
        } else if var saved = defaults.dictionary(forKey: Keys.resume) {
            saved["at"] = Date().timeIntervalSince1970
            defaults.set(saved, forKey: Keys.resume)
        }
        // Une relance (mise à jour) n’est pas une vraie fin : le maintien reprend, rien à inscrire à l’historique.
        if holding && !relaunchExpected {
            pendingEndReason = "Nuit Blanche quittée"
            recordHoldEnd()
        }
        assertions.releaseAll()
        // Relance (mise à jour, signal) : on ne touche ni à la veille, ni au marqueur, ni au battement.
        // La nouvelle instance reprend la main (même écran rabattu) ; si elle ne revient pas, le watchdog
        // rétablit la veille en une minute.
        if relaunchExpected {
            writeState(force: true, quitting: true)
            return
        }
        if FileManager.default.fileExists(atPath: Paths.ownedMarker.path) {
            if SleepControl.setSleepDisabled(false) {
                try? FileManager.default.removeItem(at: Paths.ownedMarker)
                // Écran rabattu sans écran externe : rétablir la veille ne la relance pas, on la demande.
                if PowerInfo.clamshellClosed() && !DisplayInfo.externalDisplayActive() {
                    SleepControl.sleepNow()
                }
            }
        }
        try? FileManager.default.removeItem(at: Paths.heartbeat)
        writeState(force: true, quitting: true)
    }

    /// Une mise à jour ou un redémarrage de l’app ne doit pas couper la caféine en cours.
    /// Caféine mémorisée en continu (à chaque changement) : après un plantage, le watchdog relance l’app et la
    /// caféine reprend. « Quitter » et la fermeture de session l’effacent ; un redémarrage du Mac l’invalide.
    private func persistManualHold() {
        let signature = manualActive ? "on-\(manualUntil?.timeIntervalSince1970 ?? 0)" : "off"
        guard signature != persistedManual else { return }
        persistedManual = signature
        if manualActive {
            defaults.set(["until": manualUntil?.timeIntervalSince1970 ?? 0, "boot": Self.bootID()], forKey: Keys.resume)
        } else {
            defaults.removeObject(forKey: Keys.resume)
        }
    }

    /// Rapport de plantage de Nuit Blanche écrit par macOS après cette date.
    nonisolated static func crashReportExists(after date: Date) -> Bool {
        let folder = Paths.home.appending(path: "Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.contains { url in
            url.lastPathComponent.hasPrefix("NuitBlanche") && url.pathExtension == "ips"
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > date
        }
    }

    /// Identifiant du démarrage en cours (kern.bootsessionuuid) : une caféine ne survit pas à un redémarrage.
    /// (L’heure de démarrage bouge quand l’horloge est recalée ; cet identifiant, non.)
    nonisolated static func bootID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// Reprise après une relance (mise à jour) ou un plantage, jamais après un redémarrage du Mac.
    /// Reprise seulement après une coupure récente (moins de 10 min) : relance par signal (« at ») ou
    /// plantage (battement de l’instance précédente). Jamais après un redémarrage du Mac.
    private func restoreManualHold(previousHeartbeat: Date?) {
        let recentRelaunch = (defaults.dictionary(forKey: Keys.resume)?["at"] as? Double)
            .map { Date().timeIntervalSince1970 - $0 < 600 } ?? false
        // Plantage : battement récent ET rapport de plantage macOS écrit après lui (« Forcer à quitter » n’en
        // laisse pas : la décision de l’utilisateur est respectée).
        let recentCrash = previousHeartbeat.map { beat in
            Date().timeIntervalSince(beat) < 600 && Self.crashReportExists(after: beat.addingTimeInterval(-5))
        } ?? false
        guard let saved = defaults.dictionary(forKey: Keys.resume),
              let boot = saved["boot"] as? String, !boot.isEmpty, boot == Self.bootID(),
              recentRelaunch || recentCrash else {
            defaults.removeObject(forKey: Keys.resume)
            return
        }
        let until = saved["until"] as? Double ?? 0
        if until > 0 && until <= Date().timeIntervalSince1970 {
            defaults.removeObject(forKey: Keys.resume)
            return
        }
        manualActive = true
        manualUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
    }

    func tick() {
        now = Date()
        if panelVisible { displayNow = now }
        let snapshot = PowerInfo.snapshot()
        if snapshot != power { power = snapshot }
        let loaded = SessionStore.load(now: now)
        if loaded != sessions { sessions = loaded }
        if now.timeIntervalSince(lastSystemCheck) > 30 { refreshSystem() }
        evaluate()
        lastTick = now
    }

    /// Réveil du Mac : une demande de veille restée en suspens (mode bureau, écran pas encore détecté)
    /// ne doit pas rendormir un Mac qu’on vient de réveiller.
    func didWake() {
        forceSleepPending = false
        refreshSystem()
        tick()
    }

    func refreshSystem() {
        update(\.systemSleepDisabled, SleepControl.isSleepDisabled())
        update(\.helperInstalled, Setup.helperInstalled)
        update(\.hooks, Setup.hooksStatus())
        update(\.launchAtLogin, Setup.launchAtLogin)
        lastSystemCheck = Date()
    }

    func panelDidOpen() {
        refreshNotificationStatus()
        refreshSystem()
        tick()
    }

    // MARK: Moteur

    var workingSessions: [AgentSession] { sessions.filter { $0.isAgent && $0.isWorking } }
    var agentSessions: [AgentSession] { sessions.filter(\.isAgent) }
    var commandHolds: [AgentSession] { sessions.filter(\.isCommandHold) }

    func evaluate() {
        now = Date()

        // 1. Maintien manuel arrivé à échéance.
        if manualActive, let until = manualUntil, now >= until {
            manualActive = false
            manualUntil = nil
            pendingEndReason = "Durée écoulée"
            notify("Fin du maintien", "La durée choisie est écoulée : le Mac peut de nouveau se mettre en veille.")
        }

        // 2. Agents (avec délai de grâce après la fin du travail).
        let agentsActive = agentsAuto && agentSessions.contains { agentsMode == .open || $0.isWorking }
        if agentsActive { lastAgentActivity = now }
        let grace = Double(Self.graces[graceIndex] * 60)
        if agentsAuto, !agentsActive, let last = lastAgentActivity, now.timeIntervalSince(last) < grace {
            update(\.inGrace, true)
        } else {
            update(\.inGrace, false)
        }
        let agentsHolding = agentsActive || inGrace
        let commandHolding = !commandHolds.isEmpty
        var want = manualActive || agentsHolding || commandHolding

        // 3. Garde-fou batterie : sur batterie et sous le seuil, on rend la main à la veille.
        // Sur batterie, ou sur secteur sans charge (chargeur trop faible) : le seuil s’applique.
        let lowBattery = (!power.onAC || !power.charging) && (power.batteryPercent ?? 100) <= batteryFloor
        if !lowBattery { batteryLatched = false }
        update(\.batteryBlocked, lowBattery && (want || batteryLatched))
        if lowBattery && want {
            batteryLatched = true
            if !batteryNotified {
                batteryNotified = true
                let level = power.batteryPercent.map { "\($0) %" } ?? "faible"
                notify("Batterie \(level)", "Nuit Blanche laisse le Mac se mettre en veille pour protéger la batterie. La caféine reprendra au-dessus du seuil.")
            }
            // La caféine est suspendue, pas annulée : elle reprend quand la batterie repasse au-dessus du seuil
            // (sinon un simple réglage du curseur l’annulait pour de bon).
            if holding { pendingEndReason = "Batterie faible" }
            want = false
        }
        if !lowBattery { batteryNotified = false }

        // 4. Capot fermé : autorisé seulement si l’assistant est là et que la sécurité le permet.
        update(\.thermalBlocked, thermalGuard && power.isHot)
        update(\.acBlocked, acOnly && !power.onAC)
        if thermalBlocked && want && lidModeEnabled && !thermalNotified {
            thermalNotified = true
            notify("Mac trop chaud", "Le mode capot fermé est suspendu jusqu’à ce que le Mac refroidisse.")
        }
        if !thermalBlocked { thermalNotified = false }
        let lidAllowed = lidModeEnabled && helperInstalled && !thermalBlocked && !acBlocked
        // Une fois la veille rétablie, on ne la rebloque pas écran rabattu sans écran externe : un réveil bref
        // (Power Nap) ne doit pas garder éveillé un Mac rangé dans un sac. Ouvrir l’écran réarme le capot fermé.
        let canArmLid = Self.canArmLid(alreadyDisabled: systemSleepDisabled == true, lidClosed: power.lidClosed,
                                       externalDisplay: power.lidClosed && externalDisplayProbe())
        let desiredSleepDisabled = want && lidAllowed && canArmLid

        // 5. Application : assertions (comme caffeinate) + pmset disablesleep.
        let wasRelyingOnLid = lastDesiredSleepDisabled
        lastDesiredSleepDisabled = desiredSleepDisabled
        if dryRun {
            if helperInstalled { update(\.systemSleepDisabled, desiredSleepDisabled) }
        } else {
            assertions.set(Assertions.idleSystem, want)
            // PreventSystemSleep peut maintenir un « dark wake » écran rabattu sur secteur :
            // on ne le prend que si le mode capot fermé est autorisé, sinon rabattre l’écran doit endormir le Mac.
            assertions.set(Assertions.system, desiredSleepDisabled)
            assertions.set(Assertions.idleDisplay, want && keepDisplayOn)
            if helperInstalled, systemSleepDisabled != desiredSleepDisabled,
               now.timeIntervalSince(lastApplyFailure) > 30 {
                applySleepDisabled(desiredSleepDisabled)
            }
            // Le maintien s’appuie sur disablesleep, même posé avant l’app : on en devient responsable
            // (le watchdog le retirera si l’app plante).
            if desiredSleepDisabled && systemSleepDisabled == true { markOwnership(true) }
            // Retirer disablesleep écran rabattu ne relance pas la veille (macOS ne la déclenche qu’à la fermeture).
            // On la demande nous-mêmes, sauf en mode bureau (écran externe actif).
            if wasRelyingOnLid && !desiredSleepDisabled && power.lidClosed { forceSleepPending = true }
            if desiredSleepDisabled || !power.lidClosed { forceSleepPending = false }
            // Mode bureau (écran externe branché) : la veille forcée n’a pas lieu d’être, on oublie la demande.
            if forceSleepPending && externalDisplayProbe() { forceSleepPending = false }
            if forceSleepPending,
               Self.shouldForceSleep(wasRelyingOnLid: true, nowRelying: desiredSleepDisabled,
                                     lidClosed: power.lidClosed, sleepDisabled: systemSleepDisabled,
                                     externalDisplay: DisplayInfo.externalDisplayActive()) {
                forceSleepPending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.lastDesiredSleepDisabled else { return }
                    if PowerInfo.clamshellClosed() && !DisplayInfo.externalDisplayActive() {
                        SleepControl.sleepNow()
                    }
                }
            }
        }
        update(\.lidEffective, desiredSleepDisabled && systemSleepDisabled == true)

        // 6. Historique.
        if want && !holding {
            holdStart = now
            holdTrigger = manualActive ? "Manuel" : (commandHolding ? "Terminal" : "Agents")
            holdBatteryStart = power.batteryPercent
            holdLidSeconds = 0
        }
        if want && power.lidClosed { holdLidSeconds += min(10, max(0, now.timeIntervalSince(lastTick))) }
        if !want && holding {
            if pendingEndReason == nil {
                pendingEndReason = holdTrigger == "Agents" ? "Agents terminés" : "Fin du maintien"
            }
            recordHoldEnd()
        }
        update(\.holding, want)
        // Le maintien continue (un agent travaille encore, par exemple) : la raison d’arrêt notée par une action
        // (« Arrêt manuel »…) ne concerne pas ce maintien-là ; sans cela, elle serait attribuée au suivant.
        if want { pendingEndReason = nil }

        guard !dryRun else { return }
        persistManualHold()
        heartbeat()
        writeState()
        onChange?()
    }

    /// Le capot fermé ne se réarme pas écran déjà rabattu sans écran externe (réveil bref dans un sac).
    static func canArmLid(alreadyDisabled: Bool, lidClosed: Bool, externalDisplay: Bool) -> Bool {
        alreadyDisabled || !lidClosed || externalDisplay
    }

    /// Fin d’un maintien écran rabattu : retirer disablesleep ne relance pas la veille, il faut la demander.
    /// Jamais avec un écran externe actif (mode bureau voulu), ni si la veille système est encore bloquée.
    static func shouldForceSleep(wasRelyingOnLid: Bool, nowRelying: Bool, lidClosed: Bool,
                                 sleepDisabled: Bool?, externalDisplay: Bool) -> Bool {
        wasRelyingOnLid && !nowRelying && lidClosed && sleepDisabled == false && !externalDisplay
    }

    /// Assigne seulement si la valeur change : une assignation identique redessinerait quand même l’interface.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func markOwnership(_ owned: Bool) {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: Paths.ownedMarker.path)
        if owned && !exists {
            fm.createFile(atPath: Paths.ownedMarker.path, contents: Data())
        } else if !owned && exists {
            try? fm.removeItem(at: Paths.ownedMarker)
        }
    }

    private func applySleepDisabled(_ disabled: Bool) {
        if SleepControl.setSleepDisabled(disabled) {
            update(\.systemSleepDisabled, disabled)
            markOwnership(disabled)
            if !disabled && power.lidClosed { forceSleepPending = true }
            update(\.lastError, nil)
        } else {
            lastApplyFailure = now
            helperInstalled = Setup.helperInstalled
            lastError = helperInstalled
                ? "Veille non modifiable : réinstallez l’assistant."
                : "L’assistant capot fermé n’est plus installé."
            lastErrorScreen = .lid
        }
    }

    private func recordHoldEnd() {
        guard let start = holdStart else { return }
        let entry = HistoryEntry(
            start: start, end: now, trigger: holdTrigger,
            endReason: pendingEndReason ?? "Fin du maintien",
            lidClosedSeconds: holdLidSeconds,
            batteryStart: holdBatteryStart, batteryEnd: power.batteryPercent
        )
        pendingEndReason = nil
        holdStart = nil
        guard entry.end.timeIntervalSince(entry.start) >= 60, !dryRun else { return }
        history.insert(entry, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        Self.saveHistory(history)
    }

    // MARK: Actions

    func toggleManual() {
        if manualActive {
            pendingEndReason = "Arrêt manuel"
            manualActive = false
            manualUntil = nil
        } else {
            manualActive = true
            restartManualTimer()
        }
        evaluate()
    }

    private func restartManualTimer() {
        let minutes = Self.durations[durationIndex]
        manualUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
    }

    /// Démarre (ou redémarre) la caféine avec l’une des durées proposées.
    func startManual(durationIndex index: Int) {
        durationIndex = min(max(index, 0), Self.durations.count - 1)
        manualPreset = true
        manualActive = true
        restartManualTimer()
        evaluate()
    }

    func setManualHold(minutes: Int?) {
        manualPreset = false
        manualActive = true
        manualUntil = minutes.flatMap { $0 > 0 ? Date().addingTimeInterval(Double($0) * 60) : nil }
        evaluate()
    }

    func stopEverything() {
        if holding { pendingEndReason = "Arrêt depuis le Terminal" }
        if manualActive {
            manualActive = false
            manualUntil = nil
        }
        SessionStore.removeCommandHolds()
        tick()
    }

    func toggleLidMode() {
        if !helperInstalled {
            installHelper()
        } else {
            lidModeEnabled.toggle()
        }
    }

    func installHelper() {
        closePanel?()
        busy = true
        defer { busy = false }
        writeHeartbeat(ahead: 600) // la fenêtre du mot de passe bloque l’app : pas de fausse alerte de gel
        switch Setup.installHelper() {
        case .success:
            lidModeEnabled = true
            lastError = nil
            refreshSystem()
            evaluate()
            notify("Mode capot fermé prêt", "Vous pouvez rabattre l’écran pendant un maintien : le travail continue.")
        case .failure(let error):
            if let text = error.text { lastError = text }
        }
    }

    func uninstallHelper() {
        closePanel?()
        writeHeartbeat(ahead: 600)
        switch Setup.uninstallHelper() {
        case .success:
            refreshSystem()
            evaluate()
        case .failure(let error):
            if let text = error.text { lastError = text }
        }
    }

    func setHooks(_ target: String, install: Bool) {
        if !Setup.pythonAvailable {
            lastError = "Installez les outils Xcode (xcode-select --install) pour connecter les agents."
            lastErrorScreen = .agents
        } else if !Setup.setHooks(target, install: install) {
            lastError = "Les hooks \(target == "claude" ? "Claude Code" : "Codex") n’ont pas pu être modifiés."
            lastErrorScreen = .agents
        } else if lastErrorScreen == .agents {
            lastError = nil
        }
        hooks = Setup.hooksStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if !Setup.setLaunchAtLogin(enabled) {
            lastError = "macOS a refusé de modifier l’ouverture au démarrage."
        }
        launchAtLogin = Setup.launchAtLogin
    }

    func sleepDisplay() {
        closePanel?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            SleepControl.displaySleepNow()
        }
    }

    func handle(_ chip: Chip) {
        switch chip.action {
        case .installHelper: installHelper()
        case .openLid: screen = .lid
        case .openAgents: screen = .agents
        case .none: break
        }
    }

    // MARK: Textes de l’interface

    /// Heure utilisée par les textes : horloge d’affichage panneau ouvert (dépendance observée), logique sinon.
    private var clock: Date { panelVisible ? displayNow : now }

    var statusTitle: String { holding ? "Éveillé" : "Veille normale" }

    var statusDetail: String {
        if holding {
            if manualActive {
                if let until = manualUntil { return "Encore \(Self.format(until.timeIntervalSince(clock)))" }
                return "Jusqu’à nouvel ordre"
            }
            let working = workingSessions
            if working.count == 1 { return "\(working[0].agentName) travaille" }
            if working.count > 1 { return "\(working.count) agents au travail" }
            if agentsMode == .open && !agentSessions.isEmpty {
                return agentSessions.count == 1 ? "1 session ouverte" : "\(agentSessions.count) sessions ouvertes"
            }
            if !commandHolds.isEmpty { return "Demandé depuis le Terminal" }
            if inGrace { return "Veille dans \(Self.format(graceRemaining))" }
            return "Maintien actif"
        }
        if batteryBlocked { return "Batterie sous \(batteryFloor) %" }
        if agentsAuto { return "Prêt pour les agents" }
        return "Le Mac dort normalement"
    }

    var awakeSubtitle: String {
        guard manualActive else { return "Désactivée" }
        if batteryBlocked { return "Suspendue : batterie" }
        if let until = manualUntil { return "Active, encore \(Self.format(until.timeIntervalSince(clock)))" }
        return "Active, sans limite"
    }

    var lidSubtitle: String {
        if !helperInstalled { return "À installer" }
        if !lidModeEnabled { return "Désactivé" }
        if thermalBlocked { return "Suspendu : Mac chaud" }
        if acBlocked { return "Suspendu : sur batterie" }
        if lidEffective { return power.lidClosed ? "Actif, écran rabattu" : "Actif maintenant" }
        return "Prêt, aucun maintien"
    }

    var agentsSubtitle: String {
        if !agentsAuto { return "Désactivé" }
        if !hooks.claude && !hooks.codex { return "À connecter" }
        let working = workingSessions
        if working.count == 1 { return "\(working[0].shortName) travaille" }
        if working.count > 1 { return "\(working.count) agents au travail" }
        if inGrace { return "Veille dans \(Self.format(graceRemaining))" }
        let open = agentSessions.count
        if open == 0 { return "Prêt, aucune session" }
        if agentsMode == .open { return open == 1 ? "1 session ouverte" : "\(open) sessions ouvertes" }
        return "Prêt, en attente"
    }

    var displaySubtitle: String {
        keepDisplayOn ? "Reste allumé" : "S’éteint seul"
    }

    /// Ligne du bas du module état : l’information la plus utile, écrite en toutes lettres.
    var statusIndicator: (symbol: String, text: String, color: Color, tip: String) {
        if batteryBlocked {
            return ("battery.25percent", "Batterie faible", .red,
                    "Batterie sous \(batteryFloor) % : Nuit Blanche laisse le Mac se mettre en veille.")
        }
        if thermalBlocked && lidModeEnabled {
            return ("thermometer.high", "Mac chaud", .orange,
                    "Le Mac chauffe : le capot fermé est suspendu jusqu’à ce qu’il refroidisse.")
        }
        if lidEffective {
            return ("macbook", "Écran rabattable", .green,
                    "Vous pouvez rabattre l’écran : le Mac continue de travailler.")
        }
        if holding {
            let why = !helperInstalled ? "l’assistant capot fermé n’est pas installé"
                : !lidModeEnabled ? "le capot fermé est désactivé"
                : acBlocked ? "le capot fermé est réservé au secteur"
                : "la veille n’a pas pu être bloquée"
            return ("macbook", "Ne pas rabattre", .secondary,
                    "Le Mac est éveillé mais \(why) : rabattre l’écran le mettrait en veille.")
        }
        return ("macbook", "Veille si rabattu", .secondary,
                "Aucun maintien : rabattre l’écran met le Mac en veille, comme d’habitude.")
    }

    var durationLabel: String {
        let minutes = Self.durations[durationIndex]
        return minutes == 0 ? "Illimitée" : Self.format(Double(minutes) * 60)
    }

    var chip: Chip? {
        if batteryBlocked {
            return Chip(symbol: "battery.25percent", color: .red, text: "Batterie faible : veille rétablie", action: .none)
        }
        if thermalBlocked && lidModeEnabled && holding {
            return Chip(symbol: "thermometer.high", color: .orange, text: "Mac chaud : capot fermé suspendu", action: .openLid)
        }
        if !helperInstalled && systemSleepDisabled == true {
            return Chip(symbol: "exclamationmark", color: .orange, text: "Veille désactivée en permanence", action: .openLid)
        }
        if let lastError {
            return Chip(symbol: "exclamationmark", color: .red, text: lastError,
                        action: lastErrorScreen == .agents ? .openAgents : .openLid)
        }
        if let first = workingSessions.first {
            let others = workingSessions.count - 1
            let text = others > 0 ? "\(first.agentName) + \(others) au travail" : "\(first.agentName) · \(first.project)"
            return Chip(symbol: first.symbol, color: .purple, text: text, action: .openAgents)
        }
        return nil
    }

    var menuBarSymbol: String { holding ? "moon.stars.fill" : "moon.zzz" }

    var menuBarTitle: String? {
        guard showTimeInMenuBar, manualActive, let until = manualUntil else { return nil }
        let total = max(0, Int(until.timeIntervalSince(Date()).rounded(.up)))
        let minutes = (total + 59) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let minutes = (total + 59) / 60
        if total < 60 { return "\(total) s" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
    }

    // MARK: Notifications

    /// Vérifie si macOS autorise vraiment les notifications (sinon l’interrupteur mentirait).
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                guard let self, self.notificationsDenied != denied else { return }
                self.notificationsDenied = denied
            }
        }
    }

    static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        guard notificationsEnabled, !dryRun else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Fichiers d’état (CLI, watchdog)

    private func heartbeat() {
        guard now.timeIntervalSince(lastHeartbeat) > 20 else { return }
        writeHeartbeat()
    }

    /// Battement de cœur lu par le watchdog. `ahead` : daté dans le futur avant une attente bloquante
    /// (fenêtre du mot de passe administrateur), pour que le watchdog ne prenne pas l’app pour figée.
    private func writeHeartbeat(force: Bool = false, ahead: TimeInterval = 0) {
        let date = Date().addingTimeInterval(ahead)
        lastHeartbeat = Date()
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.heartbeat.path) {
            fm.createFile(atPath: Paths.heartbeat.path, contents: Data())
        }
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: Paths.heartbeat.path)
    }

    private func writeState(force: Bool = false, quitting: Bool = false) {
        var lines: [String] = []
        if quitting {
            lines.append("Nuit Blanche est fermée.")
        } else {
            lines.append("\(statusTitle) : \(statusDetail)")
            lines.append("Capot fermé : \(lidEffective ? "autorisé (pmset disablesleep 1)" : (helperInstalled ? "veille normale" : "assistant non installé"))")
            let battery = power.batteryPercent.map { "\($0) %" } ?? "n/d"
            lines.append("Batterie : \(battery)\(power.onAC ? " (secteur)" : " (sur batterie)") · seuil \(batteryFloor) %")
            lines.append("Agents : \(agentsAuto ? (agentsMode == .working ? "pendant le travail" : "tant qu’une session est ouverte") : "désactivé")")
            for s in sessions {
                lines.append("  · \(s.agentName) — \(s.project) — \(s.stateLabel)")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        if force || text != lastStateText {
            lastStateText = text
            try? text.write(to: Paths.stateText, atomically: true, encoding: .utf8)
        }
        let json: [String: Any] = [
            "running": !quitting,
            "holding": holding && !quitting,
            "detail": statusDetail,
            "lidClosedAllowed": lidEffective && !quitting,
            "manual": manualActive,
            "until": manualUntil?.timeIntervalSince1970 ?? 0,
            "battery": power.batteryPercent ?? -1,
            "onAC": power.onAC,
            "sessions": sessions.count,
            "working": workingSessions.count,
            "helperInstalled": helperInstalled,
            "lidModeEnabled": lidModeEnabled,
            "agentsAuto": agentsAuto,
            "hotkeyAvailable": !hotkeyEnabled || hotkeyAvailable,
            "notificationsBlocked": notificationsEnabled && notificationsDenied,
            "launchAtLogin": launchAtLogin,
            "systemSleepDisabled": systemSleepDisabled ?? false,
        ]
        // Écrit seulement si le contenu change (le texte et le JSON n’ont pas exactement les mêmes champs).
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           force || data != lastStateJSON {
            lastStateJSON = data
            try? data.write(to: Paths.stateJSON, options: .atomic)
        }
    }

    // MARK: Historique

    private static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: Paths.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private static func saveHistory(_ history: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(history) {
            try? data.write(to: Paths.history, options: .atomic)
        }
    }
}

