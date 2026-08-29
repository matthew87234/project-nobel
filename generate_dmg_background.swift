import AppKit
import CoreGraphics

let width: CGFloat = 660
let height: CGFloat = 400
let scale: CGFloat = 2.0

let pixelWidth = Int(width * scale)
let pixelHeight = Int(height * scale)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: pixelWidth,
    height: pixelHeight,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

context.scaleBy(x: scale, y: scale)

// 1. Background Gradient (Dark macOS aesthetic)
let colors = [
    NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0).cgColor,
    NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0).cgColor
] as CFArray
let locations: [CGFloat] = [0.0, 1.0]
if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

// 2. Subtle decorative glow under icons
func drawGlow(center: CGPoint, radius: CGFloat, color: NSColor) {
    context.saveGState()
    let glowColors = [
        color.withAlphaComponent(0.12).cgColor,
        color.withAlphaComponent(0.0).cgColor
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        context.drawRadialGradient(
            glowGrad,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
    }
    context.restoreGState()
}

drawGlow(center: CGPoint(x: 170, y: 200), radius: 100, color: .systemBlue)
drawGlow(center: CGPoint(x: 490, y: 200), radius: 100, color: .systemIndigo)

// 3. Arrow between App and Applications (Flow Indicator)
context.saveGState()
let arrowY: CGFloat = 200
let startX: CGFloat = 270
let endX: CGFloat = 390

// Draw glowing horizontal arrow line
context.setStrokeColor(NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.6).cgColor)
context.setLineWidth(3.5)
context.setLineCap(.round)
context.beginPath()
context.move(to: CGPoint(x: startX, y: arrowY))
context.addLine(to: CGPoint(x: endX - 10, y: arrowY))
context.strokePath()

// Draw Arrowhead
context.setFillColor(NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.85).cgColor)
context.beginPath()
context.move(to: CGPoint(x: endX, y: arrowY))
context.addLine(to: CGPoint(x: endX - 14, y: arrowY + 8))
context.addLine(to: CGPoint(x: endX - 11, y: arrowY))
context.addLine(to: CGPoint(x: endX - 14, y: arrowY - 8))
context.closePath()
context.fillPath()
context.restoreGState()

// 4. Render Typography (Title & Instructions)
let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphicsContext

let titleParagraphStyle = NSMutableParagraphStyle()
titleParagraphStyle.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: titleParagraphStyle
]

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.65),
    .paragraphStyle: titleParagraphStyle
]

let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
    .foregroundColor: NSColor(red: 0.65, green: 0.78, blue: 1.0, alpha: 0.9),
    .paragraphStyle: titleParagraphStyle
]

let titleRect = CGRect(x: 0, y: 340, width: width, height: 30)
("Project Nobel" as NSString).draw(in: titleRect, withAttributes: titleAttributes)

let subtitleRect = CGRect(x: 0, y: 318, width: width, height: 22)
("Physics Study App" as NSString).draw(in: subtitleRect, withAttributes: subtitleAttributes)

let hintRect = CGRect(x: 0, y: 45, width: width, height: 25)
("Drag Project Nobel into Applications to install" as NSString).draw(in: hintRect, withAttributes: hintAttributes)

// 5. Output PNG
guard let imageRef = context.makeImage() else {
    fatalError("Could not create CGImage from context")
}

let bitmapRep = NSBitmapImageRep(cgImage: imageRef)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG data")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"
let outputURL = URL(fileURLWithPath: outputPath)
try pngData.write(to: outputURL)
print("Successfully generated background image at: \(outputURL.path)")
