import AppKit
import SwiftUI

/// Panneau sans bordure qui peut prendre le focus clavier sans activer l’app (comme le Centre de contrôle).
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Réglages du verre du panneau (valeurs calibrées par captures face au Centre de contrôle de macOS 27).
struct PanelGlassStyle: Equatable {
    /// Panneau en verre « regular » : il floute l’arrière-plan (texte d’un terminal, d’une page) pour rester lisible.
    /// Le verre « clear » laissait lire le texte de derrière à travers le panneau (écarté après captures).
    /// L’aspect liquide vient des modules, en verre « clear » (voir M / ModuleGlass).
    var clear = false
    /// Voile noir (sombre) ou blanc (clair), 0…1. 0,12 : la couleur du fond d’écran traverse encore.
    var dimming: CGFloat = 0.12
    var cornerRadius: CGFloat = M.panelRadius
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: GlassPanel
    private let container = NSView()
    private let glass = NSGlassEffectView()
    private let hosting: NSHostingView<RootView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pointerTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastClose = Date.distantPast
    private var height: CGFloat = 480
    private(set) var isOpen = false
    weak var statusButton: NSStatusBarButton?
    var style = PanelGlassStyle() { didSet { applyStyle() } }

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: RootView(model: model))
        hosting.sizingOptions = []
        panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: M.width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        glass.contentView = hosting
        glass.autoresizingMask = [.width, .height]
        // Conteneur arrondi : la fenêtre n’a de pixels opaques que dans la forme du verre,
        // donc l’ombre système suit les coins arrondis (sinon un cadre rectangulaire apparaît).
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(glass)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = container
        panel.delegate = self
        applyStyle()

        model.onHeightChange = { [weak self] newHeight in
            self?.resize(to: newHeight)
        }
        model.closePanel = { [weak self] in
            self?.close()
        }
        // Le voile suit le mode clair / sombre.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyStyle() }
        }
        // Mise en page initiale hors écran : la hauteur réelle est connue dès la première ouverture.
        container.frame = NSRect(x: 0, y: 0, width: M.width, height: height)
        glass.frame = container.bounds
        glass.layoutSubtreeIfNeeded()
    }

    private func applyStyle() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        glass.style = style.clear ? .clear : .regular
        glass.cornerRadius = style.cornerRadius
        glass.tintColor = style.dimming > 0
            ? (dark ? NSColor.black : NSColor.white).withAlphaComponent(style.dimming)
            : nil
        container.layer?.cornerRadius = style.cornerRadius
        panel.invalidateShadow()
    }

    func toggle() {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.3 {
            open()
        }
    }

    func open(screen: Screen = .main) {
        model.screen = screen
        model.panelVisible = true
        model.panelDidOpen()
        hosting.layoutSubtreeIfNeeded()
        panel.setFrame(frame(for: height), display: false)
        if !isOpen {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            })
        }
        isOpen = true
        statusButton?.highlight(true)
        installMonitors()
        startPointerTracking()
        writeDiagnostic()
    }

    /// Dernière ouverture du panneau (position, taille, écran) : aide au diagnostic.
    private func writeDiagnostic() {
        let item = statusButton?.window.map { $0.convertToScreen(statusButton!.convert(statusButton!.bounds, to: nil)) }
        let text = """
        ouverture : \(Date().formatted(.iso8601))
        panneau : \(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) clé=\(panel.isKeyWindow)
        icône : \(item.map(NSStringFromRect) ?? "aucune")
        écran : \(panel.screen?.localizedName ?? "?") \(panel.screen.map { NSStringFromRect($0.frame) } ?? "")

        """
        try? text.write(to: Paths.support.appending(path: "panel-diagnostic.txt"), atomically: true, encoding: .utf8)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        lastClose = Date()
        removeMonitors()
        stopPointerTracking()
        statusButton?.highlight(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                self.model.panelVisible = false
                self.model.screen = .main
            }
        })
    }

    // MARK: Position et taille (bord haut fixe, sous l’icône)

    private func frame(for height: CGFloat) -> NSRect {
        guard let button = statusButton, let buttonWindow = button.window else {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: screen.maxX - M.width - 8, y: screen.maxY - height - 6, width: M.width, height: height)
        }
        let itemRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = itemRect.minX
        x = min(max(x, visible.minX + 8), visible.maxX - M.width - 8)
        let top = min(itemRect.minY, visible.maxY) - 6
        return NSRect(x: x, y: top - height, width: M.width, height: height)
    }

    private func resize(to newHeight: CGFloat) {
        guard newHeight > 50, abs(newHeight - height) > 0.5 else { return }
        height = newHeight
        guard isOpen else { return }
        let target = frame(for: newHeight)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        })
    }

    // MARK: Fermeture (clic à l’extérieur, Échap)

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Un clic ferme la bulle d’explication, comme les bulles de macOS.
            if event.type == .leftMouseDown {
                MainActor.assumeIsolated { self.model.tips.hideAll() }
                return event
            }
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                if self.model.screen != .main {
                    self.model.screen = .main
                } else {
                    self.close()
                }
            }
            return nil
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: Survol (bulles d’explication, surbrillance)

    /// Relève la position du curseur 30 fois par seconde, panneau ouvert seulement. Contrairement au survol
    /// SwiftUI, cela fonctionne même si l’app n’est pas active (cas permanent d’un panneau de barre des menus).
    private func startPointerTracking() {
        stopPointerTracking()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        model.tips.reset()
    }

    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard panel.isVisible, frame.contains(mouse) else {
            model.tips.pointerMoved(to: nil)
            return
        }
        // Repère du panneau, origine en haut à gauche (celui de TipCenter.space).
        model.tips.pointerMoved(to: CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y))
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
