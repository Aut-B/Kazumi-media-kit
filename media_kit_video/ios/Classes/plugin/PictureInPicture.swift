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
  /// 补帧通道自己的串行队列与定时源。
  ///
  /// 原先用 `Timer` 挂在主 RunLoop 上：App 退到后台后主 RunLoop 的定时器会被系统
  /// 降频甚至停摆，补帧通道随之哑火——表现正是「一划回主屏幕，小窗就定在那一帧」。
  /// 改用独立队列上的 `DispatchSourceTimer`：只要进程还在跑，它就一定按节奏触发。
  private let keepAliveQueue = DispatchQueue(
    label: "media_kit.pip.keepalive",
    qos: .userInitiated
  )
  private var keepAliveSource: DispatchSourceTimer?

  /// 图层操作专用串行队列。
  ///
  /// `AVSampleBufferDisplayLayer` 的 `enqueue` / `flush` 可以在任意线程调用（只要串行）。
  /// 原先统一投到主队列：App 退到后台后主队列会被系统降频甚至挂起，样本于是再也进不了
  /// 图层 —— 小窗就停在划走前的最后一帧。改到自己的串行队列后，喂帧链路完全不再依赖
  /// 主线程，前台 / 后台的行为也就一致了。
  private let layerQueue = DispatchQueue(
    label: "media_kit.pip.layer",
    qos: .userInitiated
  )

  /// 最近一次「按 controller 真实状态纠正 isShowing」的时刻（限频用）。
  private var lastReconcile: CFTimeInterval = 0

  /// App 是否已退到后台（主线程维护，供补帧通道跨线程读取）。
  private var appIsBackground = false

  /// App 是否已退到后台。供 `VideoOutput` 判断喂帧 / 通知策略：后台态下主线程随时
  /// 可能被系统降频，任何「等主线程」的操作都必须绕开。
  public var isAppBackground: Bool {
    return appIsBackground
  }

  /// 退到后台后向系统申请的续命任务：保证「小窗弹出来」这段时间进程不会被挂起。
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  /// 最近一次「样本真正进了图层」的时刻。
  ///
  /// 保活通道据此判断是否真的需要补帧：渲染回调要是正常在供帧，就一次都不该补。
  /// 保活通道已经挪到独立队列上，这条读数会被两个线程同时访问，读写统一加锁。
  private let enqueueLock = NSLock()
  private var _lastLayerEnqueueAt: CFTimeInterval = 0

  private var lastLayerEnqueueAt: CFTimeInterval {
    get {
      enqueueLock.lock()
      defer { enqueueLock.unlock() }
      return _lastLayerEnqueueAt
    }
    set {
      enqueueLock.lock()
      _lastLayerEnqueueAt = newValue
      enqueueLock.unlock()
    }
  }

  /// 保活通道因「渲染回调仍在正常供帧」而主动跳过的次数（诊断用）。
  private var statKeepAliveSkipped = 0

  /// 小窗开始显示的时刻；`0` 表示当前未显示。
  private var showingSince: CFTimeInterval = 0

  /// [noteCopyNil] 记录：渲染回调在跑、却取不到像素缓冲的次数。
  private var statCopyNil = 0

  /// 保活定时器实际触发次数。
  private var statTimerTicks = 0

  /// 保活通道发现「图层长时间没有新样本」并强制补帧的次数。
  private var statStallRecover = 0

  /// 后台「进度不走」看门狗主动重推播放的次数（诊断用）。
  ///
  /// 15pm 上出现过一种与 6S 完全不同的卡法：帧以 30fps 稳定送进图层、内容甚至还在
  /// 变，但 mpv 的 `time-pos` 一秒都不动 —— 播放循环本身被挂起了（多半卡在音频
  /// 输出上），小窗因此定在某一帧。这个计数用来确认看门狗有没有真的出手。
  private var statStallNudge = 0

  /// 看门狗上一次采样到的播放位置与时刻（`-1` 表示尚未采样）。
  private var stallWatchPosition: Double = -1
  private var stallWatchAt: CFTimeInterval = 0

  /// 上一次重推播放的时刻（限频用）。
  private var lastStallNudge: CFTimeInterval = 0

  /// 「已武装、后台里却没有任何小窗迹象」的起点时刻（`0` 表示未在等待）。
  private var rebuildWaitSince: CFTimeInterval = 0

  /// 控制器重建次数（6S 僵死窗口自愈用）。
  private var statControllerRebuild = 0

  /// 补帧时 mpv 渲染没产出新画面的次数（轮转缓冲被占满等）。
  private var statRenderNil = 0

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

  // MARK: - 累计计数（不随单次启动清零）
  //
  // 面板读数只能在回到前台之后读：那时 `showing` 必然为 false，单次计数又已被
  // `resetDiagnostics()` 清过，于是永远看不出后台那一段的真相。下面这几个计数只在
  // [start] / [arm] 时归零，专门回答「系统到底有没有送 didStart」这类关键问题。

  private var statDidStart = 0
  private var statDidStop = 0
  private var statReconcileTry = 0
  private var statReconcileHit = 0
  private var statBgEnqueued = 0
  private var statFgEnqueued = 0
  private var statStartCalls = 0
  private var statStartFail = 0

  /// 连续两次入队的画面内容完全相同（签名一致）的次数。
  ///
  /// 这是区分「帧确实进了图层、但内容是同一帧」与「内容在变、图层却没显示」的唯一
  /// 依据：前者说明渲染 / mpv 侧没出新画面，后者说明问题在小窗那一环。
  private var statSameFrame = 0
  private var lastFrameSignature: UInt64 = 0
  private var hasFrameSignature = false

  /// 因为「内容和上一帧完全一样」而主动跳过入队的次数。
  ///
  /// 后台补帧在画面停住时会把同一帧反复送进图层，图层每收一次就要重推一次
  /// IOSurface —— 15pm 上那条红光 / 频闪就是这么来的。内容没变就不必再送。
  private var statDuplicateSkip = 0

  /// 送进小窗的帧要复制到自有缓冲池，不能直接把 GL 的轮转 IOSurface 交出去。
  ///
  /// `TextureHW` 只有三块轮转缓冲，mpv 每帧都往里写；而
  /// `AVSampleBufferDisplayLayer` 是在系统进程里异步读的。直接把轮转缓冲交出去，
  /// 图层读到的可能就是「正在被写」的那一块 —— 15pm 上表现为画面频闪 / 整片发红，
  /// 6S 上表现为反复同一帧。复制一份到自有缓冲就彻底解耦。
  private var framePool: CVPixelBufferPool?
  private var framePoolWidth = 0
  private var framePoolHeight = 0

  /// 「上一次后台窗口期」的汇总。卡帧只发生在这一段，而读数只能在回前台后取，
  /// 所以必须在这里把起点与基线记下来，否则面板永远是「小窗没在显示」。
  private var bgSegmentStart: CFTimeInterval = 0
  private var lastBgSeconds: Double = 0
  private var lastBgEnqueued: Int = 0
  private var lastBgSameFrame: Int = 0
  private var lastBgPosition: Double = 0
  private var lastBgDidStart: Int = 0
  private var lastBgStartCalls: Int = 0
  private var bgBaseEnqueued = 0
  private var bgBaseSameFrame = 0
  private var bgBaseDidStart = 0
  private var bgBaseStartCalls = 0
  private var bgBasePosition: Double = 0

  /// 由主线程维护的「系统是否认为可以画中画」缓存。
  ///
  /// 渲染线程要把它画进诊断叠加层，而 `AVPictureInPictureController` 的属性只能在
  /// 主线程访问，故在这里存一份快照。
  private var possibleCache = false

  init(handle: OpaquePointer, eventCallback: @escaping EventCallback) {
    self.handle = handle
    self.eventCallback = eventCallback
    super.init()
    // 前后台切换是「小窗卡在某一帧」的唯一分水岭，必须在这里补一次：
    // 进入后台时把音频会话、补帧通道、续命任务一并扶正；回到前台时释放续命任务。
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  @objc private func handleDidEnterBackground() {
    appIsBackground = true
    beginBackgroundSegment()
    // 新的一段后台窗口期：看门狗与「重建等待」都从零开始。
    stallWatchPosition = -1
    stallWatchAt = 0
    lastStallNudge = 0
    rebuildWaitSince = 0
    guard isArmed else {
      return
    }
    // 后台态下音频会话可能已被系统降级，重新扶一次；会话不活跃时进程更容易被挂起。
    activateAudioSession()
    if !audioSessionActive {
      retryAudioSession([0.5, 1.5, 3.0])
    }
    beginBackgroundTaskIfNeeded()
    startKeepAlive()
    // 小窗已经在显示时，系统会在切到后台的瞬间让图层暂停消化队列里的样本：队列
    // 看起来还是满的、`isReadyForMoreMediaData` 也可能一直不恢复，小窗就定在最后
    // 一帧。主动清一次队列并把时间轴拉回当前播放位置，让新帧从头开始进。
    //
    // 这里原先只认 `isShowing`。6S 上系统自动建窗时既不送 didStart、controller
    // 也一直报 inactive，`isShowing` 恒为 false —— 于是这段恢复一次都没跑过，
    // 图层从切后台那一刻起就卡住。已武装就一律恢复。
    if isShowing || isArmed {
      let layer = displayLayer
      let timebase = controlTimebase
      let resumeAt = mpvPosition()
      let resumeRate: Double = mpvFlag("pause") ? 0 : 1
      layerQueue.async {
        layer.flush()
        if #available(iOS 15.0, *), let timebase = timebase {
          CMTimebaseSetTime(
            timebase,
            time: CMTime(seconds: resumeAt, preferredTimescale: 600)
          )
          if CMTimebaseGetRate(timebase) != resumeRate {
            CMTimebaseSetRate(timebase, rate: resumeRate)
          }
        }
      }
    }
    // `inactive` 只给了零点几秒，很多情况下那一刻 `isPictureInPicturePossible`
    // 还是 false，前台那次启动就这么废了。真正进到后台时再补一次：此时后台续命
    // 任务已经拿到，阶梯可以完整跑完 —— 这是 6S 上最后缺的那一环。
    if #available(iOS 15.0, *), !isShowing {
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.isArmed, !self.isShowing else { return }
        self.startTries = 0
        self.startDeadline = CACurrentMediaTime() + 6.0
        self._attemptStart()
      }
    }
    // 立刻补一帧：后台切换的瞬间系统最容易把渲染回调掐掉。
    onNeedFrame?(true)
  }

  @objc private func handleWillEnterForeground() {
    appIsBackground = false
    endBackgroundSegment()
    endBackgroundTaskIfNeeded()
    stallWatchPosition = -1
    stallWatchAt = 0
    lastStallNudge = 0
    rebuildWaitSince = 0
  }

  /// 申请一个后台续命任务（约 30 秒，够系统把画中画窗口建起来）。
  private func beginBackgroundTaskIfNeeded() {
    guard backgroundTask == .invalid else {
      return
    }
    backgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "media_kit.pip.keepalive"
    ) { [weak self] in
      self?.endBackgroundTaskIfNeeded()
    }
  }

  /// 释放后台续命任务。
  private func endBackgroundTaskIfNeeded() {
    guard backgroundTask != .invalid else {
      return
    }
    let identifier = backgroundTask
    backgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(identifier)
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

  /// 当前是否要求「等 GPU 把这一帧写完再取」。
  ///
  /// 只有小窗真的在用这块画面时才需要：前台正常播放走同步渲染会拖慢 6S。
  /// `startDeadline > 0` 覆盖启动阶梯那几秒 —— 那几帧是系统判定「有没有内容」
  /// 的依据，必须干净。
  public var needsSynchronizedFrame: Bool {
    return isArmed && (isShowing || appIsBackground || startDeadline > 0)
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
    resetCumulative()
    hostSide = lastGoodHostSide
    startTries = 0
    // 3 秒不够。`inactive` 到真正进后台之间只有零点几秒，系统一冻住主队列，
    // 原来的重试阶梯就永远走不完（6S 读数里「前台进小窗 N 次 / 启动调用 0」）。
    // 现在先把后台续命任务拿到手，阶梯拉长到 8 秒 —— 续命期内主队列还在跑，
    // 足够等到 `isPictureInPicturePossible` 变真。
    startDeadline = CACurrentMediaTime() + 8.0
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // 这四步以前要等第一次 `_attemptStart` 才做，而那时可能已经在后台了。
      // 提到最前面：音频会话、续命任务、补帧通道、画面源一次到位。
      self.activateAudioSession()
      self.beginBackgroundTaskIfNeeded()
      self.attachDisplayLayer()
      self.onNeedFrame?(true)
      self.startKeepAlive()
      self._attemptStart()
    }
  }

  /// 安排下一次启动尝试。
  ///
  /// 不能用 `DispatchQueue.main.asyncAfter`：App 已经在往后台走的时候主队列会被
  /// 系统冻住，那个 block 永远不执行 —— 6S 上「前台进小窗 2 次、启动调用 0」
  /// 就是这么来的。改投一条独立串行队列，到点再回主线程执行。
  @available(iOS 15.0, *)
  private func scheduleStartRetry() {
    PictureInPicture.startRetryQueue.asyncAfter(deadline: .now() + 0.35) {
      [weak self] in
      guard let self = self else { return }
      DispatchQueue.main.async {
        self._attemptStart()
      }
    }
  }

  private static let startRetryQueue = DispatchQueue(
    label: "media_kit.pip.start-retry"
  )

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
      statStartCalls += 1
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
      scheduleStartRetry()
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
    // 手动这条路没走通：把「切后台时由系统自己弹窗」重新打开当兜底。
    // 两条路都留着，总比屏幕上什么都没有强。
    pipController?.canStartPictureInPictureAutomaticallyFromInline = true
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
    resetCumulative()
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
      // 补帧通道在「武装」阶段就架好：自动进入画中画时 `didStart` 可能要到 App
      // 已经退到后台才送达，那时再挂定时器就晚了。通道内部只在「小窗已显示」或
      // 「App 已在后台」时才真正补帧，前台正常播放时它一次都不会插手。
      if autoEnter {
        self.startKeepAlive()
      }
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
    lastReconcile = 0
    DispatchQueue.main.async { [weak self] in
      self?.hostView.alpha = PictureInPicture.hostIdleAlpha
      self?.stopKeepAlive()
      self?.endBackgroundTaskIfNeeded()
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
    // 与 `enqueue` 投同一条串行队列：既保证「先清空、再入队新视频的帧」这个顺序，
    // 也让切集不再依赖主线程 —— App 停在小窗里连续播放时，主线程随时可能被降频，
    // 一旦这一步跑不到，新视频的帧就会顶在上一集的时间轴上，小窗随即变黑。
    layerQueue.async {
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

    if let controller = pipController {
      // 控制器已建好：只有图层真的掉了才补挂。无条件 `attachDisplayLayer()` 会在
      // 后台把图层从小窗窗口里抢回宿主视图，小窗立刻定格。
      if displayLayer.superlayer == nil {
        attachDisplayLayer()
      }
      return controller
    }

    attachDisplayLayer()
    setupTimebase()

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
  public func enqueue(
    _ pixelBuffer: CVPixelBuffer,
    force: Bool = false,
    synchronized: Bool = false
  ) {
    guard #available(iOS 15.0, *) else {
      return
    }
    statAttempt += 1
    if appIsBackground {
      statBgEnqueued += 1
    } else {
      statFgEnqueued += 1
    }

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
        // 这里原来只认 isShowing。自动进小窗（划回主屏幕）时系统经常不送
        // didStart，isShowing 一直是 false，于是「图层不肯收样本」这件事
        // 一次都不会被恢复——小窗就永远停在那一帧。后台态同样算「小窗在用」。
        if isShowing || appIsBackground {
          if notReadySince == 0 {
            notReadySince = now
          } else if now - notReadySince > 1.0, now - lastStuckFlush > 2.0 {
            lastStuckFlush = now
            notReadySince = 0
            NSLog("PictureInPicture: layer stuck, flushing")
            // 光清图层不够：卡住时时间轴往往已经跑到样本前面，清完又被
            // 旧时间轴卡一次。顺手把时间轴拉回当前播放位置。
            let resumeAt = mpvPosition()
            let resumeRate: Double = mpvFlag("pause") ? 0 : 1
            layerQueue.async { [weak self] in
              layer.flush()
              if #available(iOS 15.0, *), let timebase = self?.controlTimebase {
                CMTimebaseSetTime(
                  timebase,
                  time: CMTime(seconds: resumeAt, preferredTimescale: 600)
                )
                if CMTimebaseGetRate(timebase) != resumeRate {
                  CMTimebaseSetRate(timebase, rate: resumeRate)
                }
              }
            }
          }
        }
        return
      }
      // force：下面在主线程先清队列、再入队，保证这一帧一定进得去。
    }
    notReadySince = 0

    if !isShowing, !force, !appIsBackground {
      // 小窗还没显示：仍要维持图层里有画面——系统正是据此判断「有内容可以画中画」，
      // 否则划回主屏幕时不会自动进入。但降到约 10 fps，避免长时间占住 Flutter
      // 那几个轮转使用的像素缓冲。
      //
      // 后台态例外：那正是「自动进入小窗」的窗口期——系统已经切走、`didStart` 还没
      // 送到，此时若把帧率压到 10 fps，小窗一弹出来就是一顿一顿的。
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
      layerQueue.async {
        layer.flush()
      }
    }
    lastPosition = position
    syncTimebase(position)

    // 画面帧原样送入图层，不再做「弹幕→帧」的逐帧合成。
    //
    // 原先的「画中画弹幕」正是在这里把弹幕绘进帧的副本：每一帧一次整帧 memcpy、新建
    // 一个 CoreGraphics 上下文、再对当前可见的每条弹幕逐条绘制文字（循环遍历最多
    // 6000 条），而源帧取自 OpenGL 纹理缓存，还要对它 `CVPixelBufferLockBaseAddress`。
    // 播放中这条路径每一帧都在跑，长时间播放会把 CPU 与内存带宽推满——现象即小窗卡死，
    // 随后整个进程连新建网络连接都失败。该功能已按用户要求整体移除，小窗只显示画面本身。
    // 与 GL 轮转缓冲解耦：复制一份自有缓冲再入队。
    //
    // 只有调用方确认「这一帧已经写完」（`renderSynchronized`）时才敢复制，
    // 否则锁住的是 GPU 正在写的内存。
    var frame = pixelBuffer
    if synchronized, let copied = copyFrame(pixelBuffer) {
      frame = copied
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

    // 「画面不换」有两种完全不同的成因：渲染出来就是同一帧，或者内容在变但图层
    // 没显示。入队前算一次内容签名，就能把两者分开。
    //
    // 只在后台窗口期取样：那时补帧走同步渲染（`renderSynchronized`），缓冲已经写完，
    // 锁基地址是安全的。前台正常播放不取样——GPU 可能还在写这块缓冲，锁它既没有
    // 意义，还可能反过来拖慢渲染。
    if appIsBackground, synchronized {
      let signature = frameSignature(pixelBuffer)
      if signature != 0 {
        if hasFrameSignature, signature == lastFrameSignature {
          statSameFrame += 1
          // 内容完全没变：再送一次只会让图层重推同一块 IOSurface。
          // 15pm 上的红光 / 频闪就是这么被放大出来的。除非是强制补帧
          // （刚清过队列、必须立刻有画面），否则直接跳过。
          if !force {
            statDuplicateSkip += 1
            return
          }
        }
        lastFrameSignature = signature
        hasFrameSignature = true
      }
    }

    statEnqueued += 1
    layerQueue.async { [weak self] in
      guard let self = self else {
        return
      }
      // 后台态（例如 App 被另一个进程托管、自己始终处于后台）下，图层可能进入
      // 「需要先清空队列才能恢复解码」的状态。此时若直接入队，样本会被图层静默地
      // 丢掉 —— 现象恰好是「入队数一直涨、小窗始终黑」。此处按官方文档给出的做法
      // 先 flush 再入队；两者都投在同一条串行队列上，先后顺序有保证。
      //
      // 注意：这条队列**不是**主队列。App 退到后台后主队列会被系统降频，样本就再也
      // 进不了图层；`AVSampleBufferDisplayLayer` 只要求调用串行，并不要求主线程。
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
      // 写在图层队列上，读的一方是补帧通道，因此这个读数带锁。
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

  /// 清零「累计」计数。只在真正发起一次画中画（[start] / [arm]）时调用。
  ///
  /// **不能**塞进 [resetDiagnostics]：`didStart` 里也会调它，那样 `didStart` 就永远
  /// 是 0，等于把最关键的读数抹掉了。
  private func resetCumulative() {
    statDidStart = 0
    statDidStop = 0
    statReconcileTry = 0
    statReconcileHit = 0
    statBgEnqueued = 0
    statFgEnqueued = 0
    statStartCalls = 0
    statStartFail = 0
    statSameFrame = 0
    statDuplicateSkip = 0
    hasFrameSignature = false
    statStallNudge = 0
    statControllerRebuild = 0
    stallWatchPosition = -1
    stallWatchAt = 0
    lastStallNudge = 0
    rebuildWaitSince = 0
  }

  /// 开始记录一段「后台窗口期」。
  private func beginBackgroundSegment() {
    bgSegmentStart = CACurrentMediaTime()
    bgBaseEnqueued = statEnqueued
    bgBaseSameFrame = statSameFrame
    bgBaseDidStart = statDidStart
    bgBaseStartCalls = statStartCalls
    bgBasePosition = mpvPosition()
  }

  /// 收尾一段「后台窗口期」，把增量存下来供回前台后的读数使用。
  private func endBackgroundSegment() {
    guard bgSegmentStart > 0 else {
      return
    }
    let snapshot = bgSnapshot()
    lastBgSeconds = snapshot.seconds
    lastBgEnqueued = snapshot.enqueued
    lastBgSameFrame = snapshot.sameFrame
    lastBgPosition = snapshot.position
    lastBgDidStart = snapshot.didStart
    lastBgStartCalls = snapshot.startCalls
    bgSegmentStart = 0
  }

  private func bgSnapshot() -> (
    seconds: Double, enqueued: Int, sameFrame: Int,
    position: Double, didStart: Int, startCalls: Int
  ) {
    if bgSegmentStart > 0 {
      return (
        CACurrentMediaTime() - bgSegmentStart,
        Swift.max(0, statEnqueued - bgBaseEnqueued),
        Swift.max(0, statSameFrame - bgBaseSameFrame),
        mpvPosition() - bgBasePosition,
        Swift.max(0, statDidStart - bgBaseDidStart),
        Swift.max(0, statStartCalls - bgBaseStartCalls)
      )
    }
    return (
      lastBgSeconds, lastBgEnqueued, lastBgSameFrame,
      lastBgPosition, lastBgDidStart, lastBgStartCalls
    )
  }

  /// 计算一帧内容的粗签名：只采样四行各 64 字节，成本可忽略。
  private func frameSignature(_ buffer: CVPixelBuffer) -> UInt64 {
    guard CVPixelBufferGetPlaneCount(buffer) == 0 else {
      return 0
    }
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
      return 0
    }
    defer {
      CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
      return 0
    }
    let height = CVPixelBufferGetHeight(buffer)
    let width = CVPixelBufferGetWidth(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard height > 0, width > 0, bytesPerRow > 0 else {
      return 0
    }
    let rowBytes = Swift.min(64, Swift.max(8, width * 4))
    let raw = base.assumingMemoryBound(to: UInt8.self)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for row in 0..<4 {
      let y = height * (row * 2 + 1) / 8
      let offset = y * bytesPerRow + (width * 4 - rowBytes) / 2
      guard offset + rowBytes <= height * bytesPerRow else {
        continue
      }
      for i in 0..<rowBytes {
        hash ^= UInt64(raw[offset + i])
        hash = hash &* 0x0000_0100_0000_01b3
      }
    }
    return hash
  }

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
    // 后台窗口期内（自动进小窗时 `didStart` 会调到这里）清零单次计数，
    // 基线要跟着挪，否则「后台入队」会算成负数。
    if bgSegmentStart > 0 {
      bgBaseEnqueued = 0
      bgBaseSameFrame = 0
      bgBaseDidStart = statDidStart
      bgBaseStartCalls = statStartCalls
      bgBasePosition = mpvPosition()
    }
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
      "保活 \(statTimerTicks)/\(statStallRecover) · 空转 \(statRenderNil) · \(size)",
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
    let segment = bgSnapshot()
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
      "stallRecover": statStallRecover,
      "renderNil": statRenderNil,
      "resumeFlush": statResumeFlush,
      "didStart": statDidStart,
      "didStop": statDidStop,
      "reconcileTry": statReconcileTry,
      "reconcileHit": statReconcileHit,
      "bgEnqueued": statBgEnqueued,
      "fgEnqueued": statFgEnqueued,
      "startCalls": statStartCalls,
      "startFail": statStartFail,
      "sameFrame": statSameFrame,
      "duplicateSkip": statDuplicateSkip,
      "stallNudge": statStallNudge,
      "controllerRebuild": statControllerRebuild,
      "layerDetached": layer.superlayer != nil
        && layer.superlayer !== hostView.layer,
      "bgSeconds": segment.seconds,
      "bgEnqueuedDelta": segment.enqueued,
      "bgSameFrameDelta": segment.sameFrame,
      "bgPositionDelta": segment.position,
      "bgDidStartDelta": segment.didStart,
      "bgStartCallsDelta": segment.startCalls,
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

  /// 启动 / 重启低速补帧通道（15 fps）。可在任意线程调用。
  ///
  /// 正常路径由媒体渲染回调驱动；这条通道只是兜底：万一渲染回调长时间不来，
  /// 图层仍能持续拿到画面，小窗不至于停在黑屏。
  ///
  /// 这里刻意**不用** `Timer` + 主 RunLoop：App 退到后台后主 RunLoop 的定时器会被
  /// 系统降频甚至停摆，而「自动进入画中画」恰好发生在后台——补帧通道于是从头到尾
  /// 一次都没触发，小窗永远停在划走前的最后一帧。`DispatchSourceTimer` 跑在自己的
  /// 串行队列上，不受主 RunLoop 调度影响。
  private func startKeepAlive() {
    stopKeepAlive()
    let source = DispatchSource.makeTimerSource(queue: keepAliveQueue)
    source.schedule(
      deadline: .now() + 1.0 / 30.0,
      repeating: 1.0 / 30.0,
      leeway: .milliseconds(10)
    )
    source.setEventHandler { [weak self] in
      // 已经解除武装：什么都不做即可。定时源由主线程上的 stop / disarm / didStop
      // 统一收掉——这里**不能**顺手 stop，那会从补帧队列去改主线程持有的定时源引用。
      guard let self = self, self.isArmed else {
        return
      }
      // 前台且小窗未显示时完全不插手：那时渲染回调一定在供帧。
      if !self.isShowing, !self.appIsBackground {
        self.statKeepAliveSkipped += 1
        return
      }
      // 系统有时不会把「已进入画中画」的 delegate 回调送过来，`isShowing` 于是
      // 一直是 false：喂帧被降频、通知走错分支，小窗就定在最后一帧。这里按
      // controller 的真实状态纠正一次（限频，避免在后台空转）。
      if !self.isShowing {
        let now = CACurrentMediaTime()
        if now - self.lastReconcile > 0.5 {
          self.lastReconcile = now
          self.reconcileShowingState()
        }
      }
      // 后台解码看门狗：帧在送、`time-pos` 却不动，说明播放循环本身停住了。
      // 每 2 秒确认一次进度是否真的在走，不动就主动把播放重新推起来。
      if self.appIsBackground, !self.mpvFlag("pause") {
        let tick = CACurrentMediaTime()
        let position = self.mpvPosition()
        if self.stallWatchPosition < 0
          || position - self.stallWatchPosition > 0.25
        {
          self.stallWatchPosition = position
          self.stallWatchAt = tick
        } else if tick - self.stallWatchAt > 2.0,
          tick - self.lastStallNudge > 3.0
        {
          self.lastStallNudge = tick
          self.stallWatchPosition = position
          self.stallWatchAt = tick
          self.statStallNudge += 1
          self.nudgePlayback()
        }
      }
      // 刚刚才送过一帧（20ms 内）说明渲染回调仍在正常工作，跳过。
      let now = CACurrentMediaTime()
      let gap = now - self.lastLayerEnqueueAt
      if gap < 0.02 {
        self.statKeepAliveSkipped += 1
        return
      }
      self.statTimerTicks += 1
      // 图层已经超过 0.2 秒没拿到新样本：这次必须强制补（绕开「图层不就绪」的丢弃）。
      // 阈值不能放大：0.5 秒的停顿在小窗里肉眼就是「卡住了」。
      let stalled = gap > 0.2
      if stalled {
        self.statStallRecover += 1
      }
      self.onNeedFrame?(stalled)
    }
    source.resume()
    keepAliveSource = source
  }

  /// 系统已进入画中画、但 delegate 回调没送到时，按 controller 的真实状态补齐。
  ///
  /// `AVPictureInPictureController` 的属性只能在主线程读，因此这里回主线程确认一次；
  /// 确认后立刻把喂帧策略切到「小窗显示中」——否则后台窗口期会一直按 10 fps 降频，
  /// 小窗里就是一顿一顿甚至定帧。
  private func reconcileShowingState() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.statReconcileTry += 1
      guard !self.isShowing else { return }
      let active = self.pipController?.isPictureInPictureActive == true
      // 图层被系统收进小窗窗口后，父层就不再是我们的宿主视图。这比
      // `isPictureInPictureActive` 更可信：6S 上系统自动建窗时，delegate 与
      // controller 状态都可能停在 false，只有「图层搬了家」这件事一定为真。
      let detached = self.displayLayer.superlayer != nil
        && self.displayLayer.superlayer !== self.hostView.layer
      if active || detached {
        NSLog("PictureInPicture: recovered missing didStart callback")
        self.statReconcileHit += 1
        self.isArmed = true
        self.isShowing = true
        self.showingSince = CACurrentMediaTime()
        self.rebuildWaitSince = 0
        self.lastPosition = -1
        self.lastIdleEnqueue = 0
        self.lastLayerEnqueueAt = CACurrentMediaTime()
        self.activateAudioSession()
        self.startKeepAlive()
        self.onNeedFrame?(true)
        return
      }
      // 已武装、已在后台，系统却既不报 active、图层也没被收走：这次自动进小窗
      // 根本没建起来（屏幕上留着的多半是上一次会话的僵死窗口，拿不到新帧）。
      // 等 2 秒仍如此就主动换一套控制器与画面源。
      guard self.appIsBackground else { return }
      let now = CACurrentMediaTime()
      if self.rebuildWaitSince == 0 {
        self.rebuildWaitSince = now
        return
      }
      if now - self.rebuildWaitSince < 2.0 { return }
      self.rebuildWaitSince = now
      self.rebuildController()
    }
  }

  /// 把「已经停住」的播放重新推起来（后台看门狗专用）。
  ///
  /// 依次做三件事，任意一件奏效即可恢复：
  /// 1. 回主线程重新激活音频会话 —— 后台态下会话被系统降级后，音频输出会一直等
  ///    一个不再被拉取的缓冲，播放循环就卡死在写音频这一步；
  /// 2. 清图层并把时间轴对回当前进度 —— 图层侧卡住时这一步即可恢复；
  /// 3. 显式清掉 `pause` 并做一次「原地 seek」 —— 后台被挂起后，唯一能从外部唤醒
  ///    播放循环的动作。目标位置就是当前位置，用户看不到跳转。
  private func nudgePlayback() {
    NSLog("PictureInPicture: playback stalled in background, nudging")
    DispatchQueue.main.async { [weak self] in
      self?.activateAudioSession()
    }
    let resumeAt = mpvPosition()
    let resumeRate: Double = mpvFlag("pause") ? 0 : 1
    let layer = displayLayer
    let timebase = controlTimebase
    layerQueue.async {
      layer.flush()
      if #available(iOS 15.0, *), let timebase = timebase {
        CMTimebaseSetTime(
          timebase,
          time: CMTime(seconds: resumeAt, preferredTimescale: 600)
        )
        if CMTimebaseGetRate(timebase) != resumeRate {
          CMTimebaseSetRate(timebase, rate: resumeRate)
        }
      }
    }
    mpv_set_property_string(handle, "pause", "no")
    mpv_command_string(
      handle,
      "seek \(String(format: "%.3f", resumeAt)) absolute+exact"
    )
    // 连推两次仍不动，多半是卡在音频输出上：重载一次 AO。旧版 mpv 没有这个
    // 命令，只会返回错误，不影响后续重试。
    if statStallNudge >= 2 {
      mpv_command_string(handle, "ao-reload")
    }
    onNeedFrame?(true)
  }

  /// 重建控制器与画面源（后台僵死小窗自愈用）。
  @available(iOS 15.0, *)
  private func rebuildController() {
    // 一段武装期内最多重建几次：避免「重建了也不生效」时反复折腾。
    guard statControllerRebuild < 3 else { return }
    statControllerRebuild += 1
    NSLog("PictureInPicture: rebuilding controller for stale session")
    pipController?.stopPictureInPicture()
    pipController?.delegate = nil
    pipController = nil
    // 僵死窗口可能还攥着图层：强制摘回来，否则新 contentSource 指向的图层落在
    // 别人的窗口里，画面照样出不来。
    attachDisplayLayer(force: true)
    guard let controller = _ensureController() else { return }
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    if controller.isPictureInPicturePossible {
      statStartCalls += 1
      controller.startPictureInPicture()
    }
    onNeedFrame?(true)
  }

  /// 停止低速补帧通道。
  private func stopKeepAlive() {
    keepAliveSource?.cancel()
    keepAliveSource = nil
  }

  /// 记录一次「渲染回调在跑，但取不到像素缓冲」（由 `VideoOutput` 在补帧时调用）。
  public func noteCopyNil() {
    statCopyNil += 1
  }

  /// 建立画面图层的时间轴（只做一次）。
  @available(iOS 15.0, *)
  private func setupTimebase() {
    // 不再给图层挂时间轴。
    //
    // 挂上 `controlTimebase` 之后，图层是按「时间轴时刻 == 样本 PTS」排片的：
    // 时间轴被 mpv 的 time-pos 牵着走（0.1 秒粒度，还会轻微回退），只要某一刻
    // 时间轴落到了样本 PTS 之后，这一帧就被判成「已经过期」丢掉；连着丢几帧，
    // 小窗就停在上一次成功显示的那一帧 —— 读数正是「入队一直在涨、同帧不多、
    // 画面不动」。6S 上还叠加了「后台主队列被冻死」，我们连纠偏都做不到。
    //
    // 现在让图层不持时间轴：样本一入队就按到达顺序立刻显示（等同直播流）。
    // 画中画的进度条 / 快进由 `AVPictureInPictureSampleBufferPlaybackDelegate`
    // 提供，不依赖图层时间轴。
    controlTimebase = nil
  }

  /// 把小窗时间轴校准到当前播放位置，并同步播放 / 暂停状态。
  @available(iOS 15.0, *)
  private func syncTimebase(_ position: Double) {
    guard let timebase = controlTimebase else {
      return
    }
    // 每帧都强行对时，图层的呈现时钟一直在抖：6S 这类老机器上表现为
    // 「声音在走、画面不动」。只有明显跑偏（seek / 换源 / 卡顿后追帧）才校正。
    let current = CMTimebaseGetTime(timebase).seconds
    // 只许往前推。旧实现按「差值超过 0.3 秒」双向校正，而 mpv 的 time-pos 是
    // 0.1 秒粒度、偶尔还会回退一点，于是时间轴被反复往回设：图层去等一个已经
    // 播过的时刻，小窗就定在那一帧（6S），或者干脆闪成一片红（15pm 上图层在
    // 时间轴抖动时会重推 IOSurface）。往前追帧用 1 秒阈值，真回退（seek / 换源）
    // 用 3 秒阈值区分。
    if !current.isFinite || position > current + 1.0 || position < current - 3.0 {
      CMTimebaseSetTime(
        timebase,
        time: CMTime(seconds: position, preferredTimescale: 600)
      )
    }
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
  private func attachDisplayLayer(force: Bool = false) {
    // 图层归系统的画中画通道使用时，把它从当前父层摘下来再挂回宿主视图，等于在
    // 系统正读这块图层时把它抽走，小窗会停在抽走前的最后一帧。
    //
    // 这里原来只在 `isShowing || appIsBackground` 时挡这一下。6S 上系统自动建窗
    // 时这两个标记都可能还是 false（delegate 不来、controller 报 inactive），图层
    // 于是被抢回宿主视图，小窗从此再也不更新 —— 读数里「入队成功一直在涨、同帧
    // 也不多」，但屏幕上就是不动。现在改为无条件：只要图层挂在别处，就不碰它。
    // 只有重建控制器时（`force`）才需要强行收回来。
    if !force, let superlayer = displayLayer.superlayer,
      superlayer !== hostView.layer
    {
      return
    }
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

  /// 把一帧复制到自有缓冲池。必须在 `renderSynchronized` 之后调用。
  private func copyFrame(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    if width <= 0 || height <= 0 {
      return nil
    }
    if framePool == nil || framePoolWidth != width || framePoolHeight != height {
      framePool = nil
      framePoolWidth = width
      framePoolHeight = height
      // 给池子设一个存活上限：图层卡住时样本会一直攥着缓冲不放，6S 内存小，
      // 宁可退回「直接交轮转缓冲」（可能偶发一帧不干净）也不能把内存吃穿。
      // 限额只能在建池时给：CVPixelBufferPoolCreatePixelBufferWithAuxiliaryAttributes
      // 在 iOS SDK 里没导出，用它会直接编译不过。
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferPoolAllocationThresholdKey as String: 8,
      ]
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nil,
        attributes as CFDictionary,
        &pool
      )
      framePool = pool
    }
    guard let pool = framePool else { return nil }
    var destination: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        pool,
        &destination
      ) == kCVReturnSuccess,
      let dest = destination
    else {
      return nil
    }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess
    else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(dest, []) }
    guard
      let sourceBase = CVPixelBufferGetBaseAddress(source),
      let destBase = CVPixelBufferGetBaseAddress(dest)
    else { return nil }
    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let destStride = CVPixelBufferGetBytesPerRow(dest)
    let rowBytes = Swift.min(sourceStride, destStride)
    for row in 0..<height {
      memcpy(
        destBase + row * destStride,
        sourceBase + row * sourceStride,
        rowBytes
      )
    }
    return dest
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
    statDidStart += 1
    isArmed = true
    isShowing = true
    startDeadline = 0
    lastGoodHostSide = hostSide
    // 启动阶梯可能为了兜底把它提亮过；小窗已经在外面显示，屏幕上不该再留这个小点。
    hostView.alpha = PictureInPicture.hostIdleAlpha
    possibleCache = pipController?.isPictureInPicturePossible ?? true
    resetDiagnostics()
    showingSince = CACurrentMediaTime()
    if displayLayer.superlayer == nil {
      attachDisplayLayer()
    }
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
    statDidStop += 1
    isShowing = false
    showingSince = 0
    lastReconcile = 0
    stopKeepAlive()
    endBackgroundTaskIfNeeded()
    eventCallback("VideoOutput.PictureInPictureStateChanged", ["active": false])
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    startDeadline = 0
    statStartFail += 1
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
