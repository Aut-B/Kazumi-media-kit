import CoreGraphics
import Foundation

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  /// 系统级画中画事件回调（仅 iOS）：`(方法名, 参数)`。
  ///
  /// 用于把画中画的状态变化（进入 / 退出 / 回到 App）回传给 Dart 侧。
  public typealias PictureInPictureEventCallback =
    (String, [String: Any]) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let pipEventCallback: PictureInPictureEventCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false

  #if os(iOS)
    /// 系统级画中画（iOS 15+，见 `PictureInPicture`）。
    private var pip: PictureInPicture?
  #endif

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback,
    pipEventCallback: @escaping PictureInPictureEventCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback
    self.pipEventCallback = pipEventCallback

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()

    #if os(iOS)
      pip?.dispose()
      pip = nil
    #endif

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      guard !self.disposed else { return }
      self.width = width
      self.height = height
    }
  }

  /// 进入 / 退出系统级画中画（iOS 15+）。其它平台为空实现。
  public func setPictureInPicture(_ value: Bool) {
    #if os(iOS)
      worker.enqueue {
        if value {
          let pip = self.ensurePictureInPicture()
          pip?.start()
          // 若当前处于暂停状态，mpv 不会继续渲染新帧；这里手动补一帧，
          // 避免画中画窗口一片空白。
          if let pixelBuffer = self.texture?.copyPixelBuffer()?
            .takeRetainedValue()
          {
            pip?.enqueue(pixelBuffer)
          }
        } else {
          self.pip?.stop()
        }
      }
    #endif
  }

  /// 「武装」自动画中画：不立即弹出窗口，而是在 App 进入后台（用户划回主屏幕）时
  /// 由系统自动进入画中画。`value` 为 `false` 时关闭该行为。
  public func setAutoEnterPictureInPicture(_ value: Bool) {
    #if os(iOS)
      worker.enqueue {
        let pip = self.ensurePictureInPicture()
        pip?.arm(autoEnter: value)
      }
    #endif
  }

  /// 当前是否具备进入画中画的条件。
  public func isPictureInPicturePossible() -> Bool {
    #if os(iOS)
      return self.pip?.isPossible ?? false
    #else
      return false
    #endif
  }

  /// 画中画诊断快照（小窗黑屏时用来定位断点）。其它平台返回空表。
  public func pictureInPictureDiagnostics() -> [String: Any] {
    #if os(iOS)
      return self.pip?.diagnostics() ?? [:]
    #else
      return [:]
    #endif
  }

  /// 开启 / 关闭画中画弹幕。其它平台为空实现。
  public func setPictureInPictureDanmakuEnabled(_ value: Bool) {
    #if os(iOS)
      worker.enqueue {
        self.ensurePictureInPicture()?.setDanmakuEnabled(value)
      }
    #endif
  }

  /// 下发画中画弹幕显示参数。其它平台为空实现。
  public func setPictureInPictureDanmakuConfig(_ config: [String: Any]) {
    #if os(iOS)
      worker.enqueue {
        self.ensurePictureInPicture()?.setDanmakuConfig(config)
      }
    #endif
  }

  /// 追加画中画弹幕数据。其它平台为空实现。
  public func addPictureInPictureDanmaku(_ items: [[String: Any]]) {
    #if os(iOS)
      worker.enqueue {
        self.ensurePictureInPicture()?.addDanmaku(items)
      }
    #endif
  }

  /// 清空画中画弹幕数据。其它平台为空实现。
  public func clearPictureInPictureDanmaku() {
    #if os(iOS)
      worker.enqueue {
        self.ensurePictureInPicture()?.clearDanmaku()
      }
    #endif
  }

  /// 为「换了视频源」做准备（连播下一集、换源、切清晰度等）。
  ///
  /// 保持画中画控制器与画面源不动，只清掉上一集的残留——图层内容、时间轴与
  /// 弹幕——这样小窗会在下一帧到来后无缝接上新视频，而不是停在黑屏。
  /// 其它平台为空实现。
  public func preparePictureInPictureForNewMedia() {
    #if os(iOS)
      worker.enqueue {
        self.pip?.prepareForNewMedia()
      }
    #endif
  }

  #if os(iOS)
    /// 把最新渲染完成的一帧喂给画中画图层。
    ///
    /// - Parameter force: 绕过「小窗未显示时降频」的限制，用于启动阶段主动补帧。
    private func feedPictureInPicture(force: Bool = false) {
      guard let instance = self.pip, instance.isArmed else {
        return
      }
      guard let pixelBuffer = self.texture?.copyPixelBuffer()?
        .takeRetainedValue()
      else {
        // 渲染回调明明来过了，却取不到像素缓冲：记一笔，用于区分「没出帧」与
        // 「出了帧但拿不到画面」——这两种情况的成因完全不同。
        instance.noteCopyNil()
        return
      }
      instance.enqueue(pixelBuffer, force: force)
    }

    /// 懒创建画中画对象，保证 `arm` 与 `start` 共用同一实例。
    private func ensurePictureInPicture() -> PictureInPicture? {
      if let existing = self.pip {
        return existing
      }
      let instance = PictureInPicture(
        handle: self.handle,
        eventCallback: self.pipEventCallback
      )
      // 启动阶段需要主动补帧（系统靠「图层里有没有画面」判定画中画可用性）。
      // 取像素缓冲必须走渲染线程，因此这里只回投一个任务。
      instance.onNeedFrame = { [weak self] () -> Void in
        guard let that = self else {
          return
        }
        that.worker.enqueue { () -> Void in
          that.feedPictureInPicture(force: true)
        }
      }
      self.pip = instance
      return instance
    }
  #endif

  /// 当前设备 / 系统是否支持系统级画中画。
  public static var isPictureInPictureSupported: Bool {
    #if os(iOS)
      return PictureInPicture.isSupported
    #else
      return false
    #endif
  }

  public func dispose(completion: @escaping () -> Void) {
    // Drain rendering on its worker without blocking the platform thread,
    // which pending render jobs may still need for texture notifications.
    worker.enqueue {
      self.disposed = true
      self.texture?.dispose()
      self.disposeTextureId {
        self.worker.cancel()
        completion()
      }
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    let update: () -> Void = { [weak self] in
      self?.updateCallback()
    }
    var hardwareTexture: ResizableTextureProtocol?
    if enableHardwareAcceleration {
      hardwareTexture = TextureHW(
        handle: handle,
        updateCallback: update
      )
    }
    if let hardwareTexture = hardwareTexture {
      texture = SafeResizableTexture(hardwareTexture)
    } else {
      if enableHardwareAcceleration {
        NSLog("VideoOutput: hardware rendering unavailable; using software rendering")
      }
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          updateCallback: update
        )
      )
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId(completion: @escaping () -> Void = {}) {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      if textureId_ >= 0 {
        registry_.unregisterTexture(textureId_)
      }
      completion()
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    guard !disposed else { return }
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      currentSize = size

      texture.resize(size)

      // 同下：小窗显示（App 多在后台）期间不阻塞渲染线程。
      var pipActive = false
      #if os(iOS)
        pipActive = pip?.isShowing == true
      #endif
      if pipActive {
        DispatchQueue.main.async { [weak self] in
          guard let that = self else { return }
          // textureUpdateCallback must run on the main thread
          that.textureUpdateCallback(that.textureId, size)
        }
      } else {
        DispatchQueue.main.sync { [weak self] in
          guard let that = self else { return }
          // textureUpdateCallback must run on the main thread
          that.textureUpdateCallback(that.textureId, size)
        }
      }
    }

    if disposed {
      return
    }

    texture.render(size)

    #if os(iOS)
      feedPictureInPicture()

      // 小窗显示期间改用异步通知：此时 App 多半已进入后台，主线程正忙于处理
      // 生命周期切换，用 `sync` 会把渲染线程一起堵住 —— 表现即系统小窗停止刷新、
      // 只剩黑屏。异步投递不会阻塞出帧，主线程空闲时自然消化。
      if pip?.isShowing == true {
        DispatchQueue.main.async { [weak self] in
          guard let that = self else { return }
          that.registry.textureFrameAvailable(that.textureId)
        }
        return
      }
    #endif

    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

  private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}
