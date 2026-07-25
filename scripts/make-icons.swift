#!/usr/bin/env swift
//
// Regenerates Escapement's two icon files from the free-form master art in
// App/Icon/freeform/.
//
// Escapement ships *two* icons on purpose, because macOS treats the two
// surfaces differently:
//
//   Escapement.icns          The bundle icon (CFBundleIconFile). Since macOS
//                            Tahoe the system clips every app icon to its own
//                            rounded-rect and, when the art has a transparent
//                            background, rescales it into a fixed inner box
//                            (~55% of the tile) and drops it on a generated
//                            light-grey plate. There is no opt-out.
//                            So this one is drawn full-bleed on a near-black
//                            ground: the system clip then lands entirely in
//                            our own background and the wheel is never
//                            shrunk, plated, or double-shadowed.
//
//   EscapementFreeform.icns  The real, free-form wheel. The app installs this
//                            as its Dock tile at launch (see AppDelegate);
//                            a runtime icon is exempt from the system clip,
//                            so the Dock and the ⌘-Tab switcher show the
//                            silhouette exactly as drawn.
//
// The masters are hand-tuned per size (16/32 px come from a simplified small
// master with fatter teeth), so each size is composited at its own resolution
// rather than downscaled from 1024.
//
// Usage: swift scripts/make-icons.swift   (writes into App/Icon/)

import AppKit
import CoreGraphics
import Foundation

// Background ramp, taken from the art's own outline colour so the wheel sits
// in the same material family as its ground.
let centerColor = (r: 0x1a / 255.0, g: 0x14 / 255.0, b: 0x0e / 255.0)
let edgeColor = (r: 0x0d / 255.0, g: 0x0a / 255.0, b: 0x06 / 255.0)

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = root.appendingPathComponent("App/Icon")
let freeformDir = iconDir.appendingPathComponent("freeform")

// The names iconutil requires, each with the pixel size it promises. The size
// is checked rather than trusted: iconutil silently *drops* a mis-sized
// representation and still exits 0, so an over- or under-sized master would
// otherwise yield a quietly incomplete .icns.
let masters: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default

/// The staging directory to clean up if the run dies part-way through, so a
/// failed run never leaves a stray .iconset sitting in App/Icon/.
var activeStaging: URL?

func fail(_ message: String) -> Never {
    if let staging = activeStaging { try? fm.removeItem(at: staging) }
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

/// Loads a PNG at its true pixel size (NSImage would report points), and holds
/// it to the size its filename claims.
func loadPNG(_ url: URL, expecting pixels: Int) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("could not read \(url.path)") }
    guard image.width == pixels, image.height == pixels else {
        fail("\(url.lastPathComponent) is \(image.width)×\(image.height), expected \(pixels)×\(pixels)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fail("could not create \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not write \(url.path)") }
}

/// Draws the art full-bleed over a radial ground, at the art's own resolution.
func composite(_ art: CGImage) -> CGImage {
    let width = art.width, height = art.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(width)×\(height) context") }

    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [centerColor.r, centerColor.g, centerColor.b, 1])!,
            CGColor(colorSpace: space, components: [edgeColor.r, edgeColor.g, edgeColor.b, 1])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    let center = CGPoint(x: rect.midX, y: rect.midY)
    // Out to the corner, so the ramp is fully inside the tile rather than
    // flattening off before the edge.
    let radius = sqrt(rect.width * rect.width + rect.height * rect.height) / 2
    ctx.drawRadialGradient(
        gradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // The masters are already inset a little for shadow room, which reads as a
    // correct optical margin once the system rounds the corners off.
    ctx.draw(art, in: rect)

    guard let out = ctx.makeImage() else { fail("could not render a \(width)×\(height) tile") }
    return out
}

func makeICNS(iconsetName: String, output: URL, transform: (CGImage) -> CGImage) {
    let staging = iconDir.appendingPathComponent(iconsetName)
    try? fm.removeItem(at: staging)
    do {
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    } catch { fail("could not create \(staging.path): \(error.localizedDescription)") }
    activeStaging = staging

    for master in masters {
        let src = freeformDir.appendingPathComponent(master.name + ".png")
        guard fm.fileExists(atPath: src.path) else { fail("missing master \(src.path)") }
        let art = loadPNG(src, expecting: master.pixels)
        writePNG(transform(art), to: staging.appendingPathComponent(master.name + ".png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", staging.path, "-o", output.path]
    do { try iconutil.run() } catch { fail("could not run iconutil: \(error.localizedDescription)") }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed for \(iconsetName)") }

    try? fm.removeItem(at: staging)
    activeStaging = nil
    print("wrote \(output.lastPathComponent)")
}

guard fm.fileExists(atPath: freeformDir.path) else {
    fail("run this from the repository root (no App/Icon/freeform found)")
}

makeICNS(
    iconsetName: "Escapement.iconset",
    output: iconDir.appendingPathComponent("Escapement.icns"),
    transform: composite
)
makeICNS(
    iconsetName: "EscapementFreeform.iconset",
    output: iconDir.appendingPathComponent("EscapementFreeform.icns"),
    transform: { $0 }
)
