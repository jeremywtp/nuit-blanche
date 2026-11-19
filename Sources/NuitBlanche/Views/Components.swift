import SwiftUI
import AppKit

/// Grille du Centre de contrôle de macOS : modules de 64 pt, espacement de 12 pt.
enum M {
    /// Modules de 74 pt (64 au Centre de contrôle) : nos titres (« Capot fermé », 79 pt mesurés) tiennent
    /// en taille réelle avec 14 pt d’air avant le bord arrondi.
    static let unit: CGFloat = 74
    static let gap: CGFloat = 12
    static let pad: CGFloat = 14
    static let content: CGFloat = unit * 4 + gap * 3   // 332
    static let width: CGFloat = content + pad * 2       // 360
    static let half: CGFloat = unit * 2 + gap           // 160
    /// Rayon des modules carrés et des curseurs (≈ 25 pt pour 140 pt au Centre de contrôle, mis à l’échelle).
    static let moduleRadius: CGFloat = 28
    /// Coins concentriques : rayon du panneau = rayon des modules + marge (28 + 14).
    static let panelRadius: CGFloat = moduleRadius + pad
    /// Hauteur des curseurs et des en-têtes de détail.
    static let sliderHeight: CGFloat = 70
    static let headerHeight: CGFloat = 64
    /// Distance de fusion du verre : 0 = rendu groupé sans fusion entre modules (valeur par défaut recommandée par Apple).
    static let glassSpacing: CGFloat = 0
    /// Morphing par glassEffectID entre écrans : désactivé, il déclenche une boucle infinie dans SwiftUI
    /// (FocusBridge → nextResponder) quand le panneau est la fenêtre active (constaté sur macOS 27.0.1).
    static let glassMorphing = false
}

// MARK: - Couleurs d’état (rond blanc en sombre, rond accentué en clair, comme le Centre de contrôle)

struct OnStyle {
    let scheme: ColorScheme
    var fill: Color { scheme == .dark ? .white : .accentColor }
    var tintedGlyph: Color { scheme == .dark ? .accentColor : .white }
    var plainGlyph: Color { scheme == .dark ? .black : .white }
    var offFill: Color { scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.07) }
    var sliderFill: Color { scheme == .dark ? .white : .black.opacity(0.82) }
    var sliderTrack: Color { scheme == .dark ? .white.opacity(0.2) : .black.opacity(0.1) }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum Haptic {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    static func step() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Liquid Glass

let snapshotMode = ProcessInfo.processInfo.environment["NB_SNAPSHOT"] != nil

private struct GlassNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct LiquidGlassKey: EnvironmentKey {
    /// Variante « clear » : verre très transparent à liseré lumineux, comme le Centre de contrôle de macOS 27.
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Espace de noms partagé par le GlassEffectContainer racine : permet le morphing tuile → en-tête de détail.
    var glassNamespace: Namespace.ID? {
        get { self[GlassNamespaceKey.self] }
        set { self[GlassNamespaceKey.self] = newValue }
    }

    var liquidGlass: Bool {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self] = newValue }
    }
}

struct ModuleGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive: Bool
    var id: String?
    @Environment(\.glassNamespace) private var namespace
    @Environment(\.liquidGlass) private var liquid

    private var glass: Glass {
        let base: Glass = liquid ? .clear : .regular
        return interactive ? base.interactive() : base
    }

    func body(content: Content) -> some View {
        if snapshotMode {
            // Rendu hors écran : le verre ne peut pas être dessiné, on montre un fond équivalent.
            content
                .background(shape.fill(Color.primary.opacity(0.10)))
                .overlay(shape.stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
        } else if M.glassMorphing, let id, let namespace {
            content
                .glassEffect(glass, in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    func moduleGlass<S: Shape>(interactive: Bool = false, in shape: S, id: String? = nil) -> some View {
        modifier(ModuleGlass(shape: shape, interactive: interactive, id: id))
    }
}

// MARK: - Rond d’icône

/// Rond d’icône des tuiles (36 pt) et des lignes de détail (26 pt).
struct GlyphCircle: View {
    var symbol: String
    var isOn: Bool
    var diameter: CGFloat = 38
    var glyph: CGFloat = 16
    /// Animation continue (agent au travail, par exemple).
    var animating = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = OnStyle(scheme: scheme)
        ZStack {
            Circle().fill(isOn ? style.fill : style.offFill)
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(isOn ? style.tintedGlyph : Color.primary)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isOn)
                // Un agent se met au travail : un seul battement, pas d’animation en boucle
                // (une boucle redessine le panneau à chaque image et coûtait ~18 % de CPU).
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: reduceMotion ? false : animating)
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth(duration: 0.22), value: isOn)
    }
}

// MARK: - Tuile à bascule (comme Wi-Fi / Bluetooth / AirDrop)

struct ToggleTile: View {
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var isOn: Bool
    var animating = false
    var help: String
    var openTip = "Afficher les options"
    var toggle: () -> Void
    var open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.tap()
                toggle()
            } label: {
                GlyphCircle(symbol: symbol, isOn: isOn, animating: animating)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .tip(help)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "activé" : "désactivé")
            .accessibilityHint(help)
            .accessibilityAddTraits(.isToggle)

            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(openTip)
            .accessibilityLabel("Options : \(title)")
            .accessibilityValue(subtitle)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(width: M.half, height: M.unit)
        .moduleGlass(interactive: true, in: Capsule(), id: id)
    }
}

// MARK: - Bouton rond (comme Mode sombre / Recopie de l’écran)

struct CircleButton: View {
    var symbol: String
    var isOn: Bool = false
    var isToggle = true
    var size: CGFloat = M.unit
    var glyph: CGFloat = 20
    var help: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = OnStyle(scheme: scheme)
        Button {
            Haptic.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(isOn ? style.plainGlyph : Color.primary)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isOn)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(isOn ? style.fill : .clear)
                }
                .contentShape(Circle())
                .animation(.smooth(duration: 0.22), value: isOn)
        }
        .buttonStyle(PressStyle())
        .moduleGlass(interactive: true, in: Circle())
        .tip(help)
        .accessibilityLabel(help)
        .accessibilityValue(isToggle ? (isOn ? "activé" : "désactivé") : "")
    }
}

// MARK: - Module état (comme À l’écoute)

struct StatusModule: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Artwork(isAwake: model.holding, animating: model.panelVisible)
                    .tip(model.holding
                         ? "Le Mac est maintenu éveillé (lune et étoiles)."
                         : "Aucun maintien : le Mac se met en veille normalement (lune endormie).")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    stat(symbol: batterySymbol, text: batteryText, color: model.batteryBlocked ? .red : .secondary)
                        .tip(batteryTip)
                    stat(symbol: model.power.isHot ? "thermometer.high" : "thermometer.medium",
                         text: thermalText, color: model.power.isHot ? .orange : .secondary)
                        .tip("Température du Mac : \(thermalText.lowercased()). Si elle devient élevée écran rabattu, la protection thermique laisse le Mac dormir.")
                }
                .padding(.top, 2)
                .layoutPriority(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
                Text(model.statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
            }
            .tip("État en direct : pourquoi le Mac est éveillé ou non. Il reste éveillé tant qu’un maintien est actif : caféine, agent au travail ou commande Terminal.")
            Spacer(minLength: 8)
            let indicator = model.statusIndicator
            HStack(spacing: 5) {
                Image(systemName: indicator.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(indicator.text)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(indicator.color)
            .contentTransition(.interpolate)
            .tip(indicator.tip)
        }
        .padding(.horizontal, 17)
        .padding(.top, 17)
        .padding(.bottom, 15)
        .frame(width: M.half, height: M.half, alignment: .topLeading)
        .moduleGlass(in: RoundedRectangle(cornerRadius: M.moduleRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func stat(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(color)
    }

    private var batterySymbol: String {
        if model.power.onAC { return "battery.100percent.bolt" }
        switch model.power.batteryPercent ?? 100 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryText: String {
        model.power.batteryPercent.map { "\($0) %" } ?? "Secteur"
    }

    private var batteryTip: String {
        let level = model.power.batteryPercent.map { "Batterie à \($0) %" } ?? "Pas de batterie"
        return model.power.onAC
            ? "\(level), sur secteur."
            : "\(level), sur batterie. Sous \(model.batteryFloor) %, Nuit Blanche laisse le Mac se mettre en veille."
    }

    private var thermalText: String {
        switch model.power.thermal {
        case .nominal: "Normale"
        case .fair: "Tiède"
        case .serious: "Chaude"
        case .critical: "Très chaude"
        @unknown default: "Inconnue"
        }
    }
}

/// Vignette du module état (40 pt, coins de 9 pt comme la pochette d’« À l’écoute »).
struct Artwork: View {
    var isAwake: Bool
    var animating = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isAwake
                      ? AnyShapeStyle(LinearGradient(
                          colors: [Color(red: 0.20, green: 0.17, blue: 0.58), Color(red: 0.53, green: 0.30, blue: 0.86)],
                          startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(OnStyle(scheme: scheme).offFill))
                .overlay {
                    // Liseré lumineux en haut, comme l’arête spéculaire des surfaces Liquid Glass.
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(isAwake ? 0.35 : 0.12), .clear],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75
                        )
                }
            Image(systemName: isAwake ? "moon.stars.fill" : "moon.zzz.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isAwake ? Color.white : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion || !animating ? false : isAwake)
        }
        .frame(width: 44, height: 44)
        .animation(.smooth(duration: 0.35), value: isAwake)
        .accessibilityHidden(true)
    }
}

// MARK: - Module curseur (comme Moniteur / Son)

struct SliderModule<Accessory: View>: View {
    var title: String
    var value: String
    var tip: String
    var leadingSymbol: String
    var trailingSymbol: String
    var fraction: Double
    var steps: Int
    var onChange: (Double) -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .tip(tip)
            HStack(spacing: 10) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                ThinSlider(fraction: fraction, steps: steps, onChange: onChange)
                    .tip(tip)
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityValue(value)
                    .accessibilityAdjustableAction { direction in
                        let step = 1 / Double(max(steps - 1, 1))
                        switch direction {
                        case .increment: onChange(min(1, fraction + step))
                        case .decrement: onChange(max(0, fraction - step))
                        @unknown default: break
                        }
                    }
                Image(systemName: trailingSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                accessory()
            }
        }
        .padding(.horizontal, 18)
        .frame(width: M.content, height: M.sliderHeight)
        .moduleGlass(in: RoundedRectangle(cornerRadius: M.moduleRadius, style: .continuous))
    }
}

/// Curseur fin sans poignée, à crans, qui s’épaissit au survol comme ceux du Centre de contrôle.
struct ThinSlider: View {
    var fraction: Double
    var steps: Int
    var onChange: (Double) -> Void
    @State private var dragging = false
    @State private var frame: CGRect = .zero
    @Environment(\.colorScheme) private var scheme
    @Environment(TipCenter.self) private var tips: TipCenter?

    var body: some View {
        let style = OnStyle(scheme: scheme)
        let hovering = tips?.pointer.map { frame.insetBy(dx: 0, dy: -6).contains($0) } ?? false
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let thickness: CGFloat = dragging ? 9 : (hovering ? 7 : 5)
            ZStack(alignment: .leading) {
                Capsule().fill(style.sliderTrack)
                Capsule()
                    .fill(style.sliderFill)
                    .frame(width: max(thickness, width * fraction))
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        var f = min(max(value.location.x / width, 0), 1)
                        if steps > 1 {
                            f = (f * Double(steps - 1)).rounded() / Double(steps - 1)
                        }
                        if abs(f - fraction) > 0.0001 {
                            Haptic.step()
                            onChange(f)
                        }
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: thickness)
            .animation(.smooth(duration: 0.18), value: fraction)
        }
        .frame(height: 20)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TipCenter.space)) } action: { frame = $0 }
    }
}

// MARK: - Pastille (comme « Capture d’écran récemment ») et capsule de pied

struct ChipView: View {
    var chip: Chip
    var tip: String
    var animating = false
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(chip.color.gradient)
                    Image(systemName: chip.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion || !animating ? "" : chip.text)
                }
                .frame(width: 18, height: 18)
                Text(chip.text)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .moduleGlass(interactive: true, in: Capsule(), id: "chip")
        .tip(tip)
        .accessibilityLabel(chip.text)
    }
}

struct FooterCapsule: View {
    var id: String
    var title: String
    var tip: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .moduleGlass(interactive: true, in: Capsule(), id: id)
        .tip(tip)
    }
}

// MARK: - Vues de détail (comme un module ouvert du Centre de contrôle)

/// En-tête de détail : la tuile s’y transforme (même identifiant de verre) et prend toute la largeur.
struct DetailHeader: View {
    var id: String
    var symbol: String
    var title: String
    var subtitle: String
    var isOn: Bool
    var toggle: Binding<Bool>?
    var toggleTip: String = ""
    var back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .moduleGlass(interactive: true, in: Circle(), id: "back")
            .tip("Revenir au panneau principal (touche Échap)")
            .accessibilityLabel("Retour")

            HStack(spacing: 10) {
                GlyphCircle(symbol: symbol, isOn: isOn)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                if let toggle {
                    Toggle("", isOn: toggle)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel(title)
                        .tip(toggleTip)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(height: M.headerHeight)
            .moduleGlass(in: Capsule(), id: id)
        }
    }
}

struct DetailScaffold<Content: View>: View {
    var header: DetailHeader
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: M.glassSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                header.padding(.bottom, 6)
                content()
            }
        }
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 2)
    }
}

/// Surbrillance au survol, pilotée par la position du curseur relevée par le panneau (voir TipCenter).
struct HoverRow: ViewModifier {
    var enabled = true
    @Environment(TipCenter.self) private var tips: TipCenter?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        let hovering = enabled && (tips?.pointer.map { frame.contains($0) } ?? false)
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TipCenter.space)) } action: { frame = $0 }
            .animation(.smooth(duration: 0.12), value: hovering)
    }
}

struct ChoiceRow: View {
    var title: String
    var subtitle: String? = nil
    var tip: String? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button {
            Haptic.step()
            action()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.6)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverRow())
        .tip(tip ?? subtitle ?? title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ToggleRow: View {
    var title: String
    var subtitle: String? = nil
    var tip: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .accessibilityLabel(title)
        }
        .modifier(HoverRow(enabled: false))
        .tip(tip ?? subtitle ?? title)
    }
}

struct InfoRow: View {
    var symbol: String
    var title: String
    var tip: String
    var value: String? = nil
    var isOn: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            GlyphCircle(symbol: symbol, isOn: isOn, diameter: 26, glyph: 11)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else if let value {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .modifier(HoverRow(enabled: false))
        .tip(tip)
        .accessibilityElement(children: .combine)
    }
}

struct ActionRow: View {
    var title: String
    var tip: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                Spacer()
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverRow())
        .tip(tip)
    }
}

struct Footnote: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }
}
