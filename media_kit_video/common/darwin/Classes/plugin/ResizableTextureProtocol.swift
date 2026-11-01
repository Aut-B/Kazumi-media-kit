#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
  func resize(_ size: CGSize)
  func render(_ size: CGSize)
  /// 渲染并等这一帧真正写完（画中画取帧用）。默认退化为 [render]。
  func renderSynchronized(_ size: CGSize)
}

extension ResizableTextureProtocol {
  public func renderSynchronized(_ size: CGSize) {
    render(size)
  }
}
