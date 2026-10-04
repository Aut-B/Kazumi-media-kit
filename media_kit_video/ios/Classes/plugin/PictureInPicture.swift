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
/// （见 `media_kit/lib/src/media_kit_player.dart` 中的 `pause` / `time-pos`），
/// 因此状态会自动同步回上层 UI，无需额外的 Dart 往返。
///
/// 两种进入方式：
/// * **手动**：调用 [start]，立即弹出画中画窗口（对应播放器上的「画中画」按钮）；
/// * **自动**：调用 [arm] 只做「武装」——把图层挂进视图层级、建好 controller 并
///   打开 `canStartPictureInPictureAutomaticallyFromInline`，**不**立即弹出窗口，
///   由系统在用户划回主屏幕（App 进入后台）时自动进入画中画。
public class PictureInPicture: NSObject {
  /// 事件回调：`(方法名, 参数)`，由 [VideoOutput] 转发给 Dart 侧。
  public typealias EventCallback = (String, [String: Any]) -> Void

  private let handle: OpaquePointer
  private let eventCallback: EventCallback

  /// 承载画面的图层（iOS 8+ 可用）。
  private let displayLayer = AVSampleBufferDisplayLayer()

  /// 承载 [displayLayer] 的宿主视图。
  ///
  /// 系统在判定画中画是否可用时，要求画面源位于视图层级中**且可见**；若把图层直接
  /// 塞在 Flutter 视图之下（完全被遮挡），系统可能认为「画面不可见」而拒绝启动
  /// 画中画。因此这里用一个 2×2 点的宿主视图挂在 Flutter 视图**之上**：
  /// 尺寸极小（2 点见方），但它的面积上会实时显示当前视频帧——若照常渲染，
  /// 屏幕上就会多出一个深色小点（浅色页面上尤其显眼）。因此整棵子树压到近乎
  /// 全透明：图层照常渲染、照常有内容，系统对画面源的判定不受影响，而肉眼
  /// 看不到任何东西。个别机型若对透明度敏感，启动阶梯会临时把它提回不透明。
  ///
  /// 位置取「窗口正中」：无论窗口是铺满屏幕、还是被宿主进程以「场景托管」的
  /// 方式嵌在它自己的窗口里，画面源都必定落在可见范围内。
  private lazy var hostView: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.alpha = PictureInPicture.hostIdleAlpha
    return view
  }()

  /// 宿主视图常态下的不透明度：低到肉眼不可见，又不为 0，以免被系统当成
  /// 「画面源不可见」而拒绝启动画中画。
  private static let hostIdleAlpha: CGFloat = 0.02

  /// 画中画控制器（iOS 15+ 才会创建）。
  private var pipController: AVPictureInPictureController?

  /// 画中画小窗的时间轴。
  ///
  /// 小窗里的进度条与「前进 / 后退 N 秒」按钮都以画面图层的时间轴为准。若不设置它，
  /// 系统无从判断当前播放到哪儿，会把进度条画成一条满格长条，并因为「已经到片尾」
  /// 而把前进按钮置灰。这里挂一个以主机时钟为时间源的 timebase，逐帧按 libmpv
  /// 的 `time-pos` 校准。
  private var controlTimebase: CMTimebase?

  /// 画中画弹幕叠加层：把弹幕绘进帧副本，使系统小窗内也能看到弹幕。
  private let danmaku = DanmakuOverlay()

  /// 画面内诊断叠加层：把读数绘进帧副本，使「小窗是否收到了画面」可直接用肉眼判断。
  private let debugOverlay = PictureInPictureDebugOverlay()

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

  // MARK: - 启动重试阶梯
  //
  // 系统只在 `isPictureInPicturePossible` 为真时才理会 `startPictureInPicture()`；
  // 为假时 iOS 15 会**静默忽略**这次调用（不进 delegate、不报错），表现即「点了没
  // 反应、小窗不弹」。而该判定依赖「画面源位于可见视图层级中」与「图层里确实有
  // 画面」，在旧机型 / 慢机型上这两件事未必在点按那一瞬间就已成立。于是这里不
  // 再一次性调用，而是保留一个短暂时限，期间反复确认、顺手把画面源扶正。

  /// 启动尝试的截止时刻；`0` 表示当前没有正在进行的尝试。
  private var startDeadline: CFTimeInterval = 0

  /// 已进行的启动尝试次数（用于诊断，也用于决定是否放大宿主视图）。
  private var startTries = 0

  /// 宿主视图当前边长（点）。默认 2 点，近乎不可见。
  private var hostSide: CGFloat = 2

  /// 上一次成功进入画中画时用的宿主视图边长，作为后续启动的起点。
  private var lastGoodHostSide: CGFloat = 2

  /// 向宿主请求一帧最新画面。
  ///
  /// 由 `VideoOutput` 注入：补帧要经过渲染线程取像素缓冲，不能在这里直接做。
  /// 参数为 `true` 时表示「强势补帧」——启动阶段需要它，因为系统判定画中画是否
  /// 可用，前提就是图层里确实有画面，这一帧不能省。小窗显示期间的保活通道用
  /// `false`，走与正常喂帧相同的温和路径（不就绪就丢弃，交给卡死自愈处理）。
  public var onNeedFrame: ((Bool) -> Void)?

  // MARK: - 诊断计数
  //
  // 「小窗黑屏」可能断在好几处：渲染回调根本没出帧、图层拒绝接收样本、样本已经
  // 入队但系统没把画面接进小窗……单看现象无法区分。这几个计数与 [diagnostics] 用来
  // 把断点定位到具体一环，平时不参与播放逻辑。

  /// [enqueue] 被调用的次数，即渲染回调实际出帧数。
  private var statAttempt = 0
  /// 真正交给图层的样本数。
  private var statEnqueued = 0
  /// 因图层 `isReadyForMoreMediaData == false` 被丢弃的次数。
  private var statNotReady = 0
  /// 因尚未「武装」被丢弃的次数。
  private var statNotArmed = 0
  /// 因小窗未显示而降频丢弃的次数。
  private var statThrottled = 0
  /// 最近一次「图层不就绪」的起始时刻。
  private var notReadySince: CFTimeInterval = 0
  /// 最近一次因「图层长时间不就绪」触发 flush 的时刻。
  private var lastStuckFlush: CFTimeInterval = 0

  // MARK: - 小窗保活

  /// 小窗显示期间主动补帧的定时器。
  ///
  /// 正常路径由媒体渲染回调驱动喂帧（每一帧渲染完成即送入图层）。但在个别运行环境
  /// 里——例如 App 被另一个进程以「场景托管」的方式嵌入到它的窗口里——Flutter 的
  /// 帧回调可能长时间不来，图层就再无新内容，小窗只剩黑屏。小窗显示期间补一条
  /// 15 fps 的低速通道，与渲染回调共用 [onNeedFrame]，不改变正常路径的行为。
  private var keepAliveTimer: Timer?

  /// 最近一次「样本真正进了图层」的时刻。
  ///
  /// 保活通道据此判断是否真的需要补帧：渲染回调要是正常在供帧，就一次都不该补。
  private var lastLayerEnqueueAt: CFTimeInterval = 0

  /// 保活通道因「渲染回调仍在正常供帧」而主动跳过的次数（诊断用）。
  private var statKeepAliveSkipped = 0

  /// 小窗开始显示的时刻；`0` 表示当前未显示。
  private var showingSince: CFTimeInterval = 0

  /// [noteCopyNil] 记录：渲染回调在跑、却取不到像素缓冲的次数。
  private var statCopyNil = 0

  /// 保活定时器实际触发次数。
  private var statTimerTicks = 0

  /// 播放类音频会话是否已成功激活（记录最近一次激活尝试的结果）。
  ///
  /// 画中画要求 App 持有活跃的播放类会话；后台态下激活可能失败，而系统此时可能
  /// 只给出一个「有框无画面」的小窗。纳入诊断，便于把这第二种成因与图层问题区分开。
  /// 注：`AVAudioSession` 没有公开 API 能查询「当前是否活跃」，因此只能记自己那
  /// 一次 `setActive(true)` 的结果。
  private var audioSessionActive = false

  /// 最近一次激活音频会话时，系统是否报告「另有音频在播放」。
  /// 为真说明会话正被别的 App 占着，这本身就可能导致小窗拿不到画面。
  private var audioOtherPlaying = false

  /// 因图层「需要先清空队列才能恢复解码」而主动 flush 的次数。
  private var statResumeFlush = 0

  /// 最近一次「恢复冲洗」的时刻，用于限制冲洗频率。
  private var lastResumeFlush: CFTimeInterval = 0

  /// 由主线程维护的「系统是否认为可以画中画」缓存。
  ///
  /// 渲染线程要把它画进诊断叠加层，而 `AVPictureInPictureController` 的属性只能在
  /// 主线程访问，故在这里存一份快照。
  private var possibleCache = false

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
  /// `startPictureInPicture()`，因此这里不赌「点按那一刻条件已经成立」，而是走一条
  /// 最短 3 秒的重试阶梯（见 [_attemptStart]）：期间反复确认可用性、把画面源扶正、
  /// 补一帧最新画面。阶梯走完仍不可用，就把具体读数报出来，而不是留下一个
  /// 「点了没反应」的黑盒。
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
    resetDiagnostics()
    hostSide = lastGoodHostSide
    startTries = 0
    startDeadline = CACurrentMediaTime() + 3.0
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self._attemptStart()
    }
  }

  /// 单次启动尝试；条件不成立则在阶梯时限内续期重试。必须在主线程调用。
  @available(iOS 15.0, *)
  private func _attemptStart() {
    // 已被 [stop] / [disarm] 取消。
    guard startDeadline > 0 else {
      return
    }
    guard let controller = _ensureController() else {
      return
    }
    possibleCache = controller.isPictureInPicturePossible
    if controller.isPictureInPictureActive {
      startDeadline = 0
      return
    }

    if controller.isPictureInPicturePossible {
      startDeadline = 0
      controller.startPictureInPicture()
      return
    }

    startTries += 1

    // 系统还不认这个画面源：重新挂一次（保证它确实在最前、且被判定为可见），
    // 图层状态异常时清掉，并补一帧最新画面。
    attachDisplayLayer()
    if displayLayer.status == .failed {
      displayLayer.flush()
    }
    onNeedFrame?(true)

    // 宿主视图平时只有 2 点见方；个别系统版本对画面源的尺寸判定更严，迟迟不就绪
    // 时放大一档（对已经就绪的设备没有任何影响）。
    if startTries >= 2, hostSide < 64 {
      hostSide = hostSide < 24 ? 24 : 64
      // 与放大同步把不透明度提回来：万一「近乎全透明」在个别机型上被判成
      // 「画面源不可见」，这一步就是兜底。小窗弹出后 [didStart] 会立刻降回去。
      hostView.alpha = 1
      attachDisplayLayer()
    }

    if CACurrentMediaTime() < startDeadline {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        guard let self = self else { return }
        self._attemptStart()
      }
      return
    }

    // 阶梯走到尽头：把判断依据一并报出来，免得又只能靠猜。
    emitError(
      "画中画启动失败：画面源未就绪（出帧 \(statAttempt)、入队 \(statEnqueued) 帧、"
        + "图层 \(layerStatusText())、就绪 \(displayLayer.isReadyForMoreMediaData)、"
        + "已挂入层级 \(hostView.window != nil)、App \(appStateText())）"
    )
    hostSide = lastGoodHostSide
    attachDisplayLayer()
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
    hostSide = lastGoodHostSide
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard let controller = self._ensureController() else {
        return
      }
      controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
      // 自动进入（划回主屏幕）走的是系统的判定，同样要求图层里「有内容」；
      // 这里先补一帧，免得用户划出去时系统还在等第一帧。
      self.onNeedFrame?(true)
    }
  }

  /// 关闭画中画小窗，但**保持画面源可用**。
  ///
  /// 用户可以随时再次点按「画中画」按钮，或划回主屏幕让系统自动进入；若此处
  /// 一并解除武装，下一次进入的小窗就会是黑屏。
  public func stop() {
    guard #available(iOS 15.0, *) else {
      return
    }
    // 用户已经收起小窗，正在进行的启动重试必须一并作罢，否则它会随后把
    // 小窗重新弹出来。
    startDeadline = 0
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // 取消可能半途而废的启动阶梯留下的「提亮」状态。
      self.hostView.alpha = PictureInPicture.hostIdleAlpha
      self.stopKeepAlive()
      self.pipController?.stopPictureInPicture()
    }
  }

  /// 不再向系统提供画中画画面源。仅用于释放前的收尾。
  public func disarm() {
    isArmed = false
    isShowing = false
    lastPosition = -1
    lastIdleEnqueue = 0
    startDeadline = 0
    showingSince = 0
    DispatchQueue.main.async { [weak self] in
      self?.hostView.alpha = PictureInPicture.hostIdleAlpha
      self?.stopKeepAlive()
    }
  }

  /// 为「换了视频源」做准备（连播下一集、切换清晰度、换源等）。
  ///
  /// 新视频的播放位置从 0 开始，而图层时间轴此前已推进到上一集的位置；时间轴
  /// 倒退会让 `AVSampleBufferDisplayLayer` 停止消化后续样本，表现即「App 里画面
  /// 正常、小窗一直黑」。这里清空图层与时间轴，并丢掉上一集的弹幕，
  /// 控制器本身保持不动，因此小窗会在下一帧到来后无缝接上新视频。
  public func prepareForNewMedia() {
    danmaku.clear()
    lastPosition = -1
    lastIdleEnqueue = 0

    let layer = displayLayer
    let timebase = controlTimebase
    DispatchQueue.main.async {
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
    guard #available(iOS 15.0, *) else {
      DispatchQueue.main.async {
        layer.removeFromSuperlayer()
        host.removeFromSuperview()
      }
      return
    }

    let controller = pipController
    pipController = nil
    DispatchQueue.main.async {
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
  private func _ensureController() -> AVPictureInPictureController? {
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
    statAttempt += 1

    guard isArmed else {
      statNotArmed += 1
      return
    }

    // 图层尚未消化完上一帧时直接丢弃，避免堆积与卡顿。
    let layer = displayLayer
    if !layer.isReadyForMoreMediaData {
      statNotReady += 1
      if !force {
        // 小窗已经显示、图层却长时间不肯接收样本：多半是早先那批样本卡在队列里
        // （时间轴倒退、或渲染在后台被挂起），此时队列永远不会自己腾空。主动清一次，
        // 把管道重新打通，否则小窗会一直停在黑屏。
        let now = CACurrentMediaTime()
        if isShowing {
          if notReadySince == 0 {
            notReadySince = now
          } else if now - notReadySince > 1.0, now - lastStuckFlush > 2.0 {
            lastStuckFlush = now
            notReadySince = 0
            NSLog("PictureInPicture: layer stuck, flushing")
            DispatchQueue.main.async {
              layer.flush()
            }
          }
        }
        return
      }
      // force：下面在主线程先清队列、再入队，保证这一帧一定进得去。
    }
    notReadySince = 0

    if !isShowing, !force {
      // 小窗还没显示：仍要维持图层里有画面——系统正是据此判断「有内容可以画中画」，
      // 否则划回主屏幕时不会自动进入。但降到约 10 fps，避免长时间占住 Flutter
      // 那几个轮转使用的像素缓冲。
      let now = CACurrentMediaTime()
      if now - lastIdleEnqueue < 0.1 {
        statThrottled += 1
        return
      }
      lastIdleEnqueue = now
    }

    // 当前播放位置：既用于校准小窗进度条，也用于确定这一帧该显示哪些弹幕。
    let position = mpvPosition()
    if lastPosition >= 0, position < lastPosition - 1 {
      // 播放位置大幅倒退说明换了视频源；时间轴倒退会让图层停止消化后续样本。
      DispatchQueue.main.async {
        layer.flush()
      }
    }
    lastPosition = position
    syncTimebase(position)

    // 有弹幕落在画面上时，先绘进帧的副本；否则直接使用原始帧（零额外开销）。
    // 只有小窗真的显示出来了才绘制——仅仅「武装」了自动画中画时不应白白耗电。
    var frame = pixelBuffer
    if isShowing, danmaku.enabled,
      danmaku.isActive(at: position),
      let composed = danmaku.composite(pixelBuffer, at: position)
    {
      frame = composed
    }
    // 诊断叠加层：开机时把读数自身画进小窗。小窗里看得到这些字，就说明帧确实送到了
    // 图层，黑屏发生在「系统把图层内容接进小窗」那一环；一片纯黑连字也没有，则说明
    // 帧压根没送进去。这是零成本区分两类成因的办法（仅诊断时开启）。
    if debugOverlay.enabled,
      let composed = debugOverlay.composite(frame, lines: debugLines(frame))
    {
      frame = composed
    }

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

    statEnqueued += 1
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      // 后台态（例如 App 被另一个进程托管、自己始终处于后台）下，图层可能进入
      // 「需要先清空队列才能恢复解码」的状态。此时若直接入队，样本会被图层静默地
      // 丢掉 —— 现象恰好是「入队数一直涨、小窗始终黑」。此处按官方文档给出的做法
      // 先 flush 再入队；两者都投在同一条主队列上，先后顺序有保证。
      let now = CACurrentMediaTime()
      let resumeFlush =
        layer.requiresFlushToResumeDecoding && now - self.lastResumeFlush > 0.2
      if layer.status == .failed
        || resumeFlush
        || (force && !layer.isReadyForMoreMediaData)
      {
        if resumeFlush {
          self.statResumeFlush += 1
        }
        self.lastResumeFlush = now
        layer.flush()
      }
      layer.enqueue(sampleBuffer)
      // 记在主线程序列上：保活定时器也在主线程读它，这样读写天然串行，不需要加锁。
      self.lastLayerEnqueueAt = CACurrentMediaTime()
    }
  }

  // MARK: - 弹幕

  /// 开启 / 关闭画中画弹幕。关闭后所有帧都按原样送入小窗。
  public func setDanmakuEnabled(_ value: Bool) {
    danmaku.enabled = value
  }

  /// 开启 / 关闭「画面内诊断叠加层」（排障用，读数会直接画进小窗）。
  public func setDebugOverlayEnabled(_ value: Bool) {
    debugOverlay.enabled = value
  }

  /// 下发弹幕显示参数（字号缩放、透明度、滚动时长等），与 App 内的弹幕设置保持一致。
  public func setDanmakuConfig(_ config: [String: Any]) {
    if let value = config["opacity"] as? NSNumber {
      danmaku.opacity = CGFloat(max(0, min(1, value.doubleValue)))
    }
    if let value = config["fontScale"] as? NSNumber {
      danmaku.fontScale = CGFloat(max(0.35, min(4, value.doubleValue)))
    }
    if let value = config["lineHeight"] as? NSNumber {
      danmaku.lineHeightScale = CGFloat(max(0.5, min(3, value.doubleValue)))
    }
    if let value = config["area"] as? NSNumber {
      danmaku.area = CGFloat(value.doubleValue)
    }
    if let value = config["duration"] as? NSNumber {
      danmaku.duration = max(1, value.doubleValue)
    }
    if let value = config["staticDuration"] as? NSNumber {
      danmaku.staticDuration = max(0.5, value.doubleValue)
    }
    if let value = config["strokeWidth"] as? NSNumber {
      danmaku.strokeWidth = CGFloat(value.doubleValue)
    }
    if let value = config["hideScroll"] as? NSNumber {
      danmaku.hideScroll = value.boolValue
    }
    if let value = config["hideTop"] as? NSNumber {
      danmaku.hideTop = value.boolValue
    }
    if let value = config["hideBottom"] as? NSNumber {
      danmaku.hideBottom = value.boolValue
    }
  }

  /// 追加一批弹幕。同一 `id` 只入库一次，因此拖动进度条后重复下发不会重影。
  public func addDanmaku(_ items: [[String: Any]]) {
    danmaku.append(items)
  }

  public func clearDanmaku() {
    danmaku.clear()
  }

  // MARK: - 诊断

  /// 重置诊断计数（每次真正发起 / 进入画中画时调用）。
  private func resetDiagnostics() {
    statAttempt = 0
    statEnqueued = 0
    statNotReady = 0
    statNotArmed = 0
    statThrottled = 0
    statCopyNil = 0
    statTimerTicks = 0
    statKeepAliveSkipped = 0
    statResumeFlush = 0
    notReadySince = 0
    lastStuckFlush = 0
    lastResumeFlush = 0
  }

  /// 供画面内诊断叠加层显示的一行行读数。
  ///
  /// 在渲染线程上调用，因此只读线程安全的缓存值与计数，不去碰
  /// `AVPictureInPictureController` 的属性（那些只能在主线程访问）。
  private func debugLines(_ frame: CVPixelBuffer) -> [String] {
    let layer = displayLayer
    let size = "\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
    return [
      "帧入图层 \(statEnqueued)/\(statAttempt)",
      "拒收 \(statNotReady) · 恢复冲洗 \(statResumeFlush) · 就绪 \(layer.isReadyForMoreMediaData ? 1 : 0)",
      "小窗 \(isShowing ? 1 : 0) · 武装 \(isArmed ? 1 : 0) · 可画 \(possibleCache ? 1 : 0) · 声 \(audioSessionActive ? 1 : 0)/\(audioOtherPlaying ? 1 : 0)",
      "保活 \(statTimerTicks) · \(size)",
    ]
  }

  /// 图层当前状态的文字描述（用于日志与诊断）。
  private func layerStatusText() -> String {
    switch displayLayer.status {
    case .failed:
      return "failed"
    case .rendering:
      return "rendering"
    default:
      return "unknown"
    }
  }

  /// App 当前运行状态的文字描述（用于诊断）。**必须在主线程调用**。
  private func appStateText() -> String {
    switch UIApplication.shared.applicationState {
    case .active:
      return "active"
    case .inactive:
      return "inactive"
    case .background:
      return "background"
    default:
      return "unknown"
    }
  }

  /// 诊断快照：用于判断「小窗黑屏」断在哪一环。**必须在主线程调用**
  /// （内部会读取 `AVPictureInPictureController` 与图层的状态）。
  public func diagnostics() -> [String: Any] {
    let layer = displayLayer
    possibleCache = pipController?.isPictureInPicturePossible ?? false
    var rate: Double = -1
    if #available(iOS 15.0, *), let timebase = controlTimebase {
      rate = CMTimebaseGetRate(timebase)
    }
    // 画面源在窗口里的落点与窗口自身尺寸：用于排查「贴边被裁掉、系统不认可见性」。
    var hostOrigin = "nil"
    var windowBounds = "nil"
    if let window = hostView.window {
      hostOrigin = "\(Int(hostView.frame.minX)),\(Int(hostView.frame.minY))"
      windowBounds = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
    }
    return [
      "supported": PictureInPicture.isSupported,
      "armed": isArmed,
      "showing": isShowing,
      "possible": isPossible,
      "attempt": statAttempt,
      "enqueued": statEnqueued,
      "notReady": statNotReady,
      "notArmed": statNotArmed,
      "throttled": statThrottled,
      "copyNil": statCopyNil,
      "timerTicks": statTimerTicks,
      "keepAliveSkipped": statKeepAliveSkipped,
      "resumeFlush": statResumeFlush,
      "sinceShow": showingSince > 0 ? CACurrentMediaTime() - showingSince : -1,
      "startTries": startTries,
      "hostSide": Double(hostSide),
      // 画面源是否真的挂进了窗口（false = 被移除或窗口还没就绪）。
      "hostAttached": hostView.window != nil,
      "hostOrigin": hostOrigin,
      "windowBounds": windowBounds,
      "appState": appStateText(),
      "audioActive": audioSessionActive,
      "audioOtherPlaying": audioOtherPlaying,
      "layerStatus": layerStatusText(),
      "layerReady": layer.isReadyForMoreMediaData,
      "layerHidden": layer.isHidden,
      "paused": mpvFlag("pause"),
      "position": mpvPosition(),
      "timebaseRate": rate,
    ]
  }

  // MARK: - 内部

  /// 激活播放类音频会话。
  ///
  /// 画中画要求 App 持有活跃的播放类音频会话；会话被抢占、或类别被改动过时，
  /// 系统可能只给出一个没有画面的小窗。除创建控制器时之外，小窗真正开始显示时
  /// 再补一次——那正是系统开始接管渲染的时刻。
  private func activateAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
      audioSessionActive = true
      audioOtherPlaying = session.isOtherAudioPlaying
    } catch {
      audioSessionActive = false
      NSLog("PictureInPicture: AVAudioSession error: \(error)")
    }
  }

  /// 小窗显示期间重试激活音频会话。必须在主线程调用。
  ///
  /// 后台态下第一次激活可能失败（被抢占、或会话正在切换），过一会儿再试一次即可。
  private func retryAudioSession(_ attempts: [Double]) {
    guard let delay = attempts.first else {
      NSLog("PictureInPicture: audio session still inactive")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self = self else { return }
      if self.audioSessionActive {
        return
      }
      self.activateAudioSession()
      if !self.audioSessionActive {
        self.retryAudioSession(Array(attempts.dropFirst()))
      }
    }
  }

  /// 小窗显示期间启动一条低速补帧通道（15 fps）。必须在主线程调用。
  ///
  /// 正常路径由媒体渲染回调驱动；这条通道只是兜底：万一渲染回调长时间不来，
  /// 图层仍能持续拿到画面，小窗不至于停在黑屏。重复调用不会叠加定时器。
  private func startKeepAlive() {
    stopKeepAlive()
    let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
      guard let self = self, self.isArmed else {
        self?.stopKeepAlive()
        return
      }
      // 只在「渲染回调确实没在供帧」时才补。正常路径下渲染回调每渲染完一帧就会把样本
      // 送进图层，这条通道因此几乎不会真的触发——它是兜底，不该变成一条常驻的固定频率
      // 生产者：那会把 worker 的队列、以及整机的 CPU 与内核对象一起拖住，跑得越久越糟。
      if CACurrentMediaTime() - self.lastLayerEnqueueAt < 0.2 {
        self.statKeepAliveSkipped += 1
        return
      }
      self.statTimerTicks += 1
      self.onNeedFrame?(false)
    }
    // 用 .common 模式：界面滚动或有其它追踪行为时定时器也不会停摆。
    RunLoop.main.add(timer, forMode: .common)
    keepAliveTimer = timer
  }

  /// 停止低速补帧通道。
  private func stopKeepAlive() {
    keepAliveTimer?.invalidate()
    keepAliveTimer = nil
  }

  /// 记录一次「渲染回调在跑，但取不到像素缓冲」（由 `VideoOutput` 在补帧时调用）。
  public func noteCopyNil() {
    statCopyNil += 1
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
  private func attachDisplayLayer() {
    guard let window = PictureInPicture.keyWindow else {
      NSLog("PictureInPicture: key window not found")
      return
    }

    // 只在极小的可见区域内显示（约几个像素），因此不会影响应用内观感。
    // 位置取窗口正中：这样无论窗口是铺满屏幕、还是被宿主进程以「场景托管」的方式
    // 嵌在它自己的窗口里（此时可见区域与全屏并不一致），画面源都必定落在可见范围
    // 之内，不会因为贴边而落到被裁掉的区域上。
    // 尺寸取 [hostSide]：默认 2 点，仅当启动阶梯发现「迟迟不就绪」时才放大。
    let side = hostSide
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
    mpv_command_string(
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
    startDeadline = 0
    lastGoodHostSide = hostSide
    // 启动阶梯可能为了兜底把它提亮过；小窗已经在外面显示，屏幕上不该再留这个小点。
    hostView.alpha = PictureInPicture.hostIdleAlpha
    possibleCache = pipController?.isPictureInPicturePossible ?? true
    resetDiagnostics()
    showingSince = CACurrentMediaTime()
    attachDisplayLayer()
    // 启动阶段为了「让系统判定画面源可用」补过几帧，那批样本的时间戳与队列状态
    // 未必干净；小窗真正开始接管画面时清一次队列，让随后送进来的帧从头开始。
    if displayLayer.status == .failed
      || displayLayer.requiresFlushToResumeDecoding
      || !displayLayer.isReadyForMoreMediaData
    {
      displayLayer.flush()
    }
    lastPosition = -1
    lastIdleEnqueue = 0
    // 小窗刚开始显示时先当作「刚刚送到过帧」，让保活通道安静下来；渲染回调一旦真的
    // 断了供帧，超过 0.2 秒它自然会接手。
    lastLayerEnqueueAt = CACurrentMediaTime()
    // 系统正是从这一刻开始接管画面。两件事必须补齐：音频会话要活跃（否则小窗
    // 可能只有框没有画面），以及一条兜底的补帧通道（万一渲染回调不来）。
    activateAudioSession()
    // 后台态下第一次激活可能不成，补一条重试阶梯。
    if !audioSessionActive {
      retryAudioSession([0.5, 1.5, 3.0])
    }
    startKeepAlive()
    // 立即补一帧，别等下一次渲染回调或保活定时器。
    onNeedFrame?(true)
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": true])
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isShowing = false
    showingSince = 0
    stopKeepAlive()
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": false])
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    startDeadline = 0
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
