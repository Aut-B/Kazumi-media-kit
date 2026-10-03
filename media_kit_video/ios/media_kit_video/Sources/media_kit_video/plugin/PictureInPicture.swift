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
/// 属性（经 `MPVHelpers`）。media_kit 的 Dart 层 observe 了这些属性，
/// 因此状态会自动同步回上层 UI，无需额外的 Dart 往返。
///
/// 两种进入方式：
/// * **手动**：调用 [start]，立即弹出画中画窗口（对应播放器上的「画中画」按钮）；
/// * **自动**：调用 [arm] 只做「武装」——把图层挂进视图层级、建好 controller 并
///   打开 `canStartPictureInPictureAutomaticallyFromInline`，**不**立即弹出窗口，
///   由系统在用户划回主屏幕（App 进入后台）时自动进入画中画。
public class PictureInPicture: NSObject {
  /// 事件回调：`(方法名, 参数)`，由 `VideoOutput` 转发给 Dart 侧。
  public typealias EventCallback = (String, [String: Any]) -> Void

  private let handle: OpaquePointer
  private let eventCallback: EventCallback

  /// 承载画面的图层。
  private let displayLayer = AVSampleBufferDisplayLayer()

  /// 承载 [displayLayer] 的宿主视图。
  ///
  /// 系统在判定画中画是否可用时，要求画面源位于视图层级中**且可见**；若把图层直接
  /// 塞在 Flutter 视图之下（完全被遮挡），系统可能认为「画面不可见」而拒绝启动
  /// 画中画。因此这里用一个 2×2 点的宿主视图挂在 Flutter 视图**之上**：
  /// 尺寸极小（约几个像素）因而观感上无影响，同时满足可见性判定。
  private lazy var hostView: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    return view
  }()

  /// 画中画控制器（iOS 15+ 才会创建）。
  private var pipController: AVPictureInPictureController?

  /// 画中画小窗的时间轴。
  ///
  /// 小窗里的进度条与「前进 / 后退 N 秒」按钮都以画面图层的时间轴为准。若不设置它，
  /// 系统无从判断当前播放到哪儿，会把进度条画成一条满格长条，并因为「已经到片尾」
  /// 而把前进按钮置灰。
  private var controlTimebase: CMTimebase?

  /// 是否处于「已武装」状态：为 true 时向 [displayLayer] 提供画面帧。
  ///
  /// 由 [start] / [arm] 置位，只有 [disarm] / [dispose] 才会复位——**关闭小窗
  /// （[stop]）不解除武装**。这一点很关键：解除武装意味着图层再也收不到帧，
  /// 而 `AVPictureInPictureController` 仍在，用户随后划回主屏幕自动进入的小窗
  /// （或再次点按「画中画」按钮）就只剩黑屏。
  public private(set) var isArmed: Bool = false

  /// 上一帧对应的播放位置（秒），用于识别「换了视频源导致时间轴倒退」。
  private var lastPosition: Double = -1

  /// 上一次在「小窗未显示」状态下喂帧的时间，用于降频。
  private var lastIdleEnqueue: CFTimeInterval = 0

  /// 向宿主请求一帧最新画面。
  ///
  /// 由 `VideoOutput` 注入：补帧要经过渲染线程取像素缓冲，不能在这里直接做。
  /// 启动阶段主动补一帧，是为了保证图层里「有内容」——这正是系统判定画中画
  /// 可用性的前提之一。
  public var onNeedFrame: (() -> Void)?

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

  /// 小窗是否正在显示。
  ///
  /// 由 delegate 回调在主线程维护。渲染线程需要频繁判断「小窗是否可见」来决定
  /// 喂帧策略，而 `AVPictureInPictureController` 的属性只能在主线程访问，故这里
  /// 用一份普通 Bool 缓存供其它线程安全读取。
  public private(set) var isShowing: Bool = false

  /// 当前是否具备进入画中画的条件（图层已就绪等）。
  public var isPossible: Bool {
    return pipController?.isPictureInPicturePossible ?? false
  }

  // MARK: - 生命周期

  /// 立即进入系统画中画（用户点按播放器上的「画中画」按钮）。
  ///
  /// 系统在 `isPictureInPicturePossible` 为 `false` 时会静默忽略
  /// `startPictureInPicture()`，因此这里不赌「点按那一刻条件已经成立」：先把画面源
  /// 扶正、补一帧，稍后再确认一次并启动。
  public func start() {
    guard #available(iOS 15.0, *) else {
      NSLog("PictureInPicture: requires iOS 15.0 or above")
      emitError("画中画需要 iOS 15 及以上系统")
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("PictureInPicture: not supported on this device")
      emitError("当前机型不支持画中画（系统判定）")
      return
    }

    isArmed = true
    DispatchQueue.main.async { [weak self] () -> Void in
      guard let instance = self else {
        return
      }
      guard let controller = instance.makeController() else {
        return
      }
      if controller.isPictureInPictureActive {
        return
      }
      if controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
        return
      }
      // 系统还不认这个画面源：重新挂一次（保证它确实在最前、且被判定为可见），
      // 图层状态异常时清掉，并补一帧最新画面，稍后再试一次。
      instance.attachDisplayLayer()
      if instance.displayLayer.status == .failed {
        instance.displayLayer.flush()
      }
      instance.onNeedFrame?()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        [weak self] () -> Void in
        guard let retry = self else {
          return
        }
        guard let controller2 = retry.pipController,
          controller2.isPictureInPicturePossible,
          !controller2.isPictureInPictureActive
        else {
          return
        }
        controller2.startPictureInPicture()
      }
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
    DispatchQueue.main.async { [weak self] () -> Void in
      guard let instance = self else {
        return
      }
      guard let controller = instance.makeController() else {
        return
      }
      controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
      // 自动进入（划回主屏幕）走的是系统的判定，同样要求图层里「有内容」；
      // 这里先补一帧，免得用户划出去时系统还在等第一帧。
      instance.onNeedFrame?()
    }
  }

  /// 关闭画中画小窗，但**保持画面源可用**。
  public func stop() {
    guard #available(iOS 15.0, *) else {
      return
    }
    DispatchQueue.main.async { [weak self] () -> Void in
      self?.pipController?.stopPictureInPicture()
    }
  }

  /// 不再向系统提供画中画画面源。仅用于释放前的收尾。
  public func disarm() {
    isArmed = false
    isShowing = false
    lastPosition = -1
    lastIdleEnqueue = 0
  }

  /// 为「换了视频源」做准备（连播下一集、切换清晰度、换源等）。
  ///
  /// 新视频的播放位置从 0 开始，而图层时间轴此前已推进到上一集的位置；时间轴
  /// 倒退会让 `AVSampleBufferDisplayLayer` 停止消化后续样本，表现即「App 里画面
  /// 正常、小窗一直黑」。这里清空图层与时间轴，控制器本身保持不动。
  public func prepareForNewMedia() {
    lastPosition = -1
    lastIdleEnqueue = 0

    let layer = displayLayer
    let timebase = controlTimebase
    DispatchQueue.main.async { () -> Void in
      layer.flush()
      if #available(iOS 15.0, *), let timebase = timebase {
        CMTimebaseSetTime(timebase, time: .zero)
      }
    }
  }

  /// 释放资源。
  ///
  /// 可能在任意线程（`VideoOutput.deinit`）被调用，而 AVKit / UIKit 的对象只能
  /// 在主线程序列上访问，因此统一转投主线程执行。
  public func dispose() {
    disarm()

    let layer = displayLayer
    let host = hostView
    let controller = pipController
    pipController = nil
    DispatchQueue.main.async { () -> Void in
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
  private func makeController() -> AVPictureInPictureController? {
    // 画中画需要「播放」类音频会话；这里补齐，避免被系统中断。
    activateAudioSession()

    attachDisplayLayer()
    setupTimebase()

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
  ///
  /// - Parameter force: 绕过「小窗未显示时降频」的限制，供启动阶段主动补帧使用。
  ///   图层里有没有画面会直接影响系统对画中画可用性的判定，这一帧不能省。
  public func enqueue(_ pixelBuffer: CVPixelBuffer, force: Bool = false) {
    guard #available(iOS 15.0, *) else {
      return
    }

    guard isArmed else {
      return
    }

    // 图层尚未消化完上一帧时直接丢弃，避免堆积与卡顿。
    let layer = displayLayer
    if !layer.isReadyForMoreMediaData, !force {
      return
    }

    if !isShowing, !force {
      // 小窗还没显示：仍要维持图层里有画面——系统正是据此判断「有内容可以画中画」，
      // 否则划回主屏幕时不会自动进入。但降到约 10 fps，避免长时间占住 Flutter
      // 那几个轮转使用的像素缓冲。
      let now = CACurrentMediaTime()
      if now - lastIdleEnqueue < 0.1 {
        return
      }
      lastIdleEnqueue = now
    }

    // 当前播放位置：用于校准小窗进度条与时间戳。
    let position = mpvPosition()
    if lastPosition >= 0, position < lastPosition - 1 {
      // 播放位置大幅倒退说明换了视频源；时间轴倒退会让图层停止消化后续样本。
      DispatchQueue.main.async { () -> Void in
        layer.flush()
      }
    }
    lastPosition = position
    syncTimebase(position)

    let frame = pixelBuffer

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: frame,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription = formatDescription else {
      return
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(
        seconds: position,
        preferredTimescale: 600
      ),
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: frame,
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

    DispatchQueue.main.async { () -> Void in
      if layer.status == .failed || (force && !layer.isReadyForMoreMediaData) {
        layer.flush()
      }
      layer.enqueue(sampleBuffer)
    }
  }

  // MARK: - 弹幕
  //
  // 小窗弹幕需要把文字绘进每一帧的副本，本轮先不接入：接口保留，Dart 侧调用为空操作。

  public func setDanmakuEnabled(_ value: Bool) {}

  public func setDanmakuConfig(_ config: [String: Any]) {}

  public func addDanmaku(_ items: [[String: Any]]) {}

  public func clearDanmaku() {}

  /// 记录一次「渲染回调在跑，但取不到像素缓冲」。
  public func noteCopyNil() {}

  /// 诊断快照（精简版只返回基础状态）。
  public func diagnostics() -> [String: Any] {
    return [
      "supported": PictureInPicture.isSupported,
      "armed": isArmed,
      "showing": isShowing,
      "possible": isPossible,
      "paused": mpvFlag("pause"),
      "position": mpvPosition(),
    ]
  }

  // MARK: - 内部

  /// 激活播放类音频会话。
  ///
  /// 画中画要求 App 持有活跃的播放类音频会话；会话被抢占、或类别被改动过时，
  /// 系统可能只给出一个没有画面的小窗。
  private func activateAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      NSLog("PictureInPicture: AVAudioSession error: \(error)")
    }
  }

  /// 建立画面图层的时间轴（只做一次）。
  @available(iOS 15.0, *)
  private func setupTimebase() {
    if controlTimebase != nil {
      return
    }
    var timebase: CMTimebase?
    let status = CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    guard status == noErr, let timebase = timebase else {
      NSLog("PictureInPicture: CMTimebaseCreateWithSourceClock failed: \(status)")
      return
    }
    CMTimebaseSetRate(timebase, rate: 1.0)
    displayLayer.controlTimebase = timebase
    controlTimebase = timebase
  }

  /// 把小窗时间轴校准到当前播放位置，并同步播放 / 暂停状态。
  @available(iOS 15.0, *)
  private func syncTimebase(_ position: Double) {
    guard let timebase = controlTimebase else {
      return
    }
    CMTimebaseSetTime(
      timebase,
      time: CMTime(seconds: position, preferredTimescale: 600)
    )
    let rate: Double = mpvFlag("pause") ? 0 : 1
    if CMTimebaseGetRate(timebase) != rate {
      CMTimebaseSetRate(timebase, rate: rate)
    }
  }

  /// 当前播放位置（秒）。取不到时返回 0。
  private func mpvPosition() -> Double {
    let value = mpvDouble("time-pos")
    if value.isNaN || value.isInfinite || value < 0 {
      return 0
    }
    return value
  }

  /// 把图层挂进视图层级：置于极小宿主视图内、叠在 Flutter 视图之上。
  ///
  /// 之所以不直接挂在 window 图层最底层：那样会被 Flutter 视图完全遮挡，部分系统
  /// 版本会因此判定画面「不可见」，导致 `isPictureInPicturePossible` 恒为 false，
  /// 画中画按钮点了没有反应。
  ///
  /// 位置取窗口正中：无论窗口铺满屏幕、还是被宿主进程以「场景托管」的方式嵌在它
  /// 自己的窗口里（此时可见区域与全屏并不一致），画面源都必定落在可见范围之内。
  private func attachDisplayLayer() {
    guard let window = PictureInPicture.keyWindow else {
      NSLog("PictureInPicture: key window not found")
      return
    }

    let side: CGFloat = 2
    if hostView.superview !== window {
      hostView.removeFromSuperview()
      window.addSubview(hostView)
      window.bringSubviewToFront(hostView)
    }
    hostView.frame = CGRect(
      x: (window.bounds.width - side) / 2,
      y: (window.bounds.height - side) / 2,
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
    return MPVHelpers.getFlag(handle, name)
  }

  private func mpvDouble(_ name: String) -> Double {
    return MPVHelpers.getDouble(handle, name)
  }

  private func setPaused(_ paused: Bool) {
    MPVHelpers.setString(handle, "pause", paused ? "yes" : "no")
  }

  /// 画中画小窗里的「前进 / 后退 N 秒」。
  ///
  /// 按绝对时间跳转并夹在 `[0, duration)` 内，随后立刻校准时间轴，让小窗进度条
  /// 马上跟到新位置。
  private func seek(by offset: Double) {
    guard offset != 0 else {
      return
    }
    let duration = mpvDouble("duration")
    var target = mpvPosition() + offset
    if target < 0 {
      target = 0
    }
    if duration > 0, target > duration - 0.5 {
      target = max(0, duration - 0.5)
    }
    MPVHelpers.command(
      handle,
      "seek \(String(format: "%.3f", target)) absolute+exact"
    )
    if #available(iOS 15.0, *), let timebase = controlTimebase {
      CMTimebaseSetTime(
        timebase,
        time: CMTime(seconds: target, preferredTimescale: 600)
      )
    }
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PictureInPicture: AVPictureInPictureControllerDelegate {
  public func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // 小窗已经出现，说明系统认可这个画面源。此刻无论此前状态如何，都保证图层
    // 处于「提供画面」状态，否则小窗会定格在最后一帧、甚至全黑。
    isArmed = true
    isShowing = true
    attachDisplayLayer()
    // 启动阶段为了「让系统判定画面源可用」补过几帧，那批样本的时间戳与队列状态
    // 未必干净；小窗真正开始接管画面时清一次队列，让随后送进来的帧从头播放。
    if displayLayer.status == .failed || !displayLayer.isReadyForMoreMediaData {
      displayLayer.flush()
    }
    lastPosition = -1
    lastIdleEnqueue = 0
    activateAudioSession()
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": true])
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isShowing = false
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
