import Foundation

/// Une session d’agent (Claude Code, Codex) ou un maintien demandé depuis le Terminal.
/// Écrite par le script `nuitblanche` (hooks ou CLI) dans ~/Library/Application Support/NuitBlanche/sessions.
struct AgentSession: Identifiable, Equatable {
    let id: String
    let agent: String
    let state: String
    let cwd: String
    let pid: Int32
    let updated: Date
    let until: Date?
    let label: String
    /// « Au travail » d’après le dernier hook, mais muette depuis trop longtemps (voir `isSilent`).
    var silent = false
    /// Au repos d’après les hooks, mais une commande lancée par l’agent tourne encore (arrière-plan).
    var background = false

    var isAgent: Bool { agent == "claude" || agent == "codex" }
    var isCommandHold: Bool { agent == "cli" || agent == "cmd" }
    var isWorking: Bool { ((state == "working" || state == "waiting") && !silent) || background }

    /// Une interruption (Échap) n’envoie aucun hook : sans ce garde-fou, la session resterait « au travail »
    /// et le Mac éveillé sans fin. Muette au-delà du délai, et sans `caffeinate` actif lancé par l’agent
    /// (Claude Code en lance un pendant ses longues opérations), elle est considérée comme inactive.
    static func isSilent(state: String, agent: String, silence: TimeInterval, hasActivity: Bool) -> Bool {
        guard state == "working" || state == "waiting" else { return false }
        let limit: TimeInterval = state == "waiting" ? 3600 : (agent == "codex" ? 1800 : 900)
        return silence > limit && !hasActivity
    }

    var agentName: String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "cmd": "Commande"
        default: "Terminal"
        }
    }

    var shortName: String {
        switch agent {
        case "claude": "Claude"
        case "codex": "Codex"
        default: agentName
        }
    }

    var project: String {
        if !label.isEmpty, isCommandHold { return label }
        guard !cwd.isEmpty else { return agentName }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return cwd == NSHomeDirectory() ? "Dossier personnel" : name
    }

    var stateLabel: String {
        if silent { return "Sans nouvelles (interrompu ?)" }
        if background { return "Commande en arrière-plan" }
        return switch state {
        case "working": "Travaille"
        case "waiting": "Attend une validation"
        case "idle": "En attente"
        default: until == nil ? "Maintien illimité" : "Maintien minuté"
        }
    }

    var symbol: String {
        switch agent {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
    }
}

enum SessionStore {
    static func load(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil) else {
            return []
        }
        var sessions: [AgentSession] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let untilValue = (obj["until"] as? NSNumber)?.doubleValue ?? 0
            let session = AgentSession(
                id: url.deletingPathExtension().lastPathComponent,
                agent: obj["agent"] as? String ?? "?",
                state: obj["state"] as? String ?? "idle",
                cwd: obj["cwd"] as? String ?? "",
                pid: (obj["pid"] as? NSNumber)?.int32Value ?? 0,
                updated: Date(timeIntervalSince1970: (obj["ts"] as? NSNumber)?.doubleValue ?? 0),
                until: untilValue > 0 ? Date(timeIntervalSince1970: untilValue) : nil,
                label: obj["label"] as? String ?? ""
            )
            if isStale(session, now: now) {
                try? fm.removeItem(at: url)
                continue
            }
            var checked = session
            if checked.isCommandHold, let boot = obj["boot"] as? String, !boot.isEmpty, boot != AppModel.bootID() {
                try? fm.removeItem(at: url) // maintien d’avant le redémarrage du Mac
                continue
            }
            let silence = now.timeIntervalSince(session.updated)
            if AgentSession.isSilent(state: session.state, agent: session.agent, silence: silence, hasActivity: false) {
                // Muette : une commande en cours la garde active, mais 2 h au plus après le dernier signal
                // (un `tail -f` ou un serveur laissé par une session interrompue ne doit pas tenir toute la nuit).
                checked.silent = silence > 7200 || !ProcessCheck.hasActivityChild(session.pid)
            } else if session.isAgent && session.state == "idle" && silence < 1800 {
                // Fin de tour, mais une commande lancée en arrière-plan peut encore tourner (30 min au plus).
                checked.background = ProcessCheck.hasActivityChild(session.pid)
            }
            sessions.append(checked)
        }
        return sessions.sorted { $0.updated > $1.updated }
    }

    private static func isStale(_ s: AgentSession, now: Date) -> Bool {
        if s.pid > 0 && !ProcessCheck.isAlive(s.pid) { return true }
        // PID réutilisé par un autre programme (après un redémarrage, par exemple) : session fantôme.
        if s.isAgent && s.pid > 0 {
            let path = ProcessCheck.executablePath(s.pid).lowercased()
            // Chemin vide : exécutable remplacé par une mise à jour pendant la session → inconnu, pas fantôme.
            if !path.isEmpty && !path.contains(s.agent) { return true }
        }
        if let until = s.until, until < now { return true }
        // Session d’agent sans PID connu : abandonnée au bout de 12 h sans nouvelle.
        if s.isAgent && s.pid == 0 && now.timeIntervalSince(s.updated) > 12 * 3600 { return true }
        return false
    }

    static func removeCommandHolds() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil) else { return }
        for url in files where url.lastPathComponent.hasPrefix("cli-") {
            try? fm.removeItem(at: url)
        }
    }
}
