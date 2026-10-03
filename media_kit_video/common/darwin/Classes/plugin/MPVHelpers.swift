import Darwin
import Foundation

#if SWIFT_PACKAGE
  import Mpv
#endif

public enum MPVHelpers {
  public static func checkError(_ status: CInt) {
    if status < 0 {
      NSLog("MPVHelpers: error: \(String(cString: media_kit_mpv_error_string(status)))")
      exit(1)
    }
  }

  public static func getVideoOutParams(
    _ handle: OpaquePointer
  ) -> MPVVideoOutParams {
    var node = mpv_node()
    guard media_kit_mpv_get_property(handle, "video-out-params", MPV_FORMAT_NODE, &node) >= 0 else {
      return MPVVideoOutParams.empty
    }
    defer {
      media_kit_mpv_free_node_contents(&node)
    }
    guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else {
      return MPVVideoOutParams.empty
    }

    let map = list.pointee
    if map.num <= 0 {
      return MPVVideoOutParams.empty
    }

    return MPVVideoOutParams.fromMPVNodeList(map)
  }

  // MARK: - 画中画用到的属性读写
  //
  // 集中在同一处调用 mpv 的 C 接口：libmpv 在本工程里是运行时绑定的
  // （见 `media_kit_mpv.c`），由这里统一承担模块可见性，画中画一侧只依赖 Swift。

  /// 读取 mpv 的布尔属性（flag）。读取失败时返回 `false`。
  public static func getFlag(_ handle: OpaquePointer, _ name: String) -> Bool {
    var value: Int32 = 0
    if media_kit_mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) < 0 {
      return false
    }
    return value != 0
  }

  /// 读取 mpv 的双精度属性。读取失败时返回 `0`。
  public static func getDouble(_ handle: OpaquePointer, _ name: String) -> Double {
    var value: Double = 0
    if media_kit_mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) < 0 {
      return 0
    }
    return value
  }

  /// 写入 mpv 的字符串属性。
  public static func setString(
    _ handle: OpaquePointer,
    _ name: String,
    _ value: String
  ) {
    _ = media_kit_mpv_set_property_string(handle, name, value)
  }

  /// 执行一条 mpv 命令。
  public static func command(_ handle: OpaquePointer, _ args: String) {
    _ = media_kit_mpv_command_string(handle, args)
  }
}
