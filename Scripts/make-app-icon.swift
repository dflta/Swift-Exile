// Makes Resources/AppIcon.png, the 1024 px app icon master, from square artwork:
//   swift Scripts/make-app-icon.swift <artwork.png> Resources/AppIcon.png
// Follows the macOS icon grid; Scripts/bundle-app.sh turns the master into AppIcon.icns.
import AppKit
import CoreGraphics

// macOS icon grid: 1024 canvas, 824-pt rounded-square body, ~185 corner radius, soft drop shadow.
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let canvas: CGFloat = 1024, body: CGFloat = 824, radius: CGFloat = 185.4
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: (canvas - body) / 2, y: (canvas - body) / 2 + 10, width: body, height: body)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.5))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// Artwork clipped to the body.
ctx.saveGState()
ctx.addPath(path); ctx.clip()
var imageRect = CGRect(origin: .zero, size: source.size)
let cg = source.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)!
ctx.interpolationQuality = .high
let zoom: CGFloat = 1.18 // the emblem fills more of the icon; wing tips stay inside
ctx.draw(cg, in: rect.insetBy(dx: -rect.width * (zoom - 1) / 2, dy: -rect.height * (zoom - 1) / 2))
ctx.restoreGState()

// Thin inner edge so the dark icon doesn't melt into dark Docks.
ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(2); ctx.strokePath()

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
