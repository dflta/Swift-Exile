// Converts the menu bar emblem (an SVG made of absolute M/L/C/Z paths) into a vector PDF that
// AppKit loads as a template image:
//   swift Scripts/make-status-icon.swift Resources/StatusIcon.svg Resources/StatusIcon.pdf
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let svg = try String(contentsOfFile: args[1], encoding: .utf8)

func firstMatch(_ pattern: String, in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
    return (1..<match.numberOfRanges).map { String(text[Range(match.range(at: $0), in: text)!]) }
}

let box = firstMatch(#"viewBox="([\d.\-]+) ([\d.\-]+) ([\d.\-]+) ([\d.\-]+)""#, in: svg).compactMap(Double.init)
let width = box[2], height = box[3]

let pathRegex = try NSRegularExpression(pattern: #"\sd="([^"]+)""#)
let paths = pathRegex.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).map {
    String(svg[Range($0.range(at: 1), in: svg)!])
}

/// Absolute M, L, C, Z only (with implicit repeats), y flipped for PDF coordinates.
func cgPath(_ data: String) -> CGMutablePath {
    let path = CGMutablePath()
    let tokens = data.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
    var index = 0, command = ""
    func number() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index])!) }
    func point() -> CGPoint { let x = number(); let y = number(); return CGPoint(x: x, y: height - y) }
    while index < tokens.count {
        if let first = tokens[index].first, first.isLetter {
            command = tokens[index]; index += 1
            if command == "Z" || command == "z" { path.closeSubpath(); continue }
        }
        switch command {
        case "M": path.move(to: point()); command = "L" // further pairs are line-tos
        case "L": path.addLine(to: point())
        case "C": let c1 = point(); let c2 = point(); path.addCurve(to: point(), control1: c1, control2: c2)
        default: fatalError("unsupported SVG path command \(command)")
        }
    }
    return path
}

var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
let pdf = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(CGColor(gray: 0, alpha: 1)) // template images use only the alpha channel
for data in paths {
    pdf.addPath(cgPath(data))
    pdf.fillPath(using: .evenOdd)
}
pdf.endPDFPage()
pdf.closePDF()
print("wrote \(args[2]) (\(Int(width))×\(Int(height)), \(paths.count) paths)")
