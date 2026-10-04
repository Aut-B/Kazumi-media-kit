// https://stackoverflow.com/questions/49043257/how-to-ensure-to-run-some-code-on-same-background-thread/49075382#49075382
import Foundation

class Worker {
  public typealias Job = () -> Void

  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSRecursiveLock()
  private var thread: Thread!
  private var queue = [Job]()
  private var canceled: Bool = false

  init() {
    thread = Thread(block: loop)
    thread.start()
  }

  public func cancel() {
    signalCancel()
    thread.cancel()
  }

  public func enqueue(_ job: @escaping Job) {
    locked {
      queue.append(job)
    }

    semaphore.signal()
  }

  private func loop() {
    while true {
      semaphore.wait()

      if isCanceled() {
        return
      }

      let job = getFirstJob()
      // 这条线程是用 `Thread` 直接开出来的，系统不会为它自动准备自动释放池。上游只
      // 让它跑 setSize / dispose 这类低频任务，问题不明显；接入画中画之后，队列里
      // 开始出现「逐帧取像素、合成弹幕」这种会创建大量临时对象的重活（每帧一张画布）。
      // 没有自动释放池，这些临时对象会一直挂在当前线程上不被回收，跑得越久占用越大，
      // 最终拖垮整个进程。这里按 Apple 对自建线程的要求补上。
      autoreleasepool {
        job()
      }
    }
  }

  private func signalCancel() {
    locked {
      canceled = true
    }

    semaphore.signal()
  }

  private func isCanceled() -> Bool {
    let c = locked {
      canceled
    }

    return c
  }

  private func getFirstJob() -> Job {
    let job = locked {
      queue.removeFirst()
    }

    return job
  }

  private func locked<T>(do block: () -> T) -> T {
    lock.lock()
    defer {
      lock.unlock()
    }

    return block()
  }
}
