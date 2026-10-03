#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class VideoOutputManager: NSObject {
  private let registry: FlutterTextureRegistry
  private var videoOutputs = [Int64: VideoOutput]()

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public func create(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    textureUpdateCallback: @escaping VideoOutput.TextureUpdateCallback,
    pipEventCallback: @escaping VideoOutput.PictureInPictureEventCallback
  ) {
    let videoOutput = VideoOutput(
      handle: handle,
      configuration: configuration,
      registry: self.registry,
      textureUpdateCallback: textureUpdateCallback,
      pipEventCallback: pipEventCallback
    )

    self.videoOutputs[handle] = videoOutput
  }

  /// 进入 / 退出系统级画中画。
  public func setPictureInPicture(
    handle: Int64,
    value: Bool
  ) {
    self.videoOutputs[handle]?.setPictureInPicture(value)
  }

  /// 「武装」自动画中画：App 进入后台时由系统自动进入画中画。
  public func setAutoEnterPictureInPicture(
    handle: Int64,
    value: Bool
  ) {
    self.videoOutputs[handle]?.setAutoEnterPictureInPicture(value)
  }

  /// 当前是否具备进入画中画的条件。
  public func isPictureInPicturePossible(
    handle: Int64
  ) -> Bool {
    return self.videoOutputs[handle]?.isPictureInPicturePossible() ?? false
  }

  /// 画中画诊断快照。
  public func pictureInPictureDiagnostics(
    handle: Int64
  ) -> [String: Any] {
    return self.videoOutputs[handle]?.pictureInPictureDiagnostics() ?? [:]
  }

  /// 开启 / 关闭画中画弹幕。
  public func setPictureInPictureDanmakuEnabled(
    handle: Int64,
    value: Bool
  ) {
    self.videoOutputs[handle]?.setPictureInPictureDanmakuEnabled(value)
  }

  /// 下发画中画弹幕显示参数。
  public func setPictureInPictureDanmakuConfig(
    handle: Int64,
    config: [String: Any]
  ) {
    self.videoOutputs[handle]?.setPictureInPictureDanmakuConfig(config)
  }

  /// 追加画中画弹幕数据。
  public func addPictureInPictureDanmaku(
    handle: Int64,
    items: [[String: Any]]
  ) {
    self.videoOutputs[handle]?.addPictureInPictureDanmaku(items)
  }

  /// 清空画中画弹幕数据。
  public func clearPictureInPictureDanmaku(
    handle: Int64
  ) {
    self.videoOutputs[handle]?.clearPictureInPictureDanmaku()
  }

  /// 为「换了视频源」做准备（保持小窗，只清上一集的图层内容 / 时间轴 / 弹幕）。
  public func preparePictureInPictureForNewMedia(
    handle: Int64
  ) {
    self.videoOutputs[handle]?.preparePictureInPictureForNewMedia()
  }

  public func setSize(
    handle: Int64,
    width: Int64?,
    height: Int64?
  ) {
    let videoOutput = self.videoOutputs[handle]
    if videoOutput == nil {
      return
    }

    videoOutput!.setSize(
      width: width,
      height: height
    )
  }

  public func destroy(
    handle: Int64
  ) {
    let videoOutput = self.videoOutputs[handle]
    if videoOutput == nil {
      return
    }

    self.videoOutputs[handle] = nil
  }
}
