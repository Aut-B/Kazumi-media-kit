import CoreGraphics
import CoreText
import Foundation
import UIKit

/// 画中画弹幕叠加层。
///
/// 系统画中画窗口只显示 `AVSampleBufferDisplayLayer` 里的内容，Flutter 侧绘制的
/// 弹幕画布（`canvas_danmaku`）不会被带进小窗。这里在原生侧按弹幕数据自行排版，
/// 把文字绘进每一帧 `CVPixelBuffer` 的副本，再送给画中画图层，从而使系统小窗内
/// 也能看到弹幕。
///
/// 开销控制：只有在「当前播放时刻确实有弹幕要显示」时才做一次整帧拷贝与绘制；
/// 没有弹幕落在屏幕上时，直接使用原始帧，零额外开销。
///
/// 弹幕来自 Dart 侧（`VideoOutput.AddPictureInPictureDanmaku`），每条带有相对视频
/// 起点的绝对时间，因此拖动进度条后位置依然正确。
public final class DanmakuOverlay {
  /// 单条弹幕。
  private struct Item {
    /// 唯一标识（B 站弹幕 id），用于去重。
    let id: String
    /// 出现在视频中的时间（秒）。
    let start: Double
    /// 1 / 6 滚动，4 底部，5 顶部。
    let mode: Int
    /// 0xRRGGBB。
    let color: UInt32
    let text: String

    /// 已分配的轨道序号；-1 表示尚未分配。
    var lane: Int = -1
    /// 文本宽度（像素）。
    var width: CGFloat = 0
    /// 该条弹幕在屏幕上停留的时长（秒）。
    var life: Double = 0
  }

  // MARK: - 配置（由 Dart 侧下发）

  public var enabled = false
  public var opacity: CGFloat = 1
  public var fontScale: CGFloat = 1
  public var lineHeightScale: CGFloat = 1
  /// 弹幕可占用的画面高度比例（0～1）。
  public var area: CGFloat = 1
  /// 滚动弹幕横穿整屏宽度所需秒数。
  public var duration: Double = 8
  /// 顶部 / 底部弹幕的停留秒数。
  public var staticDuration: Double = 4
  public var strokeWidth: CGFloat = 1.5
  public var hideScroll = false
  public var hideTop = false
  public var hideBottom = false

  // MARK: - 数据

  private var items: [Item] = []
  private var seen = Set<String>()

  /// 滚动弹幕：各轨道「可再次放入新弹幕」的时间。
  private var scrollLaneFree: [Double] = []
  /// 顶部 / 底部弹幕：各轨道「可再次放入新弹幕」的时间。
  private var topLaneFree: [Double] = []
  private var bottomLaneFree: [Double] = []

  // MARK: - 帧缓冲

  private var buffers: [CVPixelBuffer] = []
  private var bufferWidth = 0
  private var bufferHeight = 0
  private var bufferCursor = 0

  public init() {}

  // MARK: - 数据写入

  /// 追加弹幕。同一 `id` 只会入库一次，因此反复拖动进度条不会产生重复。
  public func append(_ rawItems: [[String: Any]]) {
    for raw in rawItems {
      guard let id = raw["id"] as? String else {
        continue
      }
      if seen.contains(id) {
        continue
      }
      let text = (raw["text"] as? String) ?? ""
      if text.isEmpty {
        continue
      }
      guard let start = (raw["time"] as? NSNumber)?.doubleValue else {
        continue
      }
      let mode = (raw["mode"] as? NSNumber)?.intValue ?? 1
      let color = UInt32(
        truncatingIfNeeded: (raw["color"] as? NSNumber)?.intValue ?? 0xFFFFFF
      )
      seen.insert(id)
      items.append(
        Item(
          id: id,
          start: start,
          mode: mode,
          color: color & 0xFFFFFF,
          text: text
        )
      )
    }
    if items.count > 6000 {
      items.removeFirst(items.count - 4000)
      seen = Set(items.map { $0.id })
    }
  }

  public func clear() {
    items.removeAll()
    seen.removeAll()
    scrollLaneFree.removeAll()
    topLaneFree.removeAll()
    bottomLaneFree.removeAll()
  }

  // MARK: - 渲染

  /// 当前时刻是否有弹幕需要绘制。
  public func isActive(at position: Double) -> Bool {
    guard enabled else {
      return false
    }
    for item in items {
      if item.start > position {
        continue
      }
      let life = item.life > 0 ? item.life : max(duration * 2, staticDuration)
      if position <= item.start + life {
        return true
      }
    }
    return false
  }

  /// 把弹幕绘进 [source] 的副本并返回；失败时返回 `nil`（调用方退回原始帧）。
  public func composite(_ source: CVPixelBuffer, at position: Double) -> CVPixelBuffer? {
    guard enabled else {
      return nil
    }
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    guard width > 0, height > 0 else {
      return nil
    }
    guard let dest = obtainBuffer(width: width, height: height) else {
      return nil
    }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(dest, [])
    guard
      let sourceBase = CVPixelBufferGetBaseAddress(source),
      let destBase = CVPixelBufferGetBaseAddress(dest)
    else {
      CVPixelBufferUnlockBaseAddress(dest, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
      return nil
    }

    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let destStride = CVPixelBufferGetBytesPerRow(dest)
    let rowBytes = min(sourceStride, destStride)
    for row in 0..<height {
      let destRow = destBase.advanced(by: row * destStride)
      memcpy(
        destRow,
        sourceBase.advanced(by: row * sourceStride),
        rowBytes
      )
      // 目标缓冲的对齐填充区若不补齐，画面右缘会出现一条花边。
      if destStride > rowBytes {
        memset(destRow.advanced(by: rowBytes), 0, destStride - rowBytes)
      }
    }

    draw(
      into: destBase,
      width: width,
      height: height,
      bytesPerRow: destStride,
      position: position
    )

    CVPixelBufferUnlockBaseAddress(dest, [])
    CVPixelBufferUnlockBaseAddress(source, .readOnly)
    return dest
  }

  // MARK: - 绘制实现

  /// 在 [base] 指向的 BGRA 位图上绘制弹幕。
  ///
  /// 独立成函数、并在返回时让 `CGContext` 走完生命周期，避免上下文仍持有位图指针
  /// 时调用方就解锁了帧缓冲。
  private func draw(
    into base: UnsafeMutableRawPointer,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    position: Double
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
    // 画面帧是不透明的，关闭字体平滑（次像素抗锯齿）以免出现彩色边缘。
    context.setShouldSmoothFonts(false)
    context.setAllowsFontSubpixelPositioning(false)
    context.setAllowsFontSubpixelQuantization(false)
    context.setAlpha(opacity)

    let frameWidth = CGFloat(width)
    let frameHeight = CGFloat(height)

    let fontSize = max(12, min(frameHeight * 0.042, frameHeight * 0.12)) * fontScale
    let laneHeight = fontSize * 1.35 * max(lineHeightScale, 0.6)
    let usableHeight = frameHeight * max(min(area, 1), 0.1)
    let scrollLaneCount = max(1, Int(usableHeight / laneHeight))
    let staticLaneCount = max(1, Int(usableHeight / laneHeight / 2))

    if scrollLaneFree.count != scrollLaneCount {
      scrollLaneFree = Array(repeating: -Double.greatestFiniteMagnitude, count: scrollLaneCount)
    }
    if topLaneFree.count != staticLaneCount {
      topLaneFree = Array(repeating: -Double.greatestFiniteMagnitude, count: staticLaneCount)
    }
    if bottomLaneFree.count != staticLaneCount {
      bottomLaneFree = Array(repeating: -Double.greatestFiniteMagnitude, count: staticLaneCount)
    }

    // 固定速度：整屏宽度在 duration 秒内走完。速度一致时，同轨道前后两条弹幕的
    // 间距恒定，因此只要「后一条出现时前一条已完全进入画面」就不会追尾。
    let velocity = frameWidth / CGFloat(max(duration, 1))
    let staticLife = max(staticDuration, 1)

    let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    let strokePercent = -max(2.0, min(20.0, 100 * strokeWidth / fontSize))

    for index in items.indices {
      var item = items[index]

      let isTop = item.mode == 5
      let isBottom = item.mode == 4
      if isTop && hideTop {
        continue
      }
      if isBottom && hideBottom {
        continue
      }
      if !isTop && !isBottom && hideScroll {
        continue
      }

      if item.start > position {
        continue
      }
      // 已量过宽、且已经飞出画面的：直接跳过（回拖进度条后仍会重新出现）。
      if item.life > 0, position > item.start + item.life {
        continue
      }

      let line = makeLine(item, font: font, strokePercent: strokePercent)

      if item.lane == -1 {
        // 首次进入可见期时量宽、分轨道。
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        item.width = textWidth
        item.life = isTop || isBottom
          ? staticLife
          : Double((frameWidth + textWidth) / velocity)

        if isTop {
          item.lane = firstFreeLane(topLaneFree, at: item.start)
          topLaneFree[item.lane] = item.start + staticLife
        } else if isBottom {
          item.lane = firstFreeLane(bottomLaneFree, at: item.start)
          bottomLaneFree[item.lane] = item.start + staticLife
        } else {
          item.lane = firstFreeLane(scrollLaneFree, at: item.start)
          // 后一条弹幕最早可在「前一条完全进入画面」之后出现。
          scrollLaneFree[item.lane] = item.start + Double(textWidth / velocity)
        }
        items[index] = item
      }

      if position > item.start + item.life {
        continue
      }

      let elapsed = CGFloat(position - item.start)
      let x: CGFloat
      let top: CGFloat
      if isTop {
        x = (frameWidth - item.width) / 2
        top = CGFloat(item.lane) * laneHeight
      } else if isBottom {
        x = (frameWidth - item.width) / 2
        top = usableHeight - CGFloat(item.lane + 1) * laneHeight
      } else if item.mode == 6 {
        // 逆向弹幕：从左往右。
        x = -item.width + elapsed * velocity
        top = CGFloat(item.lane) * laneHeight
      } else {
        x = frameWidth - elapsed * velocity
        top = CGFloat(item.lane) * laneHeight
      }

      // CoreGraphics 的原点在左下角，把「从上往下」的坐标换算回去。
      let baseline = frameHeight - (top + font.ascender)
      context.textPosition = CGPoint(x: x, y: baseline)
      CTLineDraw(line, context)
    }
  }

  private func makeLine(
    _ item: Item,
    font: UIFont,
    strokePercent: CGFloat
  ) -> CTLine {
    let red = CGFloat((item.color >> 16) & 0xFF) / 255
    let green = CGFloat((item.color >> 8) & 0xFF) / 255
    let blue = CGFloat(item.color & 0xFF) / 255
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor(red: red, green: green, blue: blue, alpha: 1).cgColor,
      // 负值表示「描边 + 填充」，这是弹幕白字黑边的经典画法。
      .strokeColor: UIColor.black.cgColor,
      .strokeWidth: strokePercent,
    ]
    return CTLineCreateWithAttributedString(
      NSAttributedString(string: item.text, attributes: attributes)
        as CFAttributedString
    )
  }

  /// 找到第一条空闲轨道；全都占用时退化为「最早空出来」的那条。
  private func firstFreeLane(_ lanes: [Double], at time: Double) -> Int {
    var earliest = 0
    for index in lanes.indices {
      if lanes[index] <= time {
        return index
      }
      if lanes[index] < lanes[earliest] {
        earliest = index
      }
    }
    return earliest
  }

  // MARK: - 帧缓冲复用

  private func obtainBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if bufferWidth != width || bufferHeight != height {
      buffers.removeAll()
      bufferCursor = 0
      bufferWidth = width
      bufferHeight = height
    }

    if buffers.count < 4 {
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

    let buffer = buffers[bufferCursor % buffers.count]
    bufferCursor += 1
    return buffer
  }
}
