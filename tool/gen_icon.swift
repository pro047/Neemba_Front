// Generates the two launcher-icon source PNGs for `dart run flutter_launcher_icons`.
// Placeholder artwork: lowercase "n" monogram on deep navy.
//   usage: swift tool/gen_icon.swift assets/icon

import AppKit
import CoreGraphics
import CoreText

let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let navy = CGColor(red: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 1)
let sky = CGColor(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0, alpha: 1)

func newContext() -> CGContext {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setShouldAntialias(true)
    return ctx
}

/// Glyph outline as a path, so the mark scales by geometry instead of by point size.
func monogramPath(targetHeight: CGFloat) -> CGPath {
    let font = CTFontCreateWithName(
        NSFont.systemFont(ofSize: 1000, weight: .heavy).fontName as CFString, 1000, nil)
    var chars = Array("n".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1),
          let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil)
    else { fatalError("glyph 'n' unavailable in the system font") }

    let box = raw.boundingBox
    let scale = targetHeight / box.height
    var t = CGAffineTransform(translationX: CGFloat(size) / 2 - box.midX * scale,
                              y: CGFloat(size) / 2 - box.midY * scale)
        .scaledBy(x: scale, y: scale)
    return raw.copy(using: &t)!
}

func write(_ ctx: CGContext, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    let p = monogramPath(targetHeight: 1).boundingBox  // aspect only, for the log
    print("\(name) 1024x1024  glyph aspect w/h=\(String(format: "%.2f", p.width))")
}

// icon.png — opaque square; iOS/web/macOS/Windows and the Android legacy icon.
let full = newContext()
full.setFillColor(navy)
full.fill(CGRect(x: 0, y: 0, width: size, height: size))
full.setFillColor(sky)
full.addPath(monogramPath(targetHeight: 480))
full.fillPath()
write(full, "icon.png")

// icon_foreground.png — transparent; Android adaptive foreground layer.
// flutter_launcher_icons already wraps this in <inset android:inset="16%">, which maps
// the whole PNG onto 73.44dp of the 108dp canvas. The 72dp mask circle then lands at
// radius 502px in PNG space, so 600pt tall (mark radius ~414px) still clears any mask.
let fg = newContext()
fg.setFillColor(sky)
fg.addPath(monogramPath(targetHeight: 600))
fg.fillPath()
write(fg, "icon_foreground.png")
