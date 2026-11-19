import SwiftUI
import AppKit

struct RootView: View {
    @Bindable var model: AppModel
    @Namespace private var glassNamespace

    var body: some View {
        // Un conteneur de verre par écran (dans chaque écran), jamais un conteneur englobant le changement
        // d’écran : SwiftUI y boucle à l’infini (FocusBridge, macOS 27.0.1).
        ZStack(alignment: .top) {
            switch model.screen {
            case .main: MainPanel(model: model).transition(.opacity)
            case .awake: AwakeDetail(model: model).transition(.opacity)
            case .lid: LidDetail(model: model).transition(.opacity)
            case .agents: AgentsDetail(model: model).transition(.opacity)
            case .display: DisplayDetail(model: model).transition(.opacity)
            case .settings: SettingsDetail(model: model).transition(.opacity)
            }
        }
        .environment(\.glassNamespace, glassNamespace)
        .environment(\.liquidGlass, model.liquidGlass)
        .environment(model.tips)
        .padding(M.pad)
        .frame(width: M.width, alignment: .top)
        // Bulles d’explication : au-dessus de tout, dans le même repère que les éléments survolés.
        .coordinateSpace(.named(TipCenter.space))
        .overlay { TipOverlay(tips: model.tips) }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            model.onHeightChange?(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.screen)
    }
}

// MARK: - Panneau principal

struct MainPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        // Conteneur de verre propre à l’écran (recommandation Apple : rendu groupé, échantillonnage cohérent).
        GlassEffectContainer(spacing: M.glassSpacing) {
            content
        }
    }

    private var content: some View {
        VStack(spacing: M.gap) {
            if let chip = model.chip {
                ChipView(chip: chip, tip: chipTip(chip), animating: model.panelVisible) { model.handle(chip) }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(alignment: .top, spacing: M.gap) {
                VStack(spacing: M.gap) {
                    ToggleTile(
                        id: "awake",
                        title: "Caféine",
                        subtitle: model.awakeSubtitle,
                        symbol: model.manualActive ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill",
                        isOn: model.manualActive,
                        help: model.manualActive
                            ? "Couper la caféine : le Mac pourra de nouveau se mettre en veille."
                            : "Activer la caféine : le Mac reste éveillé pendant la durée choisie, et même écran rabattu si le capot fermé est actif. Aussi : ⌥ + clic sur la lune, ou ⌃⌥⌘N.",
                        openTip: "Choisir la durée de la caféine et garder l’écran allumé ou non.",
                        toggle: { model.toggleManual() },
                        open: { model.screen = .awake }
                    )
                    ToggleTile(
                        id: "lid",
                        title: "Capot fermé",
                        subtitle: model.lidSubtitle,
                        symbol: "macbook",
                        isOn: model.helperInstalled && model.lidModeEnabled,
                        help: model.helperInstalled
                            ? "Autoriser le Mac à continuer de travailler écran rabattu, sans écran externe, pendant un maintien."
                            : "Installer l’autorisation qui permet de travailler écran rabattu (mot de passe demandé une seule fois).",
                        openTip: "État de la veille du Mac, protections batterie et chaleur.",
                        toggle: { model.toggleLidMode() },
                        open: { model.screen = .lid }
                    )
                }
                StatusModule(model: model)
            }

            HStack(spacing: M.gap) {
                ToggleTile(
                    id: "agents",
                    title: "Agents IA",
                    subtitle: model.agentsSubtitle,
                    symbol: "sparkles",
                    isOn: model.agentsAuto,
                    animating: model.panelVisible && model.agentsAuto && !model.workingSessions.isEmpty,
                    help: model.agentsAuto
                        ? "Ne plus garder le Mac éveillé automatiquement pour Claude Code et Codex."
                        : "Garder le Mac éveillé automatiquement pendant que Claude Code ou Codex travaillent.",
                    openTip: "Choisir quand rester éveillé pour les agents et voir les sessions en cours.",
                    toggle: { model.agentsAuto.toggle() },
                    open: { model.screen = .agents }
                )
                ToggleTile(
                    id: "display",
                    title: "Écran",
                    subtitle: model.displaySubtitle,
                    symbol: model.keepDisplayOn ? "sun.max.fill" : "sun.min",
                    isOn: model.keepDisplayOn,
                    help: model.keepDisplayOn
                        ? "Laisser l’écran s’éteindre normalement pendant les maintiens (le travail continue)."
                        : "Garder l’écran allumé pendant les maintiens (caféine, agent au travail…).",
                    openTip: "Options de l’écran, et l’éteindre tout de suite sans arrêter le travail.",
                    toggle: { model.keepDisplayOn.toggle() },
                    open: { model.screen = .display }
                )
            }

            SliderModule(
                title: "Durée",
                value: model.durationLabel,
                tip: "Durée de la caféine : de 30 min à 8 h, ou illimitée (jusqu’à ce que vous l’arrêtiez).",
                leadingSymbol: "timer",
                trailingSymbol: "infinity",
                fraction: Double(model.durationIndex) / Double(AppModel.durations.count - 1),
                steps: AppModel.durations.count,
                onChange: { f in
                    model.durationIndex = Int((f * Double(AppModel.durations.count - 1)).rounded())
                }
            ) { EmptyView() }

            SliderModule(
                title: "Batterie minimum",
                value: "\(model.batteryFloor) %",
                tip: "Sur batterie, sous ce niveau, Nuit Blanche arrête tout maintien et laisse le Mac se mettre en veille.",
                leadingSymbol: "battery.25percent",
                trailingSymbol: "battery.100percent",
                fraction: batteryFraction,
                steps: AppModel.batteryFloors.count,
                onChange: { f in
                    let index = Int((f * Double(AppModel.batteryFloors.count - 1)).rounded())
                    model.batteryFloor = AppModel.batteryFloors[index]
                }
            ) { EmptyView() }

            FooterCapsule(
                id: "settings",
                title: "Réglages…",
                tip: "Ouverture au démarrage, notifications, raccourci clavier, historique des maintiens."
            ) { model.screen = .settings }
                .padding(.top, 2)
        }
        .animation(.smooth(duration: 0.25), value: model.chip)
    }

    private func chipTip(_ chip: Chip) -> String {
        switch chip.action {
        case .openAgents: "Agents au travail en ce moment : le Mac reste éveillé. Cliquer pour voir les sessions."
        case .openLid: "Cliquer pour voir le détail du capot fermé."
        case .installHelper: "Cliquer pour installer l’autorisation du capot fermé."
        case .none: "Batterie sous le seuil choisi : la caféine est suspendue et les agents ne gardent plus le Mac éveillé, jusqu’à ce que la batterie repasse au-dessus du seuil."
        }
    }

    private var batteryFraction: Double {
        let floors = AppModel.batteryFloors
        let index = floors.firstIndex(of: model.batteryFloor) ?? 3
        return Double(index) / Double(floors.count - 1)
    }
}

// MARK: - Caféine

struct AwakeDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        DetailScaffold(header: DetailHeader(
            id: "awake",
            symbol: model.manualActive ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill",
            title: "Caféine",
            subtitle: model.awakeSubtitle,
            isOn: model.manualActive,
            toggle: Binding(get: { model.manualActive }, set: { if $0 != model.manualActive { model.toggleManual() } }),
            toggleTip: "Activer ou couper la caféine (le Mac reste éveillé, écran rabattu compris si le capot fermé est actif).",
            back: { model.screen = .main }
        )) {
            SectionTitle(text: "Durée")
            ForEach(Array(AppModel.durations.enumerated()), id: \.offset) { index, minutes in
                ChoiceRow(
                    title: minutes == 0 ? "Jusqu’à ce que je l’arrête" : AppModel.format(Double(minutes) * 60),
                    tip: minutes == 0
                        ? "La caféine reste active jusqu’à ce que vous la coupiez : idéal écran rabattu, chez vous."
                        : "La caféine s’arrête seule après \(AppModel.format(Double(minutes) * 60)), puis le Mac peut se rendormir.",
                    selected: model.durationIndex == index
                ) {
                    model.durationIndex = index
                }
            }
            Footnote(text: "La caféine garde le Mac éveillé, écran rabattu compris quand le capot fermé est actif. Pour qu’il travaille aussi longtemps que vous voulez : « Jusqu’à ce que je l’arrête ». Option + clic sur la lune ou ⌃⌥⌘N l’active sans ouvrir ce panneau.")
                .padding(.top, 4)
        }
    }
}

// MARK: - Écran

struct DisplayDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        DetailScaffold(header: DetailHeader(
            id: "display",
            symbol: model.keepDisplayOn ? "sun.max.fill" : "sun.min",
            title: "Écran",
            subtitle: model.displaySubtitle,
            isOn: model.keepDisplayOn,
            toggle: $model.keepDisplayOn,
            toggleTip: "Garder ou non l’écran allumé pendant les maintiens.",
            back: { model.screen = .main }
        )) {
            Footnote(text: "Pendant un maintien (caféine, agent au travail, commande Terminal), l’écran peut rester allumé ou s’éteindre comme d’habitude. Dans les deux cas, le Mac continue de travailler.")
                .padding(.bottom, 4)
            SectionTitle(text: "Pendant les maintiens")
            ChoiceRow(
                title: "L’écran reste allumé",
                subtitle: "Pratique pour suivre un agent à l’écran.",
                tip: "L’écran ne s’éteint pas tant que le Mac est maintenu éveillé.",
                selected: model.keepDisplayOn
            ) { model.keepDisplayOn = true }
            ChoiceRow(
                title: "L’écran s’éteint normalement",
                subtitle: "Économise la batterie ; le travail continue écran éteint.",
                tip: "L’écran s’éteint après le délai réglé dans macOS ; le Mac, lui, reste éveillé.",
                selected: !model.keepDisplayOn
            ) { model.keepDisplayOn = false }
            SectionDivider()
            ActionRow(title: "Éteindre l’écran maintenant",
                      tip: "Éteint l’écran tout de suite. Le Mac continue de travailler s’il est maintenu éveillé.",
                      symbol: "lock.display") {
                model.sleepDisplay()
            }
        }
    }
}

// MARK: - Capot fermé

struct LidDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        DetailScaffold(header: DetailHeader(
            id: "lid",
            symbol: "macbook",
            title: "Capot fermé",
            subtitle: model.lidSubtitle,
            isOn: model.helperInstalled && model.lidModeEnabled,
            toggle: model.helperInstalled ? $model.lidModeEnabled : nil,
            toggleTip: "Autoriser ou non le travail écran rabattu pendant les maintiens.",
            back: { model.screen = .main }
        )) {
            Footnote(text: "Écran rabattu, sans écran externe, le Mac continue de travailler tant qu’un maintien est actif : Caféine, agent au travail ou commande Terminal. À la fin du maintien, il se rendort (avec un écran externe, il reste en mode bureau).")
                .padding(.bottom, 4)

            SectionTitle(text: "État")
            if model.helperInstalled {
                InfoRow(symbol: "checkmark.shield.fill", title: "Assistant",
                        tip: "Autorisation système limitée à l’activation et au retrait de « pmset disablesleep ». Rien d’autre.",
                        value: "Installé", isOn: true)
            } else {
                InfoRow(symbol: "lock.shield", title: "Assistant",
                        tip: "Autorisation système nécessaire pour travailler écran rabattu. Mot de passe demandé une seule fois.",
                        actionTitle: "Installer…") {
                    model.installHelper()
                }
            }
            InfoRow(
                symbol: model.systemSleepDisabled == true ? "moon.stars.fill" : "moon.zzz",
                title: "Veille système",
                tip: "État réel de la veille de macOS. « Bloquée » : le Mac ne peut pas dormir, même écran rabattu.",
                value: sleepValue,
                isOn: model.systemSleepDisabled == true
            )
            InfoRow(
                symbol: "macbook",
                title: "Capot",
                tip: "Capot du Mac ouvert ou fermé (écran rabattu), lu en direct.",
                value: model.power.lidClosed ? "Fermé" : "Ouvert"
            )

            SectionDivider()
            SectionTitle(text: "Sécurité")
            ToggleRow(
                title: "Uniquement sur secteur",
                subtitle: "Sur batterie, rabattre l’écran met le Mac en veille.",
                isOn: $model.acOnly
            )
            ToggleRow(
                title: "Protection thermique",
                subtitle: "Rend la main à la veille si le Mac chauffe écran rabattu.",
                tip: "Si macOS signale une chaleur importante, le capot fermé est suspendu : écran rabattu, le Mac se met en veille.",
                isOn: $model.thermalGuard
            )
            Footnote(text: "Batterie minimum : \(model.batteryFloor) % (réglable sur le panneau principal). Si Nuit Blanche plante ou se fige, un watchdog la relance en une à trois minutes ; s’il n’y arrive pas, il rétablit la veille et rendort le Mac s’il est fermé.")

            if model.helperInstalled {
                SectionDivider()
                ActionRow(title: "Désinstaller l’assistant…",
                          tip: "Retire l’autorisation système et le watchdog, et rétablit la veille normale (mot de passe demandé).",
                          role: .destructive) {
                    model.uninstallHelper()
                }
            }
        }
    }

    private var sleepValue: String {
        switch model.systemSleepDisabled {
        case .some(true): model.lidEffective ? "Bloquée" : "Bloquée en permanence"
        case .some(false): "Normale"
        case .none: "Inconnue"
        }
    }
}

// MARK: - Agents IA

struct AgentsDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        DetailScaffold(header: DetailHeader(
            id: "agents",
            symbol: "sparkles",
            title: "Agents IA",
            subtitle: model.agentsSubtitle,
            isOn: model.agentsAuto,
            toggle: $model.agentsAuto,
            toggleTip: "Garder ou non le Mac éveillé automatiquement pour Claude Code et Codex.",
            back: { model.screen = .main }
        )) {
            SectionTitle(text: "Garder le Mac éveillé")
            ChoiceRow(
                title: "Pendant qu’ils travaillent",
                subtitle: "Le Mac se rendort une fois la réponse et ses commandes terminées.",
                tip: "Éveillé pendant qu’un agent répond, attend une validation ou exécute une commande (même en arrière-plan), puis veille après le délai choisi.",
                selected: model.agentsMode == .working
            ) { model.agentsMode = .working }
            ChoiceRow(
                title: "Tant qu’une session est ouverte",
                subtitle: "Le Mac reste joignable pour Remote Control, même écran rabattu.",
                tip: "Éveillé tant qu’une session Claude Code ou Codex est ouverte, même inactive : pratique pour piloter depuis le téléphone.",
                selected: model.agentsMode == .open
            ) { model.agentsMode = .open }

            HStack {
                Text("Délai avant la veille").font(.system(size: 13))
                Spacer()
                Picker("Délai avant la veille", selection: $model.graceIndex) {
                    ForEach(Array(AppModel.graces.enumerated()), id: \.offset) { index, minutes in
                        Text(minutes == 0 ? "Aucun" : "\(minutes) min").tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            .modifier(HoverRow(enabled: false))
            .tip("Temps d’attente après la fin du travail d’un agent avant de laisser le Mac dormir (le temps de relancer une demande).")

            SectionDivider()
            SectionTitle(text: "Sessions")
            if model.sessions.isEmpty {
                Footnote(text: "Aucune session détectée. Les nouvelles sessions Claude Code et Codex apparaîtront ici.")
            } else {
                ForEach(model.sessions.prefix(6)) { session in
                    SessionRow(session: session, now: model.displayNow)
                }
            }

            SectionDivider()
            SectionTitle(text: "Connexion")
            hookRow(name: "Claude Code", symbol: "sparkle", connected: model.hooks.claude, target: "claude")
            if model.hooks.codexInstalled {
                hookRow(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", connected: model.hooks.codex, target: "codex")
            }
            Footnote(text: "Codex demande de valider les nouveaux hooks à son lancement (« Hooks need review ») : tant que ce n’est pas fait, ses sessions ne sont pas détectées. Depuis le Terminal : nuitblanche run -- <commande> garde le Mac éveillé le temps de la commande.")
        }
    }

    @ViewBuilder
    private func hookRow(name: String, symbol: String, connected: Bool, target: String) -> some View {
        if connected {
            InfoRow(symbol: symbol, title: name,
                    tip: "\(name) prévient Nuit Blanche quand il commence et finit de travailler (hooks installés).",
                    value: "Connecté", isOn: true)
        } else {
            InfoRow(symbol: symbol, title: name,
                    tip: "Ajoute les hooks Nuit Blanche à la configuration de \(name) pour détecter son travail.",
                    actionTitle: "Connecter") {
                model.setHooks(target, install: true)
            }
        }
    }
}

struct SessionRow: View {
    var session: AgentSession
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            GlyphCircle(symbol: session.symbol, isOn: session.isWorking, diameter: 26, glyph: 11)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.project).font(.system(size: 13)).lineLimit(1)
                Text("\(session.agentName) · \(session.stateLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(session.state == "waiting" ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(AppModel.format(now.timeIntervalSince(session.updated)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .modifier(HoverRow(enabled: false))
        .tip(tipText)
        .accessibilityElement(children: .combine)
    }

    private var tipText: String {
        let place = session.cwd.isEmpty ? "" : " dans \(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        return "\(session.agentName)\(place) : \(session.stateLabel.lowercased()). Dernière activité il y a \(AppModel.format(now.timeIntervalSince(session.updated)))."
    }
}

// MARK: - Réglages

struct SettingsDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        DetailScaffold(header: DetailHeader(
            id: "settings",
            symbol: "gearshape.fill",
            title: "Réglages",
            subtitle: "Nuit Blanche \(Bundle.main.shortVersion)",
            isOn: false,
            toggle: nil,
            back: { model.screen = .main }
        )) {
            ToggleRow(
                title: "Ouvrir au démarrage",
                tip: "Lance Nuit Blanche automatiquement à l’ouverture de session.",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
            )
            ToggleRow(
                title: "Temps restant dans la barre des menus",
                tip: "Affiche le temps restant de la caféine à côté de la lune, quand une durée est choisie.",
                isOn: $model.showTimeInMenuBar
            )
            ToggleRow(
                title: "Notifications",
                subtitle: model.notificationsEnabled && model.notificationsDenied
                    ? "Bloquées par macOS : autorisez-les ci-dessous."
                    : "Fin de durée, batterie faible, surchauffe.",
                isOn: $model.notificationsEnabled
            )
            if model.notificationsEnabled && model.notificationsDenied {
                ActionRow(title: "Autoriser dans Réglages Système…",
                          tip: "Ouvre les réglages de notifications de macOS pour autoriser Nuit Blanche.",
                          symbol: "arrow.up.forward") {
                    model.closePanel?()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.jeremywtp.NuitBlanche") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            ToggleRow(title: "Raccourci ⌃⌥⌘N",
                      subtitle: model.hotkeyEnabled && !model.hotkeyAvailable
                        ? "Déjà utilisé par une autre app : indisponible."
                        : "Active ou arrête la caféine.",
                      tip: "Contrôle + Option + Commande + N, depuis n’importe quelle app, active ou coupe la caféine. Clic droit sur la lune : menu rapide.",
                      isOn: $model.hotkeyEnabled)

            SectionDivider()
            SectionTitle(text: "Historique")
            if model.history.isEmpty {
                Footnote(text: "Les maintiens de plus d’une minute apparaîtront ici.")
            } else {
                ForEach(model.history.prefix(4)) { entry in
                    HistoryRow(entry: entry)
                }
            }

            SectionDivider()
            ActionRow(title: "Réglages Batterie de macOS…",
                      tip: "Ouvre les réglages Batterie de macOS (extinction de l’écran, mode économie d’énergie).",
                      symbol: "arrow.up.forward") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                    model.closePanel?()
                    NSWorkspace.shared.open(url)
                }
            }
            ActionRow(title: "Quitter Nuit Blanche",
                      tip: "Quitte l’app : tout maintien s’arrête et la veille normale est rétablie.") {
                NSApp.terminate(nil)
            }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(entry.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.system(size: 13))
                Spacer()
                Text(AppModel.format(entry.end.timeIntervalSince(entry.start)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            Text(details)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .modifier(HoverRow(enabled: false))
        .tip("Maintien de \(entry.start.formatted(date: .omitted, time: .shortened)) à \(entry.end.formatted(date: .omitted, time: .shortened)) : \(details).")
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [entry.trigger]
        if entry.lidClosedSeconds >= 60 {
            parts.append("écran rabattu \(AppModel.format(entry.lidClosedSeconds))")
        }
        if let start = entry.batteryStart, let end = entry.batteryEnd, start != end {
            parts.append("\(start) → \(end) %")
        }
        parts.append(entry.endReason)
        return parts.joined(separator: " · ")
    }
}
