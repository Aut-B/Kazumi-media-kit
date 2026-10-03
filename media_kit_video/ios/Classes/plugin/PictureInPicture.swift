import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// 系统级画中画（Picture-in-Picture）。
///
/// media_kit 在 iOS 上把 libmpv 的画面通过 OpenGL ES 渲染进一块
/// `CVPixelBuffer`（见 `TextureHW`），再交给 Flutter 的 `Texture` 组件显示，
/// 整条链路不经过 `AVPlayer`，因此无法直接使用
/// `AVPictureInPictureController(playerLayer:)`。
///
/// 这里采用 iOS 15 引入的 `AVSampleBufferDisplayLayer` 作为画中画画面源：
/// 把每一帧渲染完成的 `CVPixelBuffer` 封装成 `CMSampleBuffer` 入队到
/// `AVSampleBufferDisplayLayer`，再以其为 `contentSource` 创建
/// `AVPictureInPictureController`，从而得到真正的系统画中画窗口
/// （可悬浮在其它 App 之上，切后台 / 锁屏继续播放）。
///
/// 播放控制（播放 / 暂停 / 快进）直接读写 libmpv 的 `pause`、`time-pos`
/// 属性。media_kit 的 Dart 层 observe 了这些属性
/// （见 `media_kit/lib/src/media_kit_player.dart` 中的 `pause` / `time-pos`），
/// 因此状态会自动同步回上层 UI，无需额外的 Dart 往返。
///
/// 两种进入方式：
/// * **手动**：调用 [start]，立即弹出画中画窗口（对应播放器上的「画中画」按钮）；
/// * **自动**：调用 [arm] 只做「武装」——把图层挂进视图层级、建好 controller 并
///   打开 `canStartPictureInPictureAutomaticallyFromInline`，**不**立即弹出窗口，
///   由系统在用户划回主屏幕（App 进入后台）时自动进入画中画。
public class PictureInPicture: NSObject {
  /// 事件回调：`(方法名, 参数)`，由 [VideoOutput] 转发给 Dart 侧。
  public typealias EventCallback = (String, [String: Any]) -> Void

  private let handle: OpaquePointer
  private let eventCallback: EventCallback

  /// 承载画面的图层（iOS 8+ 可用）。
  private let displayLayer = AVSampleBufferDisplayLayer()

  /// 承载 [displayLayer] 的宿主视图。
  ///
  /// 系统在判定画中画是否可用时，要求画面源位于视图层级中**且可见**；若把图层直接
  /// 塞在 Flutter 视图之下（完全被遮挡），系统可能认为「画面不可见」而拒绝启动
  /// 画中画。因此这里用一个 2×2 点的宿主视图挂在 Flutter 视图**之上**：
  /// 尺寸极小（约几个像素）因而观感上无影响，同时满足可见性判定。
  ///
  /// 位置取「屏幕左边缘垂直居中」——避开了圆角与刘海区域，任何机型、任何方向下
  /// 都确实处于可见区域内。
  private lazy var hostView: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    return view
  }()

  /// 画中画控制器（iOS 15+ 才会创建）。
  private var pipController: AVPictureInPictureController?

  /// 是否处于「已武装」状态：为 true 时持续把新帧喂给 [displayLayer]。
  /// 由 [start] / [arm] 置位，[stop] / [dispose] 复位。
  public private(set) var isArmed: Bool = false

  init(handle: OpaquePointer, eventCallback: @escaping EventCallback) {
    self.handle = handle
    self.eventCallback = eventCallback
    super.init()
  }

  /// 设备 / 系统是否支持画中画。
  public static var isSupported: Bool {
    if #available(iOS 15.0, *) {
      return AVPictureInPictureController.isPictureInPictureSupported()
    }
    return false
  }

  /// 是否已进入系统画中画（窗口已弹出）。
  public var isActive: Bool {
    return pipController?.isPictureInPictureActive ?? false
  }

  /// 当前是否具备进入画中画的条件（图层已就绪等）。
  public var isPossible: Bool {
    return pipController?.isPictureInPicturePossible ?? false
  }

  // MARK: - 生命周期

  /// 立即进入系统画中画（用户点按播放器上的「画中画」按钮）。
  public func start() {
    guard #available(iOS 15.0, *) else {
      NSLog("PictureInPicture: requires iOS 15.0 or above")
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("PictureInPicture: not supported on this device")
      emitError("当前设备不支持画中画")
      return
    }

    isArmed = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard let controller = self._ensureController() else {
        return
      }
      if controller.isPictureInPictureActive {
        return
      }
      if !controller.isPictureInPicturePossible {
        // 常见原因：图层尚未 attach、或尚未收到第一帧。
        NSLog("PictureInPicture: isPictureInPicturePossible == false")
      }
      controller.startPictureInPicture()
    }
  }

  /// 「武装」自动画中画：不立即弹出窗口，而是在用户划回主屏幕（App 进入后台）时
  /// 由系统自动进入画中画。
  ///
  /// - Parameter autoEnter: 是否允许系统在 App 进入后台时自动进入画中画。
  ///   传 `false` 表示只保持图层与 controller 就绪，不作自动进入。
  public func arm(autoEnter: Bool) {
    guard #available(iOS 15.0, *) else {
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      return
    }
    isArmed = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard let controller = self._ensureController() else {
        return
      }
      controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
    }
  }

  public func stop() {
    guard #available(iOS 15.0, *) else {
      return
    }
    isArmed = false
    DispatchQueue.main.async { [weak self] in
      self?.pipController?.stopPictureInPicture()
    }
  }

  /// 释放资源。
  ///
  /// 可能在任意线程（`VideoOutput.deinit`）被调用，而 AVKit / UIKit 的对象只能
  /// 在主线程序列上访问，因此统一转投主线程执行。
  public func dispose() {
    isArmed = false

    let layer = displayLayer
    let host = hostView
    guard #available(iOS 15.0, *) else {
      DispatchQueue.main.async {
        layer.removeFromSuperlayer()
        host.removeFromSuperview()
      }
      return
    }

    let controller = pipController
    pipController = nil
    DispatchQueue.main.async {
      if controller?.isPictureInPictureActive ?? false {
        controller?.stopPictureInPicture()
      }
      controller?.delegate = nil
      layer.removeFromSuperlayer()
      host.removeFromSuperview()
    }
  }

  /// 建立（或复用）画中画控制器。必须在主线程调用。
  @available(iOS 15.0, *)
  private func _ensureController() -> AVPictureInPictureController? {
    // 画中画需要「播放」类音频会话；这里补齐，避免被系统中断。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      NSLog("PictureInPicture: AVAudioSession error: \(error)")
    }

    attachDisplayLayer()

    if let controller = pipController {
      return controller
    }

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    // 默认允许「划回主屏幕时自动进入画中画」，具体开关由 Dart 侧按用户设置调整。
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    pipController = controller
    return controller
  }

  // MARK: - 帧喂入

  /// 把一帧已渲染的 [CVPixelBuffer] 入队到画中画图层。
  public func enqueue(_ pixelBuffer: CVPixelBuffer) {
    guard #available(iOS 15.0, *) else {
      return
    }
    guard isArmed else {
      return
    }

    // 图层尚未消化完上一帧时直接丢弃，避免堆积与卡顿。
    let layer = displayLayer
    if !layer.isReadyForMoreMediaData {
      return
    }

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription = formatDescription else {
      return
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: .invalid,
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
      return
    }

    // 立即显示，不做额外的时间轴调度。
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately)
          .toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }

    DispatchQueue.main.async {
      if layer.status == .failed {
        layer.flush()
      }
      layer.enqueue(sampleBuffer)
    }
  }

  // MARK: - 内部

  /// 把图层挂进视图层级：置于极小宿主视图内、叠在 Flutter 视图之上。
  ///
  /// 之所以不直接挂在 window 图层最底层：那样会被 Flutter 视图完全遮挡，部分系统
  /// 版本会因此判定画面「不可见」，导致 `isPictureInPicturePossible` 恒为 false，
  /// 画中画按钮点了没有反应。
  private func attachDisplayLayer() {
    guard let window = PictureInPicture.keyWindow else {
      NSLog("PictureInPicture: key window not found")
      return
    }

    // 只在极小的可见区域内显示（约几个像素），因此不会影响应用内观感。
    let side: CGFloat = 2
    if hostView.superview !== window {
      hostView.removeFromSuperview()
      window.addSubview(hostView)
      window.bringSubviewToFront(hostView)
    }
    hostView.frame = CGRect(
      x: 0,
      y: window.bounds.midY,
      width: side,
      height: side
    )
    displayLayer.frame = hostView.bounds
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.clear.cgColor
    displayLayer.isHidden = false
    if displayLayer.superlayer !== hostView.layer {
      displayLayer.removeFromSuperlayer()
      hostView.layer.addSublayer(displayLayer)
    }
  }

  private func emitError(_ message: String) {
    NSLog("PictureInPicture: \(message)")
    eventCallback(
      "VideoOutput.PictureInPictureError",
      ["message": message]
    )
  }

  private static var keyWindow: UIWindow? {
    if #available(iOS 13.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else {
          continue
        }
        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
          return keyWindow
        }
      }
    }
    // 兼容旧系统 / 兜底。
    return UIApplication.shared.keyWindow ?? UIApplication.shared.windows.first
  }

  // MARK: - libmpv 读写

  private func mpvFlag(_ name: String) -> Bool {
    var value: Int32 = 0
    if mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) < 0 {
      return false
    }
    return value != 0
  }

  private func mpvDouble(_ name: String) -> Double {
    var value: Double = 0
    if mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) < 0 {
      return 0
    }
    return value
  }

  private func setPaused(_ paused: Bool) {
    mpv_set_property_string(handle, "pause", paused ? "yes" : "no")
  }

  private func seek(by seconds: Double) {
    guard seconds != 0 else {
      return
    }
    mpv_command_string(handle, "seek \(seconds) relative")
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PictureInPicture: AVPictureInPictureControllerDelegate {
  public func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": true])
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": false])
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    emitError("启动画中画失败：\(error.localizedDescription)")
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void
  ) {
    // 通知 Dart 侧把视频页恢复出来。
    eventCallback("VideoOutput.PictureInPictureRestoreUI", [:])
    completionHandler(true)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    setPaused(!playing)
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    seek(by: skipInterval.seconds)
    completionHandler()
  }

  public func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    let duration = mpvDouble("duration")
    if duration <= 0 {
      // 直播 / 未知时长：按“直播”处理，不显示进度条。
      return CMTimeRange(
        start: .negativeInfinity,
        duration: .positiveInfinity
      )
    }
    return CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
  }

  public func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    return mpvFlag("pause")
  }
}
