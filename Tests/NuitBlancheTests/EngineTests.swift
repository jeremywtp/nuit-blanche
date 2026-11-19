import Foundation
import AppKit
import Testing
@testable import NuitBlanche

/// Tests du moteur en mode dryRun : aucune assertion IOKit, aucun pmset, aucun fichier, aucune notification.
@MainActor
@Suite("Moteur Nuit Blanche")
struct EngineTests {
    private func makeModel(onAC: Bool = true, battery: Int = 80, hot: Bool = false, helper: Bool = true) -> AppModel {
        let model = AppModel()
        model.dryRun = true
        model.helperInstalled = helper
        model.systemSleepDisabled = false
        model.sessions = []
        model.power = PowerSnapshot(batteryPercent: battery, onAC: onAC, charging: false, lidClosed: false,
                                    thermal: hot ? .serious : .nominal, lowPowerMode: false)
        model.lidModeEnabled = true
        model.agentsAuto = true
        model.agentsMode = .working
        model.graceIndex = 0
        model.batteryFloor = 20
        model.acOnly = false
        model.thermalGuard = true
        return model
    }

    private func session(_ agent: String, _ state: String, until: Date? = nil) -> AgentSession {
        AgentSession(id: "\(agent)-\(UUID().uuidString)", agent: agent, state: state, cwd: "/tmp/projet",
                     pid: 0, updated: Date(), until: until, label: "")
    }

    @Test("Au repos : veille normale, capot fermé inactif")
    func idle() {
        let m = makeModel()
        m.evaluate()
        #expect(m.holding == false)
        #expect(m.lidEffective == false)
    }

    @Test("Caféine illimitée : éveillé, capot fermé autorisé")
    func manualHold() {
        let m = makeModel()
        m.manualActive = true
        m.manualUntil = nil
        m.evaluate()
        #expect(m.holding)
        #expect(m.lidEffective)
        #expect(m.systemSleepDisabled == true)
    }

    @Test("Caféine arrivée à échéance : arrêt automatique")
    func manualExpiry() {
        let m = makeModel()
        m.manualActive = true
        m.manualUntil = Date().addingTimeInterval(-1)
        m.evaluate()
        #expect(m.manualActive == false)
        #expect(m.holding == false)
        #expect(m.systemSleepDisabled == false)
    }

    @Test("Agent au travail : éveillé ; terminé sans délai : veille")
    func agentWorkingThenIdle() {
        let m = makeModel()
        m.sessions = [session("claude", "working")]
        m.evaluate()
        #expect(m.holding)
        m.sessions = [session("claude", "idle")]
        m.evaluate()
        #expect(m.holding == false)
    }

    @Test("Délai avant la veille : maintien pendant la grâce")
    func gracePeriod() {
        let m = makeModel()
        m.graceIndex = 2 // 2 min
        m.sessions = [session("codex", "working")]
        m.evaluate()
        m.sessions = [session("codex", "idle")]
        m.evaluate()
        #expect(m.inGrace)
        #expect(m.holding)
    }

    @Test("Attente d’une validation : compte comme du travail")
    func waitingCountsAsWorking() {
        let m = makeModel()
        m.sessions = [session("claude", "waiting")]
        m.evaluate()
        #expect(m.holding)
    }

    @Test("Mode « session ouverte » : une session inactive suffit")
    func openMode() {
        let m = makeModel()
        m.agentsMode = .open
        m.sessions = [session("claude", "idle")]
        m.evaluate()
        #expect(m.holding)
    }

    @Test("Agents désactivés : une session au travail ne maintient pas")
    func agentsDisabled() {
        let m = makeModel()
        m.agentsAuto = false
        m.sessions = [session("claude", "working")]
        m.evaluate()
        #expect(m.holding == false)
    }

    @Test("Maintien Terminal : actif même agents désactivés")
    func commandHold() {
        let m = makeModel()
        m.agentsAuto = false
        m.sessions = [session("cli", "hold", until: Date().addingTimeInterval(600))]
        m.evaluate()
        #expect(m.holding)
    }

    @Test("Batterie sous le seuil : tout s’arrête, la caféine est suspendue puis reprend")
    func batteryFloor() {
        let m = makeModel(onAC: false, battery: 15)
        m.manualActive = true
        m.sessions = [session("claude", "working")]
        m.evaluate()
        #expect(m.holding == false)
        #expect(m.batteryBlocked)
        // Caféine suspendue, pas annulée : elle reprend au-dessus du seuil.
        #expect(m.manualActive)
        #expect(m.awakeSubtitle == "Suspendue : batterie")
        #expect(m.systemSleepDisabled == false)
        m.power.batteryPercent = 60
        m.evaluate()
        #expect(m.holding)
    }

    @Test("Batterie au-dessus du seuil sur batterie : maintien autorisé")
    func batteryAboveFloor() {
        let m = makeModel(onAC: false, battery: 60)
        m.sessions = [session("claude", "working")]
        m.evaluate()
        #expect(m.holding)
        #expect(m.lidEffective)
    }

    @Test("Secteur uniquement : sur batterie, éveillé mais capot fermé interdit")
    func acOnly() {
        let m = makeModel(onAC: false, battery: 60)
        m.acOnly = true
        m.manualActive = true
        m.evaluate()
        #expect(m.holding)
        #expect(m.acBlocked)
        #expect(m.lidEffective == false)
    }

    @Test("Surchauffe : capot fermé suspendu")
    func thermal() {
        let m = makeModel(hot: true)
        m.manualActive = true
        m.evaluate()
        #expect(m.holding)
        #expect(m.thermalBlocked)
        #expect(m.lidEffective == false)
    }

    @Test("Sans assistant : jamais de capot fermé")
    func noHelper() {
        let m = makeModel(helper: false)
        m.manualActive = true
        m.evaluate()
        #expect(m.holding)
        #expect(m.lidEffective == false)
    }

    @Test("Veille forcée seulement écran rabattu, sans écran externe, veille rétablie")
    func forceSleepDecision() {
        #expect(AppModel.shouldForceSleep(wasRelyingOnLid: true, nowRelying: false, lidClosed: true,
                                          sleepDisabled: false, externalDisplay: false))
        // Écran ouvert : rien à faire.
        #expect(!AppModel.shouldForceSleep(wasRelyingOnLid: true, nowRelying: false, lidClosed: false,
                                           sleepDisabled: false, externalDisplay: false))
        // Écran externe actif : mode bureau voulu, on ne touche à rien.
        #expect(!AppModel.shouldForceSleep(wasRelyingOnLid: true, nowRelying: false, lidClosed: true,
                                           sleepDisabled: false, externalDisplay: true))
        // pmset n’a pas pu rétablir la veille : ne pas lancer une veille vouée à l’échec.
        #expect(!AppModel.shouldForceSleep(wasRelyingOnLid: true, nowRelying: false, lidClosed: true,
                                           sleepDisabled: true, externalDisplay: false))
        // Maintien toujours en cours.
        #expect(!AppModel.shouldForceSleep(wasRelyingOnLid: true, nowRelying: true, lidClosed: true,
                                           sleepDisabled: true, externalDisplay: false))
        // Le capot fermé n’était pas utilisé : macOS a déjà endormi le Mac lui-même.
        #expect(!AppModel.shouldForceSleep(wasRelyingOnLid: false, nowRelying: false, lidClosed: true,
                                           sleepDisabled: false, externalDisplay: false))
    }

    @Test("Caféine coupée pendant qu’un agent travaille : pas de raison d’arrêt fantôme")
    func manualStopWhileAgentWorks() {
        let m = makeModel()
        m.sessions = [session("claude", "working")]
        m.manualActive = true
        m.evaluate()
        m.toggleManual() // coupe la caféine, l’agent maintient toujours le Mac éveillé
        #expect(m.holding)
        #expect(m.pendingEndReason == nil)
    }

    @Test("Menu rapide : la caféine démarre avec la durée choisie")
    func quickMenuDuration() {
        let m = makeModel()
        m.startManual(durationIndex: 1) // 1 h
        #expect(m.manualActive)
        #expect(m.durationIndex == 1)
        let remaining = m.manualUntil.map { $0.timeIntervalSinceNow } ?? 0
        #expect(remaining > 3590 && remaining <= 3600)
        m.startManual(durationIndex: AppModel.durations.count - 1) // illimitée
        #expect(m.manualUntil == nil)
        #expect(m.holding)
    }

    @Test("Session muette : expire après le délai, sauf activité réelle")
    func silentSessions() {
        #expect(!AgentSession.isSilent(state: "working", agent: "claude", silence: 600, hasActivity: false))
        #expect(AgentSession.isSilent(state: "working", agent: "claude", silence: 1000, hasActivity: false))
        #expect(!AgentSession.isSilent(state: "working", agent: "claude", silence: 5000, hasActivity: true))
        #expect(!AgentSession.isSilent(state: "working", agent: "codex", silence: 1000, hasActivity: false))
        #expect(AgentSession.isSilent(state: "working", agent: "codex", silence: 2000, hasActivity: false))
        #expect(!AgentSession.isSilent(state: "idle", agent: "claude", silence: 99_999, hasActivity: false))
        var session = AgentSession(id: "x", agent: "claude", state: "working", cwd: "", pid: 0,
                                   updated: Date(), until: nil, label: "")
        session.silent = true
        #expect(!session.isWorking)
    }

    @Test("Règle sudoers : commande root valide (visudo) et installée")
    func sudoersCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nb-sudoers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "nuitblanche").path
        let command = Setup.helperInstallCommand(user: NSUserName(), tempDirectory: dir.path, target: target, ownership: "")
        let result = Shell.run("/bin/bash", ["-c", command])
        #expect(result.status == 0, "sortie : \(result.output)")
        let rule = try String(contentsOfFile: target, encoding: .utf8)
        #expect(rule.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"))
        #expect(Shell.run("/usr/sbin/visudo", ["-cf", target]).status == 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("nuitblanche.") }
        #expect(leftovers.isEmpty)
    }

    @Test("Shell.run : délai maximal respecté")
    func shellTimeout() {
        let start = Date()
        let result = Shell.run("/bin/sleep", ["10"], timeout: 1)
        #expect(result.status == -1)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("Capot fermé : jamais réarmé écran rabattu sans écran externe")
    func lidArming() {
        #expect(AppModel.canArmLid(alreadyDisabled: false, lidClosed: false, externalDisplay: false))
        #expect(!AppModel.canArmLid(alreadyDisabled: false, lidClosed: true, externalDisplay: false))
        #expect(AppModel.canArmLid(alreadyDisabled: false, lidClosed: true, externalDisplay: true))
        #expect(AppModel.canArmLid(alreadyDisabled: true, lidClosed: true, externalDisplay: false))
        // Session au repos mais commande en arrière-plan : compte comme du travail.
        var session = AgentSession(id: "b", agent: "claude", state: "idle", cwd: "", pid: 0,
                                   updated: Date(), until: nil, label: "")
        #expect(!session.isWorking)
        session.background = true
        #expect(session.isWorking)
    }

    @Test("Formats de durée")
    func durations() {
        #expect(AppModel.format(30) == "30 s")
        #expect(AppModel.format(60) == "1 min")
        #expect(AppModel.format(3600) == "1 h")
        #expect(AppModel.format(5520) == "1 h 32")
    }
}
