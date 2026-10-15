import AppKit
import Foundation

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.setFillColor(NSColor(red: 0.035, green: 0.044, blue: 0.066, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let lime = NSColor(red: 0.78, green: 0.96, blue: 0.20, alpha: 1)
let cyan = NSColor(red: 0.23, green: 0.83, blue: 0.96, alpha: 1)
ctx.setStrokeColor(cyan.withAlphaComponent(0.35).cgColor)
ctx.setLineWidth(3)
for radius in [180.0, 280.0, 380.0] { ctx.strokeEllipse(in: CGRect(x: 512-radius, y: 512-radius, width: radius*2, height: radius*2)) }
let nodes: [CGPoint] = [CGPoint(x: 248, y: 730), CGPoint(x: 488, y: 602), CGPoint(x: 702, y: 754), CGPoint(x: 793, y: 440), CGPoint(x: 526, y: 278), CGPoint(x: 260, y: 372)]
ctx.setLineWidth(12)
ctx.setStrokeColor(cyan.withAlphaComponent(0.65).cgColor)
ctx.move(to: nodes[0]); for point in nodes.dropFirst() { ctx.addLine(to: point) }; ctx.strokePath()
ctx.setStrokeColor(lime.cgColor); ctx.setLineWidth(18)
ctx.move(to: nodes[0]); ctx.addLine(to: nodes[1]); ctx.addLine(to: nodes[4]); ctx.strokePath()
for (index, node) in nodes.enumerated() {
    ctx.setShadow(offset: .zero, blur: 38, color: (index == 1 ? lime : cyan).withAlphaComponent(0.5).cgColor)
    ctx.setFillColor((index == 1 ? lime : cyan).cgColor)
    let radius = index == 1 ? 46.0 : 23.0
    ctx.fillEllipse(in: CGRect(x: node.x-radius, y: node.y-radius, width: radius*2, height: radius*2))
    ctx.setShadow(offset: .zero, blur: 0)
}
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(4)
ctx.move(to: CGPoint(x: 168, y: 140)); ctx.addLine(to: CGPoint(x: 856, y: 140)); ctx.strokePath()
for x in stride(from: 208.0, through: 848, by: 80) { ctx.move(to: CGPoint(x: x, y: 124)); ctx.addLine(to: CGPoint(x: x, y: 156)); ctx.strokePath() }
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
