// Génère Resources/AppIcon.icon : document Icon Composer (Liquid Glass) pour macOS 26+.
// Usage : swift tools/make-icon.swift <dossier AppIcon.icon>
//
// Dessin original (lune + deux étoiles en courbes de Bézier) : la licence des SF Symbols
// interdit de les utiliser dans une icône d’app. Les calques sont blancs sur fond transparent ;
// le rendu verre (reflets, réfraction, ombres, variantes sombre / teintée / transparente) est fait par macOS.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = output.appending(path: "Assets")
try? FileManager.default.removeItem(at: output)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let size: CGFloat = 1024

func renderLayer(named name: String, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.setFillColor(NSColor.white.cgColor)
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: assets.appending(path: name))
}

/// Étoile à quatre branches aux flancs incurvés (✦).
func sparkle(center c: CGPoint, radius r: CGFloat, pinch: CGFloat = 0.16) -> CGPath {
    let path = CGMutablePath()
    let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y),
                CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
    path.move(to: tips[0])
    for i in 0..<4 {
        let next = tips[(i + 1) % 4]
        let mid = CGPoint(x: (tips[i].x + next.x) / 2, y: (tips[i].y + next.y) / 2)
        let control = CGPoint(x: c.x + (mid.x - c.x) * pinch * 2, y: c.y + (mid.y - c.y) * pinch * 2)
        path.addQuadCurve(to: next, control: control)
    }
    path.closeSubpath()
    return path
}

// Croissant : disque principal moins un disque décalé vers le haut à droite (là où sont les étoiles).
let moonCenter = CGPoint(x: 470, y: 470)
let moonRadius: CGFloat = 300
let biteCenter = CGPoint(x: 610, y: 600)
let biteRadius: CGFloat = 262

renderLayer(named: "moon.png") { ctx in
    ctx.fillEllipse(in: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
                               width: moonRadius * 2, height: moonRadius * 2))
    // Morsure : on efface (différence de formes), sans peindre ce qui dépasse du disque.
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: biteCenter.x - biteRadius, y: biteCenter.y - biteRadius,
                               width: biteRadius * 2, height: biteRadius * 2))
    ctx.setBlendMode(.normal)
}

renderLayer(named: "stars.png") { ctx in
    ctx.addPath(sparkle(center: CGPoint(x: 676, y: 676), radius: 92))
    ctx.addPath(sparkle(center: CGPoint(x: 806, y: 518), radius: 52))
    ctx.fillPath()
}

let icon: [String: Any] = [
    "fill": ["linear-gradient": [
        "display-p3:0.07000,0.06000,0.22000,1.00000",
        "display-p3:0.38000,0.22000,0.74000,1.00000",
    ]],
    "groups": [
        [
            "name": "Étoiles",
            "layers": [["name": "Étoiles", "image-name": "stars.png", "glass": true]],
            "lighting": "individual",
            "specular": true,
            "shadow": ["kind": "layer-color", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.35],
        ],
        [
            "name": "Lune",
            "layers": [["name": "Lune", "image-name": "moon.png", "glass": true]],
            "lighting": "individual",
            "specular": true,
            "shadow": ["kind": "layer-color", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.25],
        ],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
let data = try! JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: output.appending(path: "icon.json"))
print("Document Icon Composer généré : \(output.path)")
