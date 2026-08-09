#!/usr/bin/env swift
// Generates switchr/AppIcon.icon — an Apple Icon Composer package (Xcode 26 / macOS Tahoe).
// Icon Composer icons are icon.json (a fill plus one or more layer groups) + PNG layer assets;
// the system applies the squircle mask, glass shading, and specular highlight itself. The
// keycap look comes from Icon Composer's own depth model rather than hand-baked shading: the
// key face is a separate group in front of the dark backdrop fill, so the system casts a real
// shadow from its silhouette onto the backdrop behind it.
import AppKit

let _ = NSApplication.shared

func renderLayer(size: Int, draw: (CGFloat) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    draw(CGFloat(size))

    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "switchr/AppIcon.icon"

let assetsDir = "\(outDir)/Assets"
try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)

var ok = true
func write(_ data: Data?, name: String) {
    guard let data else { print("✗ \(name): render failed"); ok = false; return }
    do {
        try data.write(to: URL(fileURLWithPath: "\(assetsDir)/\(name)"))
        print("✓ \(name)")
    } catch {
        print("✗ \(name): \(error.localizedDescription)")
        ok = false
    }
}

// Key face: a hand-baked keycap bezel (rim / face), matching hypr's make-icon.swift
// approach. Icon Composer's automatic glass + translucency read as a soft frosted badge with
// no discernible edge, not a keycap, so the rim that actually sells "physical key" is baked
// into the raster instead of left to the system's shading. The rim is concentric with the
// face on all four sides — an earlier version offset the rim downward to fake a shadow lip,
// which pulled the whole silhouette off-centre in the rendered icon (visible once Icon
// Composer's own specular/shadow was layered on top). Directional lighting is left entirely
// to Icon Composer's specular + shadow on the group, which keeps the baked geometry centred.
let keyData = renderLayer(size: 1024) { s in
    let inset = s * 0.13
    let cornerR = s * 0.11
    let keyW = s - 2 * inset

    // Rim
    NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: keyW, height: keyW),
        xRadius: cornerR, yRadius: cornerR
    ).fill()

    // Face: inset within the rim by the same amount on all sides, so both are centred on canvas.
    let fi = s * 0.030
    NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: inset + fi, y: inset + fi,
                            width: keyW - 2 * fi, height: keyW - 2 * fi),
        xRadius: cornerR - fi, yRadius: cornerR - fi
    ).fill()
}
write(keyData, name: "key.png")

// Binoculars glyph — echoes the 🔭 in switchr's README ("Window and tab finder"). Centred on
// the same canvas as the key face so the two align without needing separate per-layer offsets.
let glyphData = renderLayer(size: 1024) { s in
    guard let symbol = NSImage(systemSymbolName: "binoculars.fill", accessibilityDescription: nil) else { return }
    let config = NSImage.SymbolConfiguration(paletteColors: [.white])
    let colored = symbol.withSymbolConfiguration(config) ?? symbol
    let symH = s * 0.34
    let ratio = colored.size.width / max(colored.size.height, 1)
    let symW = symH * ratio
    colored.draw(
        in: NSRect(x: (s - symW) / 2, y: (s - symH) / 2, width: symW, height: symH),
        from: .zero, operation: .sourceOver, fraction: 1.0
    )
}
write(glyphData, name: "glyph.png")

let iconJSON = """
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.11000,0.11000,0.12000,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "glyph.png",
          "name" : "glyph"
        },
        {
          "glass" : false,
          "image-name" : "key.png",
          "name" : "key"
        }
      ],
      "lighting" : "combined",
      "specular" : true,
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.6
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}
"""

do {
    try iconJSON.write(toFile: "\(outDir)/icon.json", atomically: true, encoding: .utf8)
    print("✓ icon.json")
} catch {
    print("✗ icon.json: \(error.localizedDescription)")
    ok = false
}

exit(ok ? 0 : 1)
