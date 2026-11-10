import Cocoa

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// 1. Sfondo trasparente
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// 2. Squircle macOS standard (inset di 80px per dare margine Dock)
let inset: CGFloat = 82
let squircleRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius: CGFloat = (size - inset * 2) * 0.224
let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Ombra esterna squircle
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 40, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
ctx.addPath(squirclePath)
ctx.setFillColor(CGColor(red: 0.05, green: 0.03, blue: 0.035, alpha: 1.0))
ctx.fillPath()
ctx.restoreGState()

// Clip all'interno dello squircle
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// Sfondo con sfumatura radiale interna scura
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    CGColor(red: 0.18, green: 0.06, blue: 0.07, alpha: 1.0),
    CGColor(red: 0.07, green: 0.03, blue: 0.035, alpha: 1.0),
    CGColor(red: 0.02, green: 0.01, blue: 0.015, alpha: 1.0)
] as CFArray
let bgLocations: [CGFloat] = [0.0, 0.6, 1.0]
if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
    ctx.drawRadialGradient(bgGradient,
                           startCenter: CGPoint(x: size/2, y: size/2 + 40), startRadius: 20,
                           endCenter: CGPoint(x: size/2, y: size/2), endRadius: size * 0.55,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Bordo squircle interno sottile
ctx.saveGState()
ctx.setLineWidth(3.0)
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.35, blue: 0.3, alpha: 0.25))
ctx.addPath(squirclePath)
ctx.strokePath()
ctx.restoreGState()

let center = CGPoint(x: size/2, y: size/2)

// 3. Glow diffuso rosso dietro l'orb
ctx.saveGState()
let glowColors = [
    CGColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.55),
    CGColor(red: 0.8, green: 0.05, blue: 0.1, alpha: 0.25),
    CGColor(red: 0.4, green: 0.0, blue: 0.05, alpha: 0.0)
] as CFArray
let glowLocations: [CGFloat] = [0.0, 0.45, 1.0]
if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: glowLocations) {
    ctx.drawRadialGradient(glowGrad,
                           startCenter: center, startRadius: 30,
                           endCenter: center, endRadius: 260,
                           options: [.drawsAfterEndLocation])
}
ctx.restoreGState()

// 4. Anello / Arco esterno tecnologico
ctx.saveGState()
ctx.setLineWidth(14)
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.25, blue: 0.22, alpha: 0.85))
ctx.setShadow(offset: .zero, blur: 24, color: CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9))

let arcRadius1: CGFloat = 190
// Arco superiore
ctx.addArc(center: center, radius: arcRadius1, startAngle: 0.2, endAngle: .pi - 0.2, clockwise: false)
ctx.strokePath()

// Arco inferiore
ctx.addArc(center: center, radius: arcRadius1, startAngle: .pi + 0.2, endAngle: .pi * 2 - 0.2, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// 5. Tacche / segmenti tecnologici concentrici
ctx.saveGState()
ctx.setLineWidth(6)
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.4, blue: 0.35, alpha: 0.6))
let arcRadius2: CGFloat = 220
for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 6) {
    let p1 = CGPoint(x: center.x + CGFloat(cos(angle)) * (arcRadius2 - 10),
                     y: center.y + CGFloat(sin(angle)) * (arcRadius2 - 10))
    let p2 = CGPoint(x: center.x + CGFloat(cos(angle)) * (arcRadius2 + 10),
                     y: center.y + CGFloat(sin(angle)) * (arcRadius2 + 10))
    ctx.move(to: p1)
    ctx.addLine(to: p2)
}
ctx.strokePath()
ctx.restoreGState()

// 6. Nucleo Orb centrale
ctx.saveGState()
let coreRadius: CGFloat = 120
let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)

// Bagliore intenso
ctx.setShadow(offset: .zero, blur: 50, color: CGColor(red: 1.0, green: 0.25, blue: 0.2, alpha: 1.0))

let orbColors = [
    CGColor(red: 1.0, green: 0.92, blue: 0.90, alpha: 1.0),
    CGColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1.0),
    CGColor(red: 0.85, green: 0.08, blue: 0.15, alpha: 1.0),
    CGColor(red: 0.45, green: 0.02, blue: 0.05, alpha: 1.0)
] as CFArray
let orbLocations: [CGFloat] = [0.0, 0.25, 0.70, 1.0]
if let orbGrad = CGGradient(colorsSpace: colorSpace, colors: orbColors, locations: orbLocations) {
    ctx.drawRadialGradient(orbGrad,
                           startCenter: CGPoint(x: center.x - 25, y: center.y + 25), startRadius: 5,
                           endCenter: center, endRadius: coreRadius,
                           options: [.drawsAfterEndLocation])
}
ctx.restoreGState()

// 7. Riflesso lucido superiore vetro
ctx.saveGState()
let reflexPath = CGMutablePath()
reflexPath.addEllipse(in: CGRect(x: center.x - 70, y: center.y + 15, width: 140, height: 75))
ctx.addPath(reflexPath)
ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.35))
ctx.fillPath()
ctx.restoreGState()

ctx.restoreGState() // fine clip squircle

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}

let outPath = FileManager.default.currentDirectoryPath + "/Resources/Fulcro-1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("Generata con successo: \(outPath)")
