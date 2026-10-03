#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class MediaKitVideoPlugin: NSObject, FlutterPlugin {
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if canImport(Flutter)
      let binaryMessenger = registrar.messenger()
      let registry = registrar.textures()
      let utils: UtilsProtocol? = nil
    #elseif canImport(FlutterMacOS)
      let binaryMessenger = registrar.messenger
      let registry = registrar.textures
      let utils: UtilsProtocol? = Utils(registrar)
    #endif

    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let utils: UtilsProtocol?

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    videoOutputManager = VideoOutputManager(
      registry: registry
    )
    self.utils = utils
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "VideoOutputManager.Create":
      handleCreateMethodCall(call.arguments, result)
    case "VideoOutputManager.SetSize":
      handleSetSizeMethodCall(call.arguments, result)
    case "VideoOutputManager.Dispose":
      handleDisposeMethodCall(call.arguments, result)
    case "VideoOutput.SetPictureInPicture":
      handleSetPictureInPictureMethodCall(call.arguments, result)
    case "VideoOutput.SetAutoEnterPictureInPicture":
      handleSetAutoEnterPictureInPictureMethodCall(call.arguments, result)
    case "VideoOutput.IsPictureInPicturePossible":
      handleIsPictureInPicturePossibleMethodCall(call.arguments, result)
    case "VideoOutput.PictureInPictureDiagnostics":
      handlePictureInPictureDiagnosticsMethodCall(call.arguments, result)
    case "VideoOutput.IsPictureInPictureSupported":
      result(VideoOutput.isPictureInPictureSupported)
    case "VideoOutput.SetPictureInPictureDanmakuEnabled":
      handleSetPictureInPictureDanmakuEnabledMethodCall(call.arguments, result)
    case "VideoOutput.SetPictureInPictureDanmakuConfig":
      handleSetPictureInPictureDanmakuConfigMethodCall(call.arguments, result)
    case "VideoOutput.AddPictureInPictureDanmaku":
      handleAddPictureInPictureDanmakuMethodCall(call.arguments, result)
    case "VideoOutput.ClearPictureInPictureDanmaku":
      handleClearPictureInPictureDanmakuMethodCall(call.arguments, result)
    case "VideoOutput.PreparePictureInPictureForNewMedia":
      handlePreparePictureInPictureForNewMediaMethodCall(call.arguments, result)
    case "Utils.EnterNativeFullscreen":
      handleEnterNativeFullscreenMethodCall(call.arguments, result)
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleCreateMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)
    let configDict = args?["configuration"] as! [String: Any]
    let configuration = VideoOutputConfiguration.fromDict(configDict)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.create(
      handle: handle!,
      configuration: configuration,
      textureUpdateCallback: { (_ textureId: Int64, _ size: CGSize) in
        self.channel.invokeMethod(
          "VideoOutput.Resize",
          arguments: [
            "handle": handle!,
            "id": textureId,
            "rect": [
              "top": 0,
              "left": 0,
              "width": size.width,
              "height": size.height,
            ],
          ] as [String: Any]
        )
      },
      pipEventCallback: { (method: String, args: [String: Any]) in
        DispatchQueue.main.async {
          var payload: [String: Any] = ["handle": handle!]
          payload.merge(args) { _, new in new }
          self.channel.invokeMethod(method, arguments: payload)
        }
      }
    )

    result(nil)
  }

  private func handleSetSizeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let widthStr = args?["width"] as! String
    let heightStr = args?["height"] as! String

    let handle: Int64? = Int64(handleStr)
    let width: Int64? = Int64(widthStr)
    let height: Int64? = Int64(heightStr)

    assert(handle != nil, "handle must be an Int64")

    self.videoOutputManager.setSize(
      handle: handle!,
      width: width,
      height: height
    )

    result(nil)
  }

  private func handleDisposeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.destroy(
      handle: handle!
    )

    result(nil)
  }

  /// 从调用参数里取出 handle。
  private func pictureInPictureHandle(
    _ arguments: Any?,
    _ result: FlutterResult
  ) -> Int64? {
    let args = arguments as? [String: Any]
    guard let handleStr = args?["handle"] as? String,
      let handle = Int64(handleStr)
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "handle must be an Int64",
          details: nil
        )
      )
      return nil
    }
    return handle
  }

  /// 画中画诊断快照（真机排障用）。
  private func handlePictureInPictureDiagnosticsMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    guard let handle = pictureInPictureHandle(arguments, result) else {
      return
    }
    result(videoOutputManager.pictureInPictureDiagnostics(handle: handle))
  }

  /// 画中画弹幕开关。
  private func handleSetPictureInPictureDanmakuEnabledMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    guard let handle = pictureInPictureHandle(arguments, result) else {
      return
    }
    let args = arguments as? [String: Any]
    let value = (args?["value"] as? Bool) ?? false
    videoOutputManager.setPictureInPictureDanmakuEnabled(
      handle: handle,
      value: value
    )
    result(nil)
  }

  /// 画中画弹幕显示参数。
  private func handleSetPictureInPictureDanmakuConfigMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    guard let handle = pictureInPictureHandle(arguments, result) else {
      return
    }
    let args = arguments as? [String: Any]
    let config = (args?["value"] as? [String: Any]) ?? [:]
    videoOutputManager.setPictureInPictureDanmakuConfig(
      handle: handle,
      config: config
    )
    result(nil)
  }

  /// 追加弹幕数据。
  private func handleAddPictureInPictureDanmakuMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    guard let handle = pictureInPictureHandle(arguments, result) else {
      return
    }
    let args = arguments as? [String: Any]
    let items = (args?["value"] as? [[String: Any]]) ?? []
    videoOutputManager.addPictureInPictureDanmaku(
      handle: handle,
      items: items
    )
    result(nil)
  }

  /// 清空弹幕数据。
  private func handleClearPictureInPictureDanmakuMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    guard let handle = pictureInPictureHandle(arguments, result) else {
      return
    }
    videoOutputManager.clearPictureInPictureDanmaku(handle: handle)
    result(nil)
  }

  /// 为「换了视频源」做准备（保持小窗，只清上一集的残留）。
  private func handlePreparePictureInPictureForNewMediaMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    guard let handle = pictureInPictureHandle(arguments, result) else {
      return
    }
    videoOutputManager.preparePictureInPictureForNewMedia(handle: handle)
    result(nil)
  }

  private func handleSetPictureInPictureMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    guard let handleStr = args?["handle"] as? String,
      let handle = Int64(handleStr)
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "handle must be an Int64",
          details: nil
        )
      )
      return
    }

    let value = (args?["value"] as? Bool) ?? false
    videoOutputManager.setPictureInPicture(handle: handle, value: value)
    result(nil)
  }

  /// 「武装」自动画中画：App 进入后台时由系统自动进入画中画。
  private func handleSetAutoEnterPictureInPictureMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    guard let handleStr = args?["handle"] as? String,
      let handle = Int64(handleStr)
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "handle must be an Int64",
          details: nil
        )
      )
      return
    }

    let value = (args?["value"] as? Bool) ?? false
    videoOutputManager.setAutoEnterPictureInPicture(
      handle: handle,
      value: value
    )
    result(nil)
  }

  /// 当前是否具备进入画中画的条件。
  private func handleIsPictureInPicturePossibleMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    guard let handleStr = args?["handle"] as? String,
      let handle = Int64(handleStr)
    else {
      result(false)
      return
    }

    result(videoOutputManager.isPictureInPicturePossible(handle: handle))
  }

  private func handleEnterNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.enterNativeFullscreen()
    result(nil)
  }

  private func handleExitNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.exitNativeFullscreen()
    result(nil)
  }
}
