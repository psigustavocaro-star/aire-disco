import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    let shell = CGPath(roundedRect: CGRect(x: 65, y: 66, width: 894, height: 894),
                       cornerWidth: 207, cornerHeight: 207, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 45, color: color(0.02, 0.04, 0.09, 0.60))
    ctx.setFillColor(color(0.04, 0.12, 0.19))
    ctx.addPath(shell)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shell)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [color(0.12, 0.36, 0.43), color(0.06, 0.20, 0.30), color(0.035, 0.075, 0.15)] as CFArray,
                               locations: [0, 0.58, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 185, y: 975), end: CGPoint(x: 810, y: 118),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    for radius: CGFloat in [180, 234, 289, 344, 399] {
        ctx.setStrokeColor(color(0.52, 0.95, 0.91, 0.085))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: 764 - radius, y: 795 - radius, width: radius * 2, height: radius * 2))
    }
    ctx.restoreGState()
    ctx.addPath(shell)
    ctx.setStrokeColor(color(0.69, 0.98, 0.95, 0.28))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The drive and three airflow strokes form the wordless mark.
    let drive = CGPath(roundedRect: CGRect(x: 224, y: 247, width: 575, height: 205),
                       cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -17), blur: 25, color: color(0, 0.03, 0.10, 0.57))
    ctx.setFillColor(color(0.05, 0.16, 0.23))
    ctx.addPath(drive)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(drive)
    ctx.setStrokeColor(color(0.63, 0.99, 0.86))
    ctx.setLineWidth(17)
    ctx.strokePath()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0.27, 0.59, 0.64))
    ctx.setLineWidth(15)
    ctx.move(to: CGPoint(x: 295, y: 344))
    ctx.addLine(to: CGPoint(x: 531, y: 344))
    ctx.strokePath()
    for x: CGFloat in [666, 725] {
        ctx.setFillColor(x > 700 ? color(0.46, 0.99, 0.73) : color(0.27, 0.60, 0.62))
        ctx.fillEllipse(in: CGRect(x: x - 12, y: 331, width: 24, height: 24))
    }
    let lines: [(CGFloat, CGFloat, CGFloat, CGFloat, CGColor)] = [
        (265, 529, 650, 605, color(0.39, 0.87, 0.76)),
        (314, 631, 767, 747, color(0.74, 1.0, 0.91)),
        (408, 737, 620, 818, color(0.56, 0.96, 0.82))
    ]
    for (x, y, endX, endY, stroke) in lines {
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(28)
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addCurve(to: CGPoint(x: endX, y: endY),
                     control1: CGPoint(x: x + (endX - x) * 0.60, y: y),
                     control2: CGPoint(x: endX - 38, y: y - 11))
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

func png(_ pixels: Int) -> Data {
    let bytes = NSMutableData()
    let writer = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, render(pixels), nil)
    precondition(CGImageDestinationFinalize(writer))
    return bytes as Data
}
func header(_ name: String, _ count: Int) -> Data {
    var size = UInt32(count).bigEndian
    var bytes = Data(name.utf8)
    withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }
    return bytes
}
let representations = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
    ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)
]
var encoded: [Int: Data] = [:]
var body = Data()
for (name, pixels) in representations {
    let image = encoded[pixels] ?? png(pixels)
    encoded[pixels] = image
    body.append(header(name, image.count + 8))
    body.append(image)
}
var icon = header("icns", body.count + 8)
icon.append(body)
try icon.write(to: output.appendingPathComponent("Aire.icns"))
try encoded[512]!.write(to: output.appendingPathComponent("Logo.png"))
