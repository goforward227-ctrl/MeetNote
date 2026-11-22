// アプリのアイコンを描いて、AppIcon.appiconset に必要な大きさの PNG を書き出す。
// 使い方： swift scripts/make-icon.swift
import AppKit
import SwiftUI

let outputDir = URL(fileURLWithPath: "MeetNote/Assets.xcassets/AppIcon.appiconset")

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // 1024 の座標で描けるようにする（macOS のアイコンは 824 の角丸四角を中央に置く）。
    cg.scaleBy(x: s / 1024, y: s / 1024)

    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = Path(roundedRect: plate, cornerRadius: 185, style: .continuous).cgPath

    // 影
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    cg.addPath(shape)
    cg.setFillColor(CGColor(gray: 1, alpha: 1))
    cg.fillPath()
    cg.restoreGState()

    // 地（白から薄いグレーへ）
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 1.0, alpha: 1), CGColor(gray: 0.91, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(background, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    cg.restoreGState()

    // 録音の赤い丸（細い輪つき）
    let center = CGPoint(x: 512, y: 610)
    let red = CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    cg.setStrokeColor(red)
    cg.setLineWidth(18)
    cg.strokeEllipse(in: CGRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300))
    cg.setFillColor(red)
    cg.fillEllipse(in: CGRect(x: center.x - 108, y: center.y - 108, width: 216, height: 216))

    // 議事録の行
    cg.setFillColor(CGColor(gray: 0.72, alpha: 1))
    for (index, width) in [440.0, 440.0, 280.0].enumerated() {
        let y = 340.0 - Double(index) * 62
        let line = CGRect(x: 292, y: y, width: width, height: 26)
        cg.addPath(CGPath(roundedRect: line, cornerWidth: 13, cornerHeight: 13, transform: nil))
        cg.fillPath()
    }

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try draw(size: points * scale).write(to: outputDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputDir.appendingPathComponent("Contents.json"))
print("書き出しました: \(outputDir.path)")
