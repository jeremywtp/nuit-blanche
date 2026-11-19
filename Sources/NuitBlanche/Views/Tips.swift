import SwiftUI
import AppKit

/// Bulles d’explication au survol.
///
/// Les bulles natives (`.help`) et le survol SwiftUI (`onHover`) dépendent de l’app active ; or Nuit Blanche
/// ne s’active jamais (panneau non activant, comme le Centre de contrôle). D’où ce système maison : le panneau
/// lit la position du curseur (PanelController, 30 fois par seconde, panneau ouvert seulement) et la passe à
/// `pointerMoved` ; l’élément survolé est trouvé parmi les cadres enregistrés. Délai au premier survol,
/// affichage immédiat en passant d’un élément à l’autre, disparition au clic, bulle toujours dans le panneau.
@MainActor
@Observable
final class TipCenter {
    nonisolated static let space = "nuitblanche.panel"

    struct Tip: Equatable {
        var id: UUID
        var text: String
        var frame: CGRect
    }

    private(set) var current: Tip?
    /// Position du curseur dans le panneau (repère TipCenter.space), nil hors du panneau.
    private(set) var pointer: CGPoint?
    @ObservationIgnored private var hoveredID: UUID?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var lastHide = Date.distantPast
    @ObservationIgnored private var registry: [UUID: (text: String, frame: CGRect)] = [:]

    func enter(id: UUID, text: String, frame: CGRect) {
        pending?.cancel()
        // Une bulle était visible il y a un instant : on enchaîne sans délai, comme les bulles de macOS.
        let instant = current != nil || Date().timeIntervalSince(lastHide) < 0.5
        let item = DispatchWorkItem { [weak self] in
            self?.current = Tip(id: id, text: text, frame: frame)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (instant ? 0.03 : 0.55), execute: item)
    }

    func exit(id: UUID) {
        if current?.id == id {
            pending?.cancel()
            current = nil
            lastHide = Date()
        } else if current == nil {
            pending?.cancel()
        }
    }

    func update(id: UUID, text: String, frame: CGRect) {
        registry[id] = (text, frame)
        if current?.id == id, current?.text != text || current?.frame != frame {
            current = Tip(id: id, text: text, frame: frame)
        }
    }

    func unregister(id: UUID) {
        registry[id] = nil
        exit(id: id)
    }

    /// Appelé par le panneau à chaque relevé du curseur : trouve l’élément le plus petit sous le curseur.
    func pointerMoved(to point: CGPoint?) {
        if pointer != point { pointer = point }
        let hit = point.flatMap { p in
            registry.filter { $0.value.frame.contains(p) }
                .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }
        }
        guard hit?.key != hoveredID else { return }
        if let old = hoveredID { exit(id: old) }
        hoveredID = hit?.key
        if let hit { enter(id: hit.key, text: hit.value.text, frame: hit.value.frame) }
    }

    /// Clic : la bulle se ferme et ne revient pas tant que le curseur reste sur le même élément.
    func hideAll() {
        pending?.cancel()
        if current != nil {
            current = nil
            lastHide = .distantPast
        }
    }

    /// Changement d’écran ou fermeture : on repart de zéro.
    func reset() {
        hideAll()
        hoveredID = nil
        if pointer != nil { pointer = nil }
    }

    /// Diagnostic : affiche la n-ième bulle (ordre de lecture) sans souris.
    func showRegistered(index: Int) {
        let sorted = registry.sorted { ($0.value.frame.minY, $0.value.frame.minX) < ($1.value.frame.minY, $1.value.frame.minX) }
        guard sorted.indices.contains(index) else { return }
        let entry = sorted[index]
        current = Tip(id: entry.key, text: entry.value.text, frame: entry.value.frame)
    }
}

struct TipModifier: ViewModifier {
    var text: String
    @Environment(TipCenter.self) private var tips: TipCenter?
    @State private var id = UUID()
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(TipCenter.space))
            } action: { newFrame in
                frame = newFrame
                tips?.update(id: id, text: text, frame: newFrame)
            }
            .onChange(of: text) { _, newText in
                tips?.update(id: id, text: newText, frame: frame)
            }
            .onDisappear { tips?.unregister(id: id) }
            .accessibilityHint(text)
    }
}

extension View {
    /// Explication affichée au survol (et lue par VoiceOver).
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }
}

/// Calque des bulles, posé au-dessus de tout le panneau (dans l’espace de coordonnées TipCenter.space).
struct TipOverlay: View {
    var tips: TipCenter

    var body: some View {
        GeometryReader { geo in
            if let tip = tips.current {
                let size = TipBubble.size(for: tip.text)
                let x = min(max(tip.frame.midX - size.width / 2, 8), max(8, geo.size.width - size.width - 8))
                let below = tip.frame.maxY + 7
                let fitsBelow = below + size.height <= geo.size.height - 6
                let y = fitsBelow ? below : max(6, tip.frame.minY - 7 - size.height)
                TipBubble(text: tip.text)
                    .frame(width: size.width, height: size.height)
                    .offset(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: fitsBelow ? .top : .bottom)))
                    .id(tip.id)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: tips.current?.id)
    }
}

struct TipBubble: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    static let maxTextWidth: CGFloat = 224
    static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let hPadding: CGFloat = 11
    static let vPadding: CGFloat = 7

    /// Taille exacte calculée avec les métriques du texte (pas de mesure en deux temps, pas de saut).
    static func size(for text: String) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let single = (text as NSString).size(withAttributes: attributes)
        let width = min(ceil(single.width) + 1, maxTextWidth)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
        )
        return CGSize(width: width + hPadding * 2, height: ceil(bounds.height) + vPadding * 2)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.hPadding)
            .padding(.vertical, Self.vPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassEffect(
                .regular.tint(scheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}
