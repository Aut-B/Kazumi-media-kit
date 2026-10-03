/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'package:flutter/widgets.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/video_controller.dart';

/// {@template platform_video_controller}
///
/// PlatformVideoController
/// -----------------------
///
/// This class provides the interface for platform specific [VideoController] implementations.
/// The platform specific implementations are expected to implement the methods accordingly.
///
/// The subclasses are then used in composition with the [VideoController] class, based on the platform the application is running on.
///
/// {@endtemplate}
abstract class PlatformVideoController {
  /// The [Player] instance associated with this instance.
  final Player player;

  /// User defined configuration for [VideoController].
  final VideoControllerConfiguration configuration;

  /// Texture ID of the video output, registered with Flutter engine by the native implementation.
  final ValueNotifier<int?> id = ValueNotifier<int?>(null);

  /// [Rect] of the video output, received from the native implementation.
  final ValueNotifier<Rect?> rect = ValueNotifier<Rect?>(null);

  /// {@macro platform_video_controller}
  PlatformVideoController(
    this.player,
    this.configuration,
  );

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  Future<void> setSize({
    int? width,
    int? height,
  });

  /// 当前平台 / 设备是否支持系统级画中画。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台恒为 `false`。
  Future<bool> isPictureInPictureSupported() => Future.value(false);

  /// 进入 / 退出系统级画中画。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  /// 进入 / 退出结果可通过 `PictureInPicture.events` 监听。
  Future<void> setPictureInPicture(bool value) => Future.value();

  /// 「武装」自动画中画：不立即弹出画中画窗口，而是在用户划回主屏幕
  /// （App 进入后台）时由系统自动进入画中画。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  Future<void> setAutoEnterPictureInPicture(bool value) => Future.value();

  /// 当前是否具备进入画中画的条件（图层已就绪、已渲染首帧等）。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台恒为 `false`。
  Future<bool> isPictureInPicturePossible() => Future.value(false);

  /// 画中画诊断快照，用于判断「小窗黑屏」断在哪一环。
  ///
  /// 常见字段：`attempt`（渲染回调出帧次数）、`enqueued`（真正交给图层的帧数）、
  /// `notReady`（图层拒收次数）、`layerStatus`（`rendering` / `failed` /
  /// `unknown`）、`layerReady`、`showing`（小窗是否已显示）。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台返回空表。
  Future<Map<String, Object?>> pictureInPictureDiagnostics() =>
      Future.value(const {});

  /// 开启 / 关闭画中画弹幕。
  ///
  /// 系统画中画小窗只显示原生画面图层的内容，Flutter 侧绘制的弹幕画布不会被带
  /// 进去；开启后由原生侧按 [addPictureInPictureDanmaku] 提供的数据自行排版并
  /// 绘进每一帧，使小窗内也能看到弹幕。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  Future<void> setPictureInPictureDanmakuEnabled(bool value) => Future.value();

  /// 下发画中画弹幕的显示参数，与 App 内的弹幕设置保持一致。
  ///
  /// 支持的键：`opacity`、`fontScale`、`lineHeight`、`area`、`duration`、
  /// `staticDuration`、`strokeWidth`、`hideScroll`、`hideTop`、`hideBottom`。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  Future<void> setPictureInPictureDanmakuConfig(Map<String, Object> config) =>
      Future.value();

  /// 追加画中画弹幕数据。
  ///
  /// 每一项包含 `id`（用于去重）、`time`（相对视频起点的秒数）、`mode`
  /// （1/6 滚动、4 底部、5 顶部）、`color`（0xRRGGBB）与 `text`。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  Future<void> addPictureInPictureDanmaku(List<Map<String, Object>> items) =>
      Future.value();

  /// 清空已缓存的画中画弹幕数据（切换视频时调用）。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  Future<void> clearPictureInPictureDanmaku() => Future.value();

  /// 为「换了视频源」做准备（连播下一集、换源、切清晰度等）。
  ///
  /// 保持画中画控制器与画面源不动，只清掉上一集的残留——图层内容、时间轴与弹幕。
  /// 新视频的播放位置从 0 开始，若不清空，时间轴倒退会让画面图层停止刷新，
  /// 表现为「App 内画面正常、系统小窗一直黑屏」。
  ///
  /// 目前仅 iOS（15+）在 [NativeVideoController] 中实现，其它平台为空实现。
  Future<void> preparePictureInPictureForNewMedia() => Future.value();

  /// A [Future] that completes when the first video frame has been rendered.
  Future<void> get waitUntilFirstFrameRendered =>
      waitUntilFirstFrameRenderedCompleter.future;

  /// [Completer] used to signal the decoding & rendering of the first video frame.
  /// Use [waitUntilFirstFrameRendered] to wait for the first frame to be rendered.
  @protected
  final waitUntilFirstFrameRenderedCompleter = Completer<void>();

  void dispose() {
    id.dispose();
    rect.dispose();
  }
}

/// {@template video_controller_configuration}
///
/// VideoControllerConfiguration
/// ----------------------------
/// Configurable options for customizing the [VideoController] behavior.
///
/// {@endtemplate}
class VideoControllerConfiguration {
  /// Sets the [`--vo`](https://mpv.io/manual/stable/#options-vo) property on native backend.
  ///
  /// Default: Platform specific.
  /// * Windows, GNU/Linux, macOS & iOS: `libmpv`
  /// * Android: `gpu`
  /// * Ohos: `gpu-next`
  final String? vo;

  /// Sets the [`--hwdec`](https://mpv.io/manual/stable/#options-hwdec) property on native backend.
  ///
  /// Default: Platform specific.
  /// * Windows, GNU/Linux, macOS & iOS, Ohos : `auto`
  /// * Android: `auto-safe`
  final String? hwdec;

  /// The scale for the video output.
  /// This may be used for performance reasons. Specifying this option will cause [width] & [height] to be ignored.
  ///
  /// Default: `1.0`
  final double scale;

  /// The fixed width for the video output.
  /// This may be used for performance reasons.
  ///
  /// Default: `null`
  final int? width;

  /// The fixed height for the video output.
  /// This may be used for performance reasons.
  ///
  /// Default: `null`
  final int? height;

  /// Whether to enable hardware acceleration.
  ///
  /// DO NOT DISABLE THIS OPTION MEANINGLESSLY.
  /// THE BATTERY WILL DRAIN, THE DEVICE MAY HEAT UP & CPU USAGE WILL BE HIGH.
  ///
  /// Default: `true`
  final bool enableHardwareAcceleration;

  /// Whether to use Flutter's `SurfaceProducer` API on Android.
  ///
  /// This option only has effect on Android. If disabled, the Android
  /// implementation uses the `SurfaceTexture` code path instead. The
  /// `SurfaceTexture` code path is only effective with Android's Skia backend.
  ///
  /// Default: `true`
  final bool enableAndroidSurfaceProducer;

  /// Whether to attach `android.view.Surface` after video parameters are known.
  ///
  /// Default:
  /// * [vo] == gpu : `true`
  /// * [vo] != gpu : `false`
  final bool? androidAttachSurfaceAfterVideoParameters;

  /// {@macro video_controller_configuration}
  const VideoControllerConfiguration({
    this.vo,
    this.hwdec,
    this.width,
    this.height,
    this.scale = 1.0,
    this.enableHardwareAcceleration = true,
    this.enableAndroidSurfaceProducer = true,
    this.androidAttachSurfaceAfterVideoParameters,
  });

  /// Returns a copy of this class with the given fields replaced by the new values.
  VideoControllerConfiguration copyWith({
    String? vo,
    String? hwdec,
    double? scale,
    int? width,
    int? height,
    bool? enableHardwareAcceleration,
    bool? enableAndroidSurfaceProducer,
    bool? androidAttachSurfaceAfterVideoParameters,
  }) =>
      VideoControllerConfiguration(
        vo: vo ?? this.vo,
        hwdec: hwdec ?? this.hwdec,
        scale: scale ?? this.scale,
        width: width ?? this.width,
        height: height ?? this.height,
        enableHardwareAcceleration:
            enableHardwareAcceleration ?? this.enableHardwareAcceleration,
        enableAndroidSurfaceProducer:
            enableAndroidSurfaceProducer ?? this.enableAndroidSurfaceProducer,
        androidAttachSurfaceAfterVideoParameters:
            androidAttachSurfaceAfterVideoParameters ??
                this.androidAttachSurfaceAfterVideoParameters,
      );
}
