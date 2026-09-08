// Draws Readout's app icon and writes Icon.icns.
//
// Generated rather than hand-drawn so the mark stays in step with the one in
// the menu bar: a gauge dial with a needle just past half. Run through
// Scripts/make_icon.sh.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// Apple's icon grid: on a 1024 canvas the rounded square is 824 wide, centred,
/// leaving room for the shadow the system expects to sit under it.
let canvas: CGFloat = 1024
let plateInset: CGFloat = 100
let plateSize = canvas - plateInset * 2

/// A superellipse, not a rounded rectangle. macOS corners are continuous, and a
/// circular corner reads as visibly rounder next to the system's own icons.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720

    for step in 0 ... steps {
        let theta = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(theta)
        let sinT = sin(theta)
        // Signed power keeps the curve in the right quadrant.
        let x = a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        let point = CGPoint(x: centre.x + x, y: centre.y + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Colours

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Drawing

func drawIcon(in context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let plate = CGRect(x: plateInset, y: plateInset, width: plateSize, height: plateSize)
    let platePath = squircle(in: plate)

    // The shadow sits under the plate, the way the system draws its own icons.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -canvas * 0.018),
        blur: canvas * 0.038,
        color: rgb(0, 0, 0, 0.32)
    )
    context.addPath(platePath)
    context.setFillColor(rgb(20, 26, 38))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.clip()

    // Graphite ground, so the dial reads as an instrument face rather than a
    // coloured tile, with the accent kept for the needle.
    let ground = CGGradient(
        colorsSpace: space,
        colors: [rgb(58, 66, 84), rgb(24, 29, 41)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        ground,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )

    // A soft highlight across the top third, the light every macOS icon has.
    let sheen = CGGradient(
        colorsSpace: space,
        colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.midY + plate.height * 0.05),
        options: []
    )

    drawDial(in: context, plate: plate)
    context.restoreGState()

    // Hairline rim, which keeps the plate's edge crisp on a light desktop.
    context.addPath(platePath)
    context.setStrokeColor(rgb(255, 255, 255, 0.14))
    context.setLineWidth(canvas * 0.004)
    context.strokePath()
}

func drawDial(in context: CGContext, plate: CGRect) {
    let centre = CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.085)
    let radius = plate.width * 0.315
    let track = plate.width * 0.085

    // The dial sweeps 240°, the span an instrument uses: from lower left round
    // through the top to lower right.
    let start: CGFloat = 210 * .pi / 180
    let end: CGFloat = -30 * .pi / 180

    // Unfilled track.
    context.setLineCap(.round)
    context.setLineWidth(track)
    context.setStrokeColor(rgb(255, 255, 255, 0.24))
    context.addArc(center: centre, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    context.strokePath()

    // Filled portion, ending where the needle points.
    let reading: CGFloat = 0.62
    let needleAngle = start - (start - end) * reading
    context.saveGState()
    context.setLineWidth(track)
    context.addArc(center: centre, radius: radius, startAngle: start, endAngle: needleAngle, clockwise: true)
    context.replacePathWithStrokedPath()
    context.clip()
    let sweep = CGGradient(
        colorsSpace: space,
        colors: [rgb(64, 156, 255), rgb(120, 210, 255)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sweep,
        start: CGPoint(x: centre.x - radius, y: centre.y),
        end: CGPoint(x: centre.x + radius, y: centre.y + radius),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    // Needle: a tapered blade rather than a line, and deliberately short and
    // broad. At 16 points a slender needle renders as a faint smudge and the
    // dial stops reading as an instrument, so it is drawn heavier than it
    // would be at full size.
    let needleLength = radius * 0.72
    let baseWidth = plate.width * 0.066
    let tip = CGPoint(
        x: centre.x + cos(needleAngle) * needleLength,
        y: centre.y + sin(needleAngle) * needleLength
    )
    let perpendicular = needleAngle + .pi / 2
    let offset = CGPoint(x: cos(perpendicular) * baseWidth / 2, y: sin(perpendicular) * baseWidth / 2)

    let needle = CGMutablePath()
    needle.move(to: CGPoint(x: centre.x + offset.x, y: centre.y + offset.y))
    needle.addLine(to: tip)
    needle.addLine(to: CGPoint(x: centre.x - offset.x, y: centre.y - offset.y))
    needle.closeSubpath()

    context.addPath(needle)
    context.setFillColor(rgb(255, 255, 255))
    context.fillPath()

    // Hub.
    let hub = plate.width * 0.052
    context.setFillColor(rgb(255, 255, 255))
    context.fillEllipse(in: CGRect(
        x: centre.x - hub / 2, y: centre.y - hub / 2, width: hub, height: hub
    ))
    let core = hub * 0.42
    context.setFillColor(rgb(30, 36, 48))
    context.fillEllipse(in: CGRect(
        x: centre.x - core / 2, y: centre.y - core / 2, width: core, height: core
    ))
}

// MARK: - Output

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(in: context)
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)

// The names iconutil expects in an .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    write(render(size: variant.pixels), to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) sizes to \(outputDirectory.path)")
