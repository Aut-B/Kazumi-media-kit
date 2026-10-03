import CoreGraphics
import CoreText
import Foundation
import UIKit

/// 画中画「画面内」诊断叠加层（仅排障用）。
///
/// 系统小窗只显示 `AVSampleBufferDisplayLayer` 里的内容，Flutter 画的东西一概进不去；
/// 反过来说，**把读数直接画进送入图层的帧里，小窗就必然会显示它**。因此这一层能一次
/// 把「小窗黑屏」切成两类，无需用户去翻日志或复制对话框：
///
/// * 小窗里看得到数字与移动色块 → 画面帧确实送到了图层，黑屏发生在「系统把图层内容
///   接进小窗」这一环；
/// * 小窗一片纯黑、连字都没有 → 帧压根没送进去，问题在出帧 / 取帧 / 入队这条链上。
///
/// 色块每帧横向移动一小段：静止的画面（帧送出去了但不再更新）与完全不显示，也能一眼
/// 区分开。
///
/// 仅在诊断时开启；开启后每帧多一次整帧拷贝与一次文字绘制，正常播放时不开。
public final class PictureInPictureDebugOverlay {
  /// 是否启用。由 Dart 侧（多任务模式）打开。
  public var enabled = false

  // 帧缓冲池：与弹幕层各自持有，避免两处绘制互相踩到同一块缓冲。
  private var buffers: [CVPixelBuffer] = []
  private var width = 0
  private var height = 0
  private var cursor = 0

  /// 已绘制的帧数，用于让色块逐帧移动。
  private var tick = 0

  public init() {}

  /// 把 [lines] 绘进 [source] 的副本并返回；未启用或失败时返回 `nil`。
  public func composite(_ source: CVPixelBuffer, lines: [String]) -> CVPixelBuffer? {
    guard enabled, !lines.isEmpty else {
      return nil
    }
    let frameWidth = CVPixelBufferGetWidth(source)
    let frameHeight = CVPixelBufferGetHeight(source)
    guard frameWidth > 0, frameHeight > 0 else {
      return nil
    }
    guard let dest = obtainBuffer(width: frameWidth, height: frameHeight) else {
      return nil
    }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(dest, [])
    defer {
      CVPixelBufferUnlockBaseAddress(dest, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }

    guard
      let sourceBase = CVPixelBufferGetBaseAddress(source),
      let destBase = CVPixelBufferGetBaseAddress(dest)
    else {
      return nil
    }

    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let destStride = CVPixelBufferGetBytesPerRow(dest)
    let rowBytes = min(sourceStride, destStride)
    for row in 0..<frameHeight {
      let destRow = destBase.advanced(by: row * destStride)
      memcpy(
        destRow,
        sourceBase.advanced(by: row * sourceStride),
        rowBytes
      )
      // 目标缓冲的对齐填充区不补齐的话，画面右缘会出现一条花边。
      if destStride > rowBytes {
        memset(destRow.advanced(by: rowBytes), 0, destStride - rowBytes)
      }
    }

    draw(
      into: destBase,
      width: frameWidth,
      height: frameHeight,
      bytesPerRow: destStride,
      lines: lines
    )
    return dest
  }

  // MARK: - 绘制

  /// 在 [base] 指向的 BGRA 位图上绘制读数条与移动色块。
  ///
  /// 与弹幕层同样的注意点：`CGContext` 必须在返回前走完生命周期，否则调用方一解锁
  /// 帧缓冲，上下文手里的位图指针就悬空了。
  private func draw(
    into base: UnsafeMutableRawPointer,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    lines: [String]
  ) {
    guard
      let context = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else {
      return
    }
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(false)
    context.setAllowsFontSubpixelPositioning(false)
    context.setAllowsFontSubpixelQuantization(false)

    tick += 1
    let frameWidth = CGFloat(width)
    let frameHeight = CGFloat(height)

    // 小窗本身不大，字号取偏大的值（按帧高的比例），否则缩到小窗里看不清。
    let fontSize = max(14, min(frameHeight * 0.105, 34))
    let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let lineHeight = fontSize * 1.28
    let padding = fontSize * 0.34
    let boxHeight = lineHeight * CGFloat(lines.count) + padding * 2

    // 顶部黑色半透明底条：任何画面亮度下文字都可读。
    context.setFillColor(UIColor(white: 0, alpha: 0.75).cgColor)
    context.fill(
      CGRect(x: 0, y: frameHeight - boxHeight, width: frameWidth, height: boxHeight)
    )

    for (index, line) in lines.enumerated() {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.white.cgColor,
      ]
      let ctLine = CTLineCreateWithAttributedString(
        NSAttributedString(string: line, attributes: attributes)
          as CFAttributedString
      )
      // 从上往下的第 index 行，换算成 CoreGraphics 的左下角原点坐标。
      let topFromTop = CGFloat(index) * lineHeight + padding
      context.textPosition = CGPoint(
        x: padding,
        y: frameHeight - topFromTop - font.ascender
      )
      CTLineDraw(ctLine, context)
    }

    // 底部一条逐帧右移的色块：画面是否还在刷新，一眼可辨。
    let barWidth = frameWidth * 0.16
    let phase = CGFloat(tick % 40) / 40
    context.setFillColor(UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor)
    context.fill(
      CGRect(
        x: phase * (frameWidth - barWidth),
        y: 0,
        width: barWidth,
        height: max(5, frameHeight * 0.045)
      )
    )
  }

  // MARK: - 帧缓冲复用

  private func obtainBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if self.width != width || self.height != height {
      buffers.removeAll()
      cursor = 0
      self.width = width
      self.height = height
    }

    if buffers.count < 3 {
      var pixelBuffer: CVPixelBuffer?
      let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
      )
      guard status == kCVReturnSuccess, let created = pixelBuffer else {
        return nil
      }
      buffers.append(created)
    }

    let buffer = buffers[cursor % buffers.count]
    cursor += 1
    return buffer
  }
}
