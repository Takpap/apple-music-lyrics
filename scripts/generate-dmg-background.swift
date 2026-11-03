#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: generate-dmg-background.swift <version> <output.png>\n".utf8)
    )
    exit(1)
}

let version = CommandLine.arguments[1]
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let canvasSize = NSSize(width: 720, height: 500)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Unable to create DMG bitmap\n".utf8))
    exit(1)
}
bitmap.size = canvasSize
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Unable to create DMG graphics context\n".utf8))
    exit(1)
}

func drawCentered(
    _ text: String,
    y: CGFloat,
    font: NSFont,
    color: NSColor,
    width: CGFloat = 640
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    let rect = NSRect(x: (canvasSize.width - width) / 2, y: y, width: width, height: 30)
    text.draw(in: rect, withAttributes: attributes)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

drawCentered(
    "安装 Apple Music Lyrics",
    y: 440,
    font: .systemFont(ofSize: 24, weight: .semibold),
    color: .labelColor
)
drawCentered(
    "v\(version)  ·  将左侧应用拖到右侧 Applications",
    y: 407,
    font: .systemFont(ofSize: 13, weight: .regular),
    color: .secondaryLabelColor
)

let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 300, y: 278))
arrow.line(to: NSPoint(x: 420, y: 278))
arrow.move(to: NSPoint(x: 408, y: 289))
arrow.line(to: NSPoint(x: 420, y: 278))
arrow.line(to: NSPoint(x: 408, y: 267))
NSColor.tertiaryLabelColor.setStroke()
arrow.stroke()

NSColor.separatorColor.withAlphaComponent(0.7).setFill()
NSBezierPath(rect: NSRect(x: 54, y: 149, width: 612, height: 1)).fill()

drawCentered(
    "首次打开被阻止：系统设置 › 隐私与安全性 › 仍要打开",
    y: 111,
    font: .systemFont(ofSize: 12, weight: .medium),
    color: .labelColor,
    width: 612
)
drawCentered(
    "歌词无法读取：系统设置 › 隐私与安全性 › 自动化 › Apple Music Lyrics › Music",
    y: 84,
    font: .systemFont(ofSize: 11, weight: .regular),
    color: .secondaryLabelColor,
    width: 650
)
drawCentered(
    "详细步骤请打开下方的“安装与权限说明”",
    y: 55,
    font: .systemFont(ofSize: 11, weight: .regular),
    color: .tertiaryLabelColor
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to render DMG background\n".utf8))
    exit(1)
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Unable to write DMG background: \(error)\n".utf8))
    exit(1)
}
