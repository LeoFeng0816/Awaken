// 靜醒（Awaken）App 圖示：完全以 CoreGraphics 向量路徑繪製的原創咖啡杯，不使用 SF Symbols、字型或外部圖片。
// 依 MIT License 與本專案一同授權。
//
// 用法：
//   swift Scripts/make-icon.swift <輸出.iconset 目錄>          產生 macOS iconset（16–1024 px）
//   swift Scripts/make-icon.swift --png <輸出.png> [邊長 px]    產生單張 PNG（預設 512，例如 Assets/Awaken.png）
//
// 設計座標系：1024 × 1024，原點在左下角，y 向上。所有尺寸都依此比例縮放。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 色彩

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
    CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
}

// MARK: - 各部位路徑（1024 設計座標）

/// 背景：macOS 圖示格線的圓角方形（四周留 100 的透明邊）。
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                  cornerWidth: 186, cornerHeight: 186, transform: nil)

/// 杯身：上緣寬、下緣收窄的碗形。
let cupBody: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 296, y: 610))
    p.addCurve(to: CGPoint(x: 420, y: 352), control1: CGPoint(x: 296, y: 470), control2: CGPoint(x: 340, y: 366))
    p.addLine(to: CGPoint(x: 604, y: 352))
    p.addCurve(to: CGPoint(x: 728, y: 610), control1: CGPoint(x: 684, y: 366), control2: CGPoint(x: 728, y: 470))
    p.closeSubpath()
    return p
}()

/// 杯耳：右側的粗環，只露出杯身外的部分。
let handle: CGPath = {
    let p = CGMutablePath()
    p.addEllipse(in: ellipse(724, 500, 84, 80))
    return p.copy(strokingWithWidth: 42, lineCap: .round, lineJoin: .round, miterLimit: 10)
}()

/// 兩道蒸氣：S 形曲線，圓頭筆畫。
let steam: CGPath = {
    let p = CGMutablePath()
    for x in [452.0, 572.0] as [CGFloat] {
        p.move(to: CGPoint(x: x, y: 690))
        p.addCurve(to: CGPoint(x: x, y: 800), control1: CGPoint(x: x - 46, y: 726), control2: CGPoint(x: x + 46, y: 764))
        p.addCurve(to: CGPoint(x: x, y: 846), control1: CGPoint(x: x - 22, y: 816), control2: CGPoint(x: x - 14, y: 834))
    }
    return p.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10)
}()

// MARK: - 繪製

func draw(_ ctx: CGContext) {
    // 背景：深夜靛藍到清晨藍的漸層，下緣帶一點暖色晨光（「靜」與「醒」）。
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    linear(ctx, [rgb(0x3F78C2), rgb(0x1B2552)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFC46B, 0.42), rgb(0xFFC46B, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 210), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 210), endRadius: 400, options: [])
    // 上緣細微高光，讓方塊有一點立體感。
    linear(ctx, [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 700))
    ctx.restoreGState()

    // 蒸氣
    ctx.addPath(steam)
    ctx.setFillColor(rgb(0xFFFFFF, 0.88))
    ctx.fillPath()

    // 杯碟陰影與杯碟
    ctx.setFillColor(rgb(0x0B1230, 0.30))
    ctx.fillEllipse(in: ellipse(512, 318, 262, 54))
    ctx.saveGState()
    ctx.addEllipse(in: ellipse(512, 336, 256, 56))
    ctx.clip()
    linear(ctx, [rgb(0xFFF7EC), rgb(0xE3CFB4)], from: CGPoint(x: 512, y: 392), to: CGPoint(x: 512, y: 280))
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xCDB596, 0.55))
    ctx.fillEllipse(in: ellipse(512, 350, 150, 24))

    // 杯耳
    ctx.saveGState()
    ctx.addPath(handle)
    ctx.clip()
    linear(ctx, [rgb(0xFFF7EC), rgb(0xE6D3BA)], from: CGPoint(x: 724, y: 600), to: CGPoint(x: 724, y: 400))
    ctx.restoreGState()

    // 杯身
    ctx.saveGState()
    ctx.addPath(cupBody)
    ctx.clip()
    linear(ctx, [rgb(0xFFFBF4), rgb(0xE9D7BF)], from: CGPoint(x: 360, y: 610), to: CGPoint(x: 700, y: 352))
    // 左側柔和反光
    ctx.setFillColor(rgb(0xFFFFFF, 0.45))
    ctx.fillEllipse(in: ellipse(352, 520, 22, 70))
    ctx.restoreGState()

    // 杯口與咖啡液面
    ctx.setFillColor(rgb(0xFFFBF4))
    ctx.fillEllipse(in: ellipse(512, 610, 216, 48))
    ctx.saveGState()
    ctx.addEllipse(in: ellipse(512, 612, 188, 34))
    ctx.clip()
    linear(ctx, [rgb(0x4A2A17), rgb(0x8A5732)], from: CGPoint(x: 512, y: 646), to: CGPoint(x: 512, y: 578))
    ctx.setFillColor(rgb(0xD9A06A, 0.55))
    ctx.fillEllipse(in: ellipse(560, 602, 70, 10))
    ctx.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

// MARK: - 進入點

let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.first == "--png" {
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: make-icon.swift --png <out.png> [size]\n".utf8))
            exit(2)
        }
        let size = args.count >= 3 ? Int(args[2]) ?? 512 : 512
        try writePNG(render(size), to: URL(fileURLWithPath: args[1]))
        print(args[1])
    } else {
        let out = URL(fileURLWithPath: args.first ?? "AppIcon.iconset")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try writePNG(render(base), to: out.appendingPathComponent("icon_\(base)x\(base).png"))
            try writePNG(render(base * 2), to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        print(out.path)
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
