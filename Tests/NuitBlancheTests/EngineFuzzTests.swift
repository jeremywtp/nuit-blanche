import Foundation
import Testing
@testable import NuitBlanche

/// Générateur pseudo-aléatoire déterministe (SplitMix64) : un échec se rejoue avec la même graine.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Le moteur subit des milliers d’événements tirés au hasard ; après chaque évaluation, des règles de
/// sécurité ne doivent jamais être violées (mode dryRun : rien n’est touché sur le système).
@MainActor
@Suite("Moteur — tests par génération aléatoire")
struct EngineFuzzTests {
    @Test("Invariants de sécurité sur 6 × 4000 événements aléatoires", arguments: [1, 7, 42, 1337, 2026, 99991] as [UInt64])
    func invariants(seed: UInt64) {
        var rng = SplitMix(state: seed)
        let m = AppModel()
        m.dryRun = true
        m.systemSleepDisabled = false
        var external = false
        m.externalDisplayProbe = { external }
        let agents = ["claude", "codex"], states = ["working", "waiting", "idle"]

        for step in 0..<4000 {
            // Un ou deux événements par pas.
            for _ in 0..<Int.random(in: 1...2, using: &rng) {
                switch Int.random(in: 0..<16, using: &rng) {
                case 0: m.manualActive ? m.toggleManual() : m.startManual(durationIndex: Int.random(in: 0..<AppModel.durations.count, using: &rng))
                case 1: if m.manualActive { m.manualUntil = Date().addingTimeInterval(-1) } // durée écoulée
                case 2:
                    m.sessions = (0..<Int.random(in: 0...3, using: &rng)).map { i in
                        var s = AgentSession(id: "s\(i)", agent: agents.randomElement(using: &rng)!,
                                             state: states.randomElement(using: &rng)!, cwd: "/tmp", pid: 0,
                                             updated: Date(), until: nil, label: "")
                        s.silent = Bool.random(using: &rng) && Bool.random(using: &rng)
                        s.background = s.state == "idle" && Bool.random(using: &rng) && Bool.random(using: &rng)
                        return s
                    }
                case 3: m.sessions.append(AgentSession(id: "cli", agent: "cli", state: "hold", cwd: "", pid: 0,
                                                       updated: Date(), until: Date().addingTimeInterval(600), label: ""))
                case 4: m.agentsAuto.toggle()
                case 5: m.agentsMode = Bool.random(using: &rng) ? .working : .open
                case 6: m.graceIndex = Int.random(in: 0..<AppModel.graces.count, using: &rng)
                case 7: m.power.batteryPercent = Int.random(in: 0...100, using: &rng)
                case 8: m.power.onAC.toggle(); m.power.charging = m.power.onAC && Bool.random(using: &rng)
                case 9: m.power.thermal = [.nominal, .fair, .serious, .critical].randomElement(using: &rng)!
                case 10: m.power.lidClosed.toggle()
                case 11: external.toggle()
                case 12: m.lidModeEnabled.toggle()
                case 13: m.helperInstalled.toggle()
                case 14: m.acOnly.toggle()
                default: m.batteryFloor = AppModel.batteryFloors.randomElement(using: &rng)!
                }
            }
            // Certains événements relancent déjà le moteur : l’invariant d’armement porte sur CETTE évaluation.
            let wasSleepDisabled = m.systemSleepDisabled == true
            m.evaluate()

            let context = "graine \(seed), pas \(step)"
            let lowBattery = (!m.power.onAC || !m.power.charging) && (m.power.batteryPercent ?? 100) <= m.batteryFloor
            #expect(!m.lidEffective || m.holding, "capot fermé sans maintien (\(context))")
            if m.helperInstalled {
                #expect(m.holding || m.systemSleepDisabled != true, "veille bloquée sans maintien (\(context))")
            }
            #expect(!lowBattery || !m.holding, "maintien sous le seuil de batterie (\(context))")
            if lowBattery && m.manualActive { #expect(m.awakeSubtitle == "Suspendue : batterie", "\(context)") }
            #expect(!(m.thermalGuard && m.power.isHot) || !m.lidEffective, "capot fermé malgré la chaleur (\(context))")
            #expect(!(m.acOnly && !m.power.onAC) || !m.lidEffective, "capot fermé sur batterie en mode secteur (\(context))")
            #expect(m.helperInstalled || !m.lidEffective, "capot fermé sans assistant (\(context))")
            #expect(m.lidModeEnabled || !m.lidEffective, "capot fermé désactivé mais actif (\(context))")
            if !wasSleepDisabled && m.power.lidClosed && !external {
                #expect(m.systemSleepDisabled != true, "veille rebloquée écran rabattu sans écran externe (\(context))")
            }
            if let until = m.manualUntil, m.manualActive {
                #expect(until > Date().addingTimeInterval(-0.5), "caféine échue toujours active (\(context))")
            }
            if m.lidEffective { #expect(m.statusIndicator.text == "Écran rabattable", "\(context)") }
            let noReason = !m.manualActive && !m.sessions.contains(where: \.isCommandHold)
                && (!m.agentsAuto || !m.sessions.contains(where: { $0.isAgent }))
            if noReason && !m.inGrace { #expect(!m.holding, "maintien sans raison (\(context))") }
        }
    }
}
