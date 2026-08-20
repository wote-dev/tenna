// Generates every Tennanova icon from the two masters in assets/icon/.
//
// This exists because the .icns used to be a hand-produced binary with no regeneration
// path, and the Android drawable was a manual copy of a file at the repo root. Neither
// could be rebuilt when the artwork changed. Now both come from one command.
//
// The machine has Command Line Tools but not Xcode, and neither Pillow nor ImageMagick.
// `sips` can resize but cannot mask to a shape with alpha, which the macOS squircle and
// the round web favicon both need — hence CoreGraphics.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("make-icons: " + msg + "\n").utf8))
    exit(1)
}

func loadCGImage(_ path: String) -> CGImage {
    guard let data = FileManager.default.contents(atPath: path),
          let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { die("cannot read \(path)") }
    return img
}

func writePNG(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { die("cannot open \(path) for writing") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { die("failed writing \(path)") }
}

/// An RGBA8 copy of an image, row 0 = the image's TOP row, so indices line up with
/// `CGImage.cropping(to:)`'s top-left origin rather than CoreGraphics' bottom-left one.
///
/// A bitmap context already stores row 0 as the top row, so drawing the image plainly is
/// what produces that. Flipping the CTM first — the reflex when a bottom-left origin is
/// mentioned — stores it upside down. Verified with a two-row test image. It went unnoticed
/// for as long as it did because every reader here was symmetric about the vertical axis:
/// `artSquare` scans the exact middle row and `edgeTint` averages the whole border ring.
func rgba(_ img: CGImage) -> (px: [UInt8], w: Int, h: Int) {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { die("cannot create sampling context") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (px, w, h)
}

/// The artwork's bounding square, found by walking in from the flat backdrop the render
/// was generated on, so re-running against regenerated artwork does not silently crop it
/// wrong.
///
/// Only the horizontal centre line is measured. The tile's left and right edges are hard —
/// the detected span is 934px anywhere between threshold 20 and 55 — while its top fades
/// into a glow that is the same pale blue as the backdrop, so a naive 2D bounding box
/// grows by ~15% and drags the tile's own rounded corner back into the crop. That is the
/// tile-inside-the-system-mask artifact this whole function exists to avoid. Both masters
/// are centred renders, so one crisp axis is enough to place a square.
func artSquare(_ img: CGImage, insetFraction: CGFloat, threshold: Int = 30) -> CGRect {
    let (px, w, h) = rgba(img)
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
    // Average the four corners: one stray corner pixel should not define the backdrop.
    let probes = [at(2, 2), at(w - 3, 2), at(2, h - 3), at(w - 3, h - 3)]
    let bg = (probes.reduce(0) { $0 + $1.0 } / 4,
              probes.reduce(0) { $0 + $1.1 } / 4,
              probes.reduce(0) { $0 + $1.2 } / 4)

    var x0 = -1, x1 = -1
    for x in 0..<w {
        let (r, g, b) = at(x, h / 2)
        if max(abs(r - bg.0), abs(g - bg.1), abs(b - bg.2)) > threshold {
            if x0 < 0 { x0 = x }
            x1 = x
        }
    }
    guard x1 > x0 else { die("could not find artwork against its backdrop") }

    let cx = CGFloat(x0 + x1 + 1) / 2, cy = CGFloat(h) / 2
    var side = CGFloat(x1 - x0 + 1)
    side -= side * insetFraction * 2
    return CGRect(x: (cx - side / 2).rounded(), y: (cy - side / 2).rounded(),
                  width: side.rounded(), height: side.rounded())
}

/// Replaces the flat region touching the image border with the artwork's own rim colour.
///
/// A render whose transparency has been flattened arrives as the tile bleeding to all four
/// edges with *pure black* in the corners, rather than as a tile centred on a pale backdrop.
/// Every downstream path here assumes the second shape: `mask: .none` writes the crop
/// straight out as the Android adaptive-icon foreground, which is drawn full-bleed and
/// rounded by the launcher's own mask — so a black corner ships to the home screen. Masking
/// to a superellipse does not fix it either, because the tile's corner is rounded more
/// tightly than a superellipse and the black survives inside the mask.
///
/// So the backdrop is identified by colour and by touching the border, not by shape, and
/// repainted in the tile's rim colour. On a master that is already a tile on a flat
/// backdrop the two colours match and this returns the image untouched.
///
/// It also returns where the tile is, because the flood fill has just measured that
/// exactly and `artSquare` cannot: once a full-bleed render has been repainted, its rim and
/// its new corners are the same pale colour, so the contrast walk locks onto the gradient
/// *inside* the mark and crops it off-centre.
func flattenBackdrop(_ img: CGImage) -> (image: CGImage, tile: CGRect?) {
    var (px, w, h) = rgba(img)
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
    func mean(_ probes: [(Int, Int, Int)]) -> (Int, Int, Int) {
        (probes.reduce(0) { $0 + $1.0 } / probes.count,
         probes.reduce(0) { $0 + $1.1 } / probes.count,
         probes.reduce(0) { $0 + $1.2 } / probes.count)
    }
    func far(_ c: (Int, Int, Int), _ d: (Int, Int, Int), _ t: Int) -> Bool {
        max(abs(c.0 - d.0), abs(c.1 - d.1), abs(c.2 - d.2)) > t
    }

    let corner = mean([at(2, 2), at(w - 3, 2), at(2, h - 3), at(w - 3, h - 3)])
    // The four edge midpoints: on a full-bleed render these sit on the tile's own rim,
    // which is the colour the corners should have been.
    let inset = max(2, w / 100)
    let rim = mean([at(w / 2, inset), at(w / 2, h - 1 - inset),
                    at(inset, h / 2), at(w - 1 - inset, h / 2)])

    guard far(corner, rim, 24) else { return (img, nil) }   // already a tile on a flat backdrop
    print("flattening backdrop: corners \(corner) -> rim \(rim)")

    // Flood from the border across everything close to the corner colour. Colour alone is
    // not enough — a dark pixel inside the mark itself must not be repainted.
    var isBackdrop = [Bool](repeating: false, count: w * h)
    var queue = [Int]()
    queue.reserveCapacity(w * h / 4)
    func consider(_ x: Int, _ y: Int) {
        let idx = y * w + x
        if isBackdrop[idx] { return }
        if far(at(x, y), corner, 40) { return }
        isBackdrop[idx] = true
        queue.append(idx)
    }
    for x in 0..<w { consider(x, 0); consider(x, h - 1) }
    for y in 0..<h { consider(0, y); consider(w - 1, y) }
    var head = 0
    while head < queue.count {
        let idx = queue[head]; head += 1
        let x = idx % w, y = idx / w
        if x > 0 { consider(x - 1, y) }
        if x < w - 1 { consider(x + 1, y) }
        if y > 0 { consider(x, y - 1) }
        if y < h - 1 { consider(x, y + 1) }
    }

    // Grow it over the blend ring where the tile's antialiased edge fades into the flat
    // colour. Left behind, that ring reads as a dark hairline around the whole tile.
    let grow = max(2, w / 300)
    for _ in 0..<grow {
        var added = [Int]()
        for idx in 0..<(w * h) where isBackdrop[idx] {
            let x = idx % w, y = idx / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < w && ny < h && !isBackdrop[ny * w + nx] {
                added.append(ny * w + nx)
            }
        }
        for idx in added { isBackdrop[idx] = true }
    }

    for idx in 0..<(w * h) where isBackdrop[idx] {
        let i = idx * 4
        px[i] = UInt8(rim.0); px[i + 1] = UInt8(rim.1); px[i + 2] = UInt8(rim.2); px[i + 3] = 255
    }

    // Built straight from the buffer: `rgba()` hands back row 0 = the image's top row,
    // which is exactly what this initialiser expects.
    guard let provider = CGDataProvider(data: Data(px) as CFData),
          let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)
    else { die("flatten failed") }

    // The tile is what the flood did not reach. Squared off around its own centre, since
    // every downstream mask is inscribed in a square.
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for idx in 0..<(w * h) where !isBackdrop[idx] {
        let x = idx % w, y = idx / w
        if x < x0 { x0 = x }; if x > x1 { x1 = x }
        if y < y0 { y0 = y }; if y > y1 { y1 = y }
    }
    guard x1 >= x0, y1 >= y0 else { die("the backdrop swallowed the whole image") }
    let side = CGFloat(max(x1 - x0, y1 - y0) + 1)
    let cx = CGFloat(x0 + x1 + 1) / 2, cy = CGFloat(y0 + y1 + 1) / 2
    let tile = CGRect(x: (cx - side / 2).rounded(), y: (cy - side / 2).rounded(),
                      width: side.rounded(), height: side.rounded())
    return (out, tile)
}

/// Average colour of the outermost ring, used for `ic_launcher_background` so the sliver
/// some launchers reveal during the adaptive-icon parallax matches the artwork's edge.
func edgeTint(_ img: CGImage) -> String {
    let (px, w, h) = rgba(img)
    var r = 0, g = 0, b = 0, n = 0
    for y in 0..<h {
        for x in 0..<w where x < 2 || y < 2 || x >= w - 2 || y >= h - 2 {
            let i = (y * w + x) * 4
            r += Int(px[i]); g += Int(px[i + 1]); b += Int(px[i + 2]); n += 1
        }
    }
    return String(format: "#%02X%02X%02X", r / n, g / n, b / n)
}

/// The continuous-curvature corner Apple uses for app icons. A plain rounded rectangle
/// reads visibly wrong beside system icons in the Dock; n = 5 is the standard fit.
func superellipse(in rect: CGRect, n: CGFloat = 5, steps: Int = 1440) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

enum MaskShape { case none, squircle, circle }

/// Rendered at 4x and downsampled: CoreGraphics antialiases paths well, but a 16px icon
/// masked directly still shows stair-stepping on the corners.
func render(_ src: CGImage, size: Int, mask: MaskShape, contentScale: CGFloat = 1) -> CGImage {
    let ss = size * 4
    func context(_ n: Int) -> CGContext {
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { die("cannot create render context") }
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        return ctx
    }

    let ctx = context(ss)
    let side = CGFloat(ss) * contentScale
    let art = CGRect(x: (CGFloat(ss) - side) / 2, y: (CGFloat(ss) - side) / 2,
                     width: side, height: side)
    ctx.saveGState()
    switch mask {
    case .none: break
    case .squircle: ctx.addPath(superellipse(in: art)); ctx.clip()
    case .circle: ctx.addPath(CGPath(ellipseIn: art, transform: nil)); ctx.clip()
    }
    ctx.draw(src, in: art)
    ctx.restoreGState()
    guard let big = ctx.makeImage() else { die("render failed at \(size)px") }

    let down = context(size)
    down.draw(big, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = down.makeImage() else { die("downsample failed at \(size)px") }
    return out
}

// MARK: - main

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
func p(_ rel: String) -> String { root + "/" + rel }

let square = flattenBackdrop(loadCGImage(p("assets/icon/tennanova-icon-square.png")))
let circle = flattenBackdrop(loadCGImage(p("assets/icon/tennanova-icon-circle.png")))
let squareSrc = square.image, circleSrc = circle.image

/// The tile the flood fill measured, shrunk by the same hair `artSquare` takes off, or
/// `artSquare`'s own contrast walk when the master is a tile on a backdrop.
func artRect(_ img: CGImage, _ measured: CGRect?, insetFraction: CGFloat) -> CGRect {
    guard let r = measured else { return artSquare(img, insetFraction: insetFraction) }
    let d = (r.width * insetFraction).rounded()
    return r.insetBy(dx: d, dy: d)
}

// A hair inside the tile edge, to clear its antialiased rim without eating gradient.
// Every downstream mask wants clean gradient to bite into, not an already-rounded corner.
let squareArt = squareSrc.cropping(to: artRect(squareSrc, square.tile, insetFraction: 0.025))!
// The circle keeps its rim; the circle mask below trims the backdrop fringe instead.
let circleArt = circleSrc.cropping(to: artRect(circleSrc, circle.tile, insetFraction: 0.005))!

print("square art: \(squareArt.width)x\(squareArt.height)   circle art: \(circleArt.width)x\(circleArt.height)")
print("edge tint (use for ic_launcher_background): \(edgeTint(squareArt))")

// Android: full-bleed foreground. The launcher's own mask does the rounding — an inset
// tile inside the system mask gives a visible double-rounded corner.
writePNG(render(squareArt, size: 512, mask: .none),
         to: p("android/app/src/main/res/drawable-nodpi/tennanova_icon.png"))

// Legacy densities. minSdk is 33 so nothing reads these, but Play Console and some
// third-party launchers still look them up directly.
for (dir, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    writePNG(render(squareArt, size: size, mask: .squircle),
             to: p("android/app/src/main/res/mipmap-\(dir)/ic_launcher.png"))
    writePNG(render(squareArt, size: size, mask: .circle),
             to: p("android/app/src/main/res/mipmap-\(dir)/ic_launcher_round.png"))
}

// macOS. 824/1024 is Apple's grid for a squircle app icon; the margin is transparent.
let iconset = p("mac/Resources/AppIcon.iconset")
try? FileManager.default.removeItem(atPath: iconset)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                     ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(render(squareArt, size: size, mask: .squircle, contentScale: 824.0 / 1024.0),
             to: iconset + "/\(name).png")
}

// Web. These were JPEG data carrying a .png extension and declared image/png, which is
// why the "circle" favicon has never actually been circular.
writePNG(render(squareArt, size: 512, mask: .squircle), to: p("web/media/icon-square.png"))
writePNG(render(circleArt, size: 512, mask: .circle), to: p("web/media/icon-circle.png"))

// Play Console applies its own mask, so this one ships square.
writePNG(render(squareArt, size: 512, mask: .none),
         to: p("assets/icon/generated/ic_launcher-playstore.png"))

print("done")
