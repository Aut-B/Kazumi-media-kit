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
/// （见 `media_kit/lib/src/player/native/player/real.dart`），
/// 因此状态会自动同步回上层 UI，无需额外的 Dart 往返。
public class PictureInPicture: NSObject {
  /// 事件回调：`(方法名, 参数)`，由 [VideoOutput] 转发给 Dart 侧。
  public typealias EventCallback = (String, [String: Any]) -> Void

  private let handle: OpaquePointer
  private let eventCallback: EventCallback

  /// 承载画面的图层（iOS 8+ 可用）。
  private let displayLayer = AVSampleBufferDisplayLayer()

  /// 画中画控制器（iOS 15+ 才会创建）。
  private var pipController: AVPictureInPictureController?

  /// 是否处于“已开启画中画”状态。由 [start] 置位、[stop] / [dispose] 复位。
  /// 用于决定是否需要继续把新帧喂给 [displayLayer]。
  public private(set) var isRunning: Bool = false

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

  /// 是否已进入系统画中画。
  public var isActive: Bool {
    return pipController?.isPictureInPictureActive ?? false
  }

  // MARK: - 生命周期

  public func start() {
    guard #available(iOS 15.0, *) else {
      NSLog("PictureInPicture: requires iOS 15.0 or above")
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("PictureInPicture: not supported on this device")
      eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": false])
      return
    }

    isRunning = true
    DispatchQueue.main.async { [weak self] in
      self?._startOnMain()
    }
  }

  @available(iOS 15.0, *)
  private func _startOnMain() {
    // 画中画需要「播放」类音频会话；这里补齐，避免被系统中断。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      NSLog("PictureInPicture: AVAudioSession error: \(error)")
    }

    attachDisplayLayer()

    if pipController == nil {
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: contentSource)
      controller.delegate = self
      // 退到后台时自动进入画中画。
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      pipController = controller
    }

    guard let controller = pipController else {
      return
    }
    if !controller.isPictureInPictureActive {
      controller.startPictureInPicture()
    }
  }

  public func stop() {
    guard #available(iOS 15.0, *) else {
      return
    }
    isRunning = false
    DispatchQueue.main.async { [weak self] in
      self?.pipController?.stopPictureInPicture()
    }
  }

  public func dispose() {
    isRunning = false
    if #available(iOS 15.0, *) {
      if pipController?.isPictureInPictureActive ?? false {
        pipController?.stopPictureInPicture()
      }
      pipController?.delegate = nil
      pipController = nil
    }
    DispatchQueue.main.async { [weak self] in
      self?.displayLayer.removeFromSuperlayer()
    }
  }

  // MARK: - 帧喂入

  /// 把一帧已渲染的 [CVPixelBuffer] 入队到画中画图层。
  public func enqueue(_ pixelBuffer: CVPixelBuffer) {
    guard #available(iOS 15.0, *) else {
      return
    }
    guard isRunning else {
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

    let layer = displayLayer
    DispatchQueue.main.async {
      if layer.status == .failed {
        layer.flush()
      }
      layer.enqueue(sampleBuffer)
    }
  }

  // MARK: - 内部

  /// 把图层挂到当前 key window 的最底层（Flutter 视图之下）。
  ///
  /// 系统要求 `AVSampleBufferDisplayLayer` 位于视图层级中且尺寸非零；但画中画的
  /// “内联”预览我们并不需要（应用内已有 Flutter 纹理在渲染画面），因此把它放在
  /// Flutter 视图背后即可，避免出现两路画面。
  private func attachDisplayLayer() {
    guard let window = PictureInPicture.keyWindow else {
      return
    }
    if displayLayer.superlayer === window.layer {
      return
    }
    displayLayer.removeFromSuperlayer()
    displayLayer.frame = window.bounds
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.black.cgColor
    displayLayer.isHidden = false
    window.layer.insertSublayer(displayLayer, at: 0)
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
    NSLog("PictureInPicture: failed to start: \(error)")
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": false])
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
