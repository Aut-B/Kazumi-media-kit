/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';

import 'package:flutter/services.dart';

/// 系统级画中画（Picture-in-Picture）辅助 API（iOS）。
///
/// 与 [PlatformVideoController.setPictureInPicture] 配合使用：
///
/// ```dart
/// if (await PictureInPicture.isSupported()) {
///   await videoController.setPictureInPicture(true);
/// }
/// ```
///
/// 进入 / 退出画中画、以及用户点击画中画窗口的「回到 App」按钮时，会通过
/// [events] 抛出事件。
class PictureInPicture {
  PictureInPicture._();

  /// 与原生插件共用的方法通道。
  static const MethodChannel _channel = MethodChannel(
    'com.alexmercerind/media_kit_video',
  );

  static final StreamController<String> _events =
      StreamController<String>.broadcast();

  /// 画中画事件流。取值：
  /// * `start`：已进入系统画中画窗口；
  /// * `stop`：已退出系统画中画窗口；
  /// * `restore`：用户点击画中画窗口的「回到 App」按钮。
  static Stream<String> get events {
    return _events.stream;
  }

  /// 由原生侧（[NativeVideoController] 的方法通道处理器）调用，向 [events] 推送事件。
  static void emit(String event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  static final StreamController<String> _errors =
      StreamController<String>.broadcast();

  /// 画中画错误流。内容为可直接展示给用户的失败原因，
  /// 例如「当前设备不支持画中画」「启动画中画失败：…」。
  static Stream<String> get errors {
    return _errors.stream;
  }

  /// 由原生侧调用，向 [errors] 推送错误信息。
  static void emitError(String message) {
    if (!_errors.isClosed) {
      _errors.add(message);
    }
  }

  /// 当前设备 / 系统是否支持系统级画中画（iOS 15+）。
  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>(
            'VideoOutput.IsPictureInPictureSupported',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
