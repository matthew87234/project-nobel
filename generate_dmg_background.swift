import AppKit
import CoreGraphics

let width: CGFloat = 600
let height: CGFloat = 380

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

// 1. Sleek Modern Light Gradient (Ensures Finder black icon labels are crystal-clear and crisp)
let colors = [
    NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0).cgColor,
    NSColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1.0).cgColor
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

// 2. Subtle Icon Plate Target Circles (Highlights where icons sit)
func drawTargetCircle(center: CGPoint, radius: CGFloat) {
    context.saveGState()
    context.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
    context.setStrokeColor(NSColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 0.8).cgColor)
    context.setLineWidth(1.5)
    
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.fillEllipse(in: rect)
    context.strokeEllipse(in: rect)
    context.restoreGState()
}

drawTargetCircle(center: CGPoint(x: 150, y: 195), radius: 68)
drawTargetCircle(center: CGPoint(x: 450, y: 195), radius: 68)

// 3. Beautiful Modern Curved / Gradient Arrow in Center
context.saveGState()
let arrowY: CGFloat = 195
let startX: CGFloat = 238
let endX: CGFloat = 362

// Arrow line shadow
context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.08).cgColor)

// Main Arrow Line
context.setStrokeColor(NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.75).cgColor)
context.setLineWidth(4.0)
context.setLineCap(.round)
context.beginPath()
context.move(to: CGPoint(x: startX, y: arrowY))
context.addLine(to: CGPoint(x: endX - 12, y: arrowY))
context.strokePath()

// Arrow Head
context.setFillColor(NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.9).cgColor)
context.beginPath()
context.move(to: CGPoint(x: endX, y: arrowY))
context.addLine(to: CGPoint(x: endX - 14, y: arrowY + 9))
context.addLine(to: CGPoint(x: endX - 11, y: arrowY))
context.addLine(to: CGPoint(x: endX - 14, y: arrowY - 9))
context.closePath()
context.fillPath()
context.restoreGState()

// 4. Clean Typography
let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphicsContext

let titleParagraphStyle = NSMutableParagraphStyle()
titleParagraphStyle.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .bold),
    .foregroundColor: NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0),
    .paragraphStyle: titleParagraphStyle
]

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(red: 0.45, green: 0.48, blue: 0.54, alpha: 1.0),
    .paragraphStyle: titleParagraphStyle
]

let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(red: 0.35, green: 0.40, blue: 0.48, alpha: 1.0),
    .paragraphStyle: titleParagraphStyle
]

let titleRect = CGRect(x: 0, y: 325, width: width, height: 26)
("Project Nobel" as NSString).draw(in: titleRect, withAttributes: titleAttributes)

let subtitleRect = CGRect(x: 0, y: 304, width: width, height: 18)
("Physics Study App" as NSString).draw(in: subtitleRect, withAttributes: subtitleAttributes)

let hintRect = CGRect(x: 0, y: 35, width: width, height: 20)
("Drag Project Nobel to Applications to install" as NSString).draw(in: hintRect, withAttributes: hintAttributes)

// 5. Save PNG
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
print("Successfully generated clean 600x380 background at: \(outputURL.path)")
