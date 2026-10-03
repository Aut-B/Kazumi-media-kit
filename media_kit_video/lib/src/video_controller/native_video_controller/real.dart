/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:ffi';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:media_kit/media_kit.dart';
// ignore_for_file: unused_import, implementation_imports
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';

import 'package:media_kit/generated/libmpv/bindings.dart';

import 'package:media_kit_video/src/picture_in_picture.dart';
import 'package:media_kit_video/src/video_controller/video_controller.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  /// {@macro native_video_controller}
  NativeVideoController._(super.player, super.configuration)
    : width = configuration.width,
      height = configuration.height;

  /// {@macro native_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = NativeVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller._dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    // ----------------------------------------------
    final values = {
      'vo': configuration.vo ?? 'libmpv',
      'hwdec': configuration.hwdec ?? 'auto',
      'vid': 'auto',
    };
    final mpv = NativePlayer.mpv;
    final ctx = player.ctx;
    for (final entry in values.entries) {
      final property = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_property_string(ctx, property, value);
      calloc.free(property);
      calloc.free(value);
    }
    // ----------------------------------------------

    // Wait until first texture ID is received i.e. render context & EGL/D3D surface is created.
    // We are not waiting on the native-side itself because it will block the UI thread.
    // Background platform channels are not a thing yet.
    final completer = Completer<void>();
    void listener() {
      if (controller.id.value != null) {
        debugPrint('NativeVideoController: Texture ID: ${controller.id.value}');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
      'configuration': {
        'width': configuration.width.toString(),
        'height': configuration.height.toString(),
        'enableHardwareAcceleration': configuration.enableHardwareAcceleration,
      },
    });

    await completer.future;
    controller.id.removeListener(listener);

    // Return the [VideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void>? setSize({int? width, int? height}) {
    if (this.width == width && this.height == height) {
      // No need to resize if the requested size is same as the current size.
      return null;
    }
    this.width = width;
    this.height = height;
    return _channel.invokeMethod('VideoOutputManager.SetSize', {
      'handle': player.handle.toString(),
      'width': width.toString(),
      'height': height.toString(),
    });
  }

  /// 当前平台 / 设备是否支持系统级画中画（仅 iOS）。
  @override
  Future<bool> isPictureInPictureSupported() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'VideoOutput.IsPictureInPictureSupported',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 进入 / 退出系统级画中画（仅 iOS）。
  ///
  /// 播放 / 暂停 / 快进在原生侧直接操作 libmpv，media_kit 会通过属性观察自动
  /// 同步 Dart 状态；进入 / 退出结果通过 `PictureInPicture.events` 通知。
  @override
  Future<void> setPictureInPicture(bool value) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod('VideoOutput.SetPictureInPicture', {
        'handle': player.handle.toString(),
        'value': value,
      });
    } catch (exception) {
      debugPrint('NativeVideoController: setPictureInPicture: $exception');
    }
  }

  /// 「武装」自动画中画（仅 iOS）：不立即弹出窗口，而是在用户划回主屏幕
  /// （App 进入后台）时由系统自动进入画中画。
  @override
  Future<void> setAutoEnterPictureInPicture(bool value) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod('VideoOutput.SetAutoEnterPictureInPicture', {
        'handle': player.handle.toString(),
        'value': value,
      });
    } catch (exception) {
      debugPrint(
        'NativeVideoController: setAutoEnterPictureInPicture: $exception',
      );
    }
  }

  /// 当前是否具备进入画中画的条件（仅 iOS）。
  @override
  Future<bool> isPictureInPicturePossible() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'VideoOutput.IsPictureInPicturePossible',
            {'handle': player.handle.toString()},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 画中画诊断快照（仅 iOS）。
  @override
  Future<Map<String, Object?>> pictureInPictureDiagnostics() async {
    if (!Platform.isIOS) {
      return const {};
    }
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        'VideoOutput.PictureInPictureDiagnostics',
        {'handle': player.handle.toString()},
      );
      return value ?? const {};
    } catch (_) {
      return const {};
    }
  }

  /// 开启 / 关闭画中画「画面内诊断叠加层」（仅 iOS）。
  @override
  Future<void> setPictureInPictureDebugOverlay(bool value) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod(
        'VideoOutput.SetPictureInPictureDebugOverlay',
        {'handle': player.handle.toString(), 'value': value},
      );
    } catch (exception) {
      debugPrint(
        'NativeVideoController: setPictureInPictureDebugOverlay: $exception',
      );
    }
  }

  /// 开启 / 关闭画中画弹幕（仅 iOS）。
  @override
  Future<void> setPictureInPictureDanmakuEnabled(bool value) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod(
        'VideoOutput.SetPictureInPictureDanmakuEnabled',
        {'handle': player.handle.toString(), 'value': value},
      );
    } catch (exception) {
      debugPrint(
        'NativeVideoController: setPictureInPictureDanmakuEnabled: $exception',
      );
    }
  }

  /// 下发画中画弹幕显示参数（仅 iOS）。
  @override
  Future<void> setPictureInPictureDanmakuConfig(
    Map<String, Object> config,
  ) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod(
        'VideoOutput.SetPictureInPictureDanmakuConfig',
        {'handle': player.handle.toString(), 'value': config},
      );
    } catch (exception) {
      debugPrint(
        'NativeVideoController: setPictureInPictureDanmakuConfig: $exception',
      );
    }
  }

  /// 追加画中画弹幕数据（仅 iOS）。
  @override
  Future<void> addPictureInPictureDanmaku(
    List<Map<String, Object>> items,
  ) async {
    if (!Platform.isIOS || items.isEmpty) {
      return;
    }
    try {
      await _channel.invokeMethod('VideoOutput.AddPictureInPictureDanmaku', {
        'handle': player.handle.toString(),
        'value': items,
      });
    } catch (exception) {
      debugPrint(
        'NativeVideoController: addPictureInPictureDanmaku: $exception',
      );
    }
  }

  /// 清空画中画弹幕数据（仅 iOS）。
  @override
  Future<void> clearPictureInPictureDanmaku() async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod('VideoOutput.ClearPictureInPictureDanmaku', {
        'handle': player.handle.toString(),
      });
    } catch (exception) {
      debugPrint(
        'NativeVideoController: clearPictureInPictureDanmaku: $exception',
      );
    }
  }

  /// 为「换了视频源」做准备（仅 iOS）。
  @override
  Future<void> preparePictureInPictureForNewMedia() async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod(
        'VideoOutput.PreparePictureInPictureForNewMedia',
        {'handle': player.handle.toString()},
      );
    } catch (exception) {
      debugPrint(
        'NativeVideoController: preparePictureInPictureForNewMedia: $exception',
      );
    }
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() {
    final handle = player.handle;
    _controllers.remove(handle);
    return _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [_channel].
  static final _controllers = HashMap<int, NativeVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler((MethodCall call) {
          try {
            final Map args = call.arguments;
            debugPrint(call.method.toString());
            debugPrint(args.toString());
            switch (call.method) {
              case 'VideoOutput.Resize':
                {
                  // Notify about updated texture ID & [Rect].
                  final int handle = args['handle'];
                  final Map rectArgs = args['rect'];
                  final Rect rect = Rect.fromLTWH(
                    (rectArgs['left'] as num).toDouble(),
                    (rectArgs['top'] as num).toDouble(),
                    (rectArgs['width'] as num).toDouble(),
                    (rectArgs['height'] as num).toDouble(),
                  );
                  final int id = args['id'];
                  _controllers[handle]?.rect.value = rect;
                  _controllers[handle]?.id.value = id;
                  // Notify about the first frame being rendered.
                  if (rect.width > 0 && rect.height > 0) {
                    final completer = _controllers[handle]
                        ?.waitUntilFirstFrameRenderedCompleter;
                    if (!(completer?.isCompleted ?? true)) {
                      completer?.complete();
                    }
                  }
                  break;
                }
              case 'VideoOutput.PictureInPictureStateChanged':
                {
                  final bool active = (args['active'] as bool?) ?? false;
                  PictureInPicture.emit(active ? 'start' : 'stop');
                  break;
                }
              case 'VideoOutput.PictureInPictureRestoreUI':
                {
                  PictureInPicture.emit('restore');
                  break;
                }
              case 'VideoOutput.PictureInPictureError':
                {
                  final String message =
                      (args['message'] as String?) ?? '画中画不可用';
                  PictureInPicture.emitError(message);
                  break;
                }
              default:
                {
                  break;
                }
            }
          } catch (exception, stacktrace) {
            debugPrint(exception.toString());
            debugPrint(stacktrace.toString());
          }
          return Future.value();
        });
}
