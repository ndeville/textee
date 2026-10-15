// Writes each app's Finder icon as a PNG, for the chart's column heads.
// swift bench/appicons.swift <out dir> <size px> <name>=<app path> ...
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let size = Int(args[2])!
for pair in args.dropFirst(3) {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    let icon = NSWorkspace.shared.icon(forFile: parts[1])
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(parts[0]).png"))
    print("✅ \(parts[0])")
}
