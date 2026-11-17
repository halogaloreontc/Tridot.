import FlutterMacOS
import Foundation

// Конвертер звука и видео средствами Mac (ADR-026, шаг S3). Договор тот
// же, что у Android (android/.../media/MediaChannel.kt и
// lib/core/skills/converter/platform_media_job.dart):
//
// - `tridot/media`: `capabilities` → `{targets, video1080, api}`;
//   `start {id, input, output, target, audioKbps?, videoRes?,
//   videoQuality?, jpegQuality?}` → `nil` сразу (неверный путь или цель —
//   FlutterError с кодом); `cancel {id}` — можно звать сколько угодно;
// - `tridot/media/events`: `{id, progress}` (0..1 или `nil`, не чаще 4 раз
//   в секунду), затем ровно одно `{id, done: true}` или `{id, error: код}`.
//
// Наружу уходят только коды ошибок, без путей и текстов исключений.
// Работа — в очереди из двух потоков, не на главном.

/// Коды ошибок — те же, что JobCodes в Dart (lib/core/jobs/job_runner.dart).
enum MediaCode: String {
  case missing
  case noStream
  case media
  case mediaOpen
  case encoder
  case disk
  case tooBig
  case tooBigWav
  case noMemory
  case unsupported
  case cancelled
  case failed
}

/// Ошибка задачи с готовым кодом [MediaCode].
struct MediaFail: Error {
  let code: MediaCode
}

/// Цели (значения поля target карточки), которые делает Mac.
enum MediaTarget {
  static let mp3 = "mp3"
  static let m4a = "m4a"
  static let wav = "wav"
  static let mp4 = "mp4"
  static let mov = "mov"
  static let frameJpeg = "frame-jpeg"
  static let framePng = "frame-png"
}

/// Предустановки качества — копия таблицы ConvertQuality
/// (lib/core/skills/converter/convert_quality.dart) и Presets.kt. Тест
/// test/skills/converter/presets_parity_test.dart читает этот файл и
/// сверяет числа: меняются они во всех местах сразу.
enum MediaPresets {
  /// Битрейт звука mp3 и m4a, кбит/с.
  static let audioKbps = [128, 192, 256, 320]
  static let audioKbpsDefault = 192

  /// Качество JPEG кадра.
  static let jpegQuality = [95, 85, 75, 60]
  static let jpegQualityDefault = 85

  /// Качество видео: высокое, среднее, экономное.
  static let videoQuality = ["high", "mid", "eco"]

  /// Битрейт видео H.264, кбит/с, по размеру: высокое, среднее, экономное.
  static let videoKbps: [String: [Int]] = [
    "1080": [8000, 5000, 3000],
    "720": [5000, 3000, 1800],
    "480": [2500, 1500, 900],
    "src": [8000, 4000, 2000],
  ]

  /// Битрейт звука AAC внутри видео, кбит/с.
  static let videoAudioKbps = [192, 160, 128]

  /// Длинная сторона кадра по размеру видео.
  static let longSide: [String: Int] = ["1080": 1920, "720": 1280, "480": 854]

  /// «Как в исходнике»: бит на пиксель кадра (высокое, среднее, экономное).
  static let pixelFactor = [0.13, 0.08, 0.05]

  static func qualityIndex(_ quality: String?) -> Int {
    switch quality {
    case "high": return 0
    case "eco": return 2
    default: return 1
    }
  }

  static func pickAudioKbps(_ value: Int?) -> Int {
    if let value = value, audioKbps.contains(value) { return value }
    return audioKbpsDefault
  }

  static func pickJpegQuality(_ value: Int?) -> Int {
    if let value = value, jpegQuality.contains(value) { return value }
    return jpegQualityDefault
  }

  static func pickVideoRes(_ value: String?) -> String {
    if let value = value, videoKbps[value] != nil { return value }
    return "src"
  }

  static func pickVideoQuality(_ value: String?) -> String {
    if let value = value, videoQuality.contains(value) { return value }
    return "mid"
  }

  /// Битрейт видео, бит/с. «Как в исходнике» — по числу пикселей и кадров
  /// в секунду, но не больше строки 1080p.
  static func videoBitrate(
    _ res: String, _ quality: String?, width: Int, height: Int, fps: Double
  ) -> Int {
    let q = qualityIndex(quality)
    let row = videoKbps[res] ?? videoKbps["src"]!
    if res != "src" || width <= 0 || height <= 0 { return row[q] * 1000 }
    let rate = (1...240).contains(fps) ? fps : 30
    let byPixels = Double(width) * Double(height) * rate * pixelFactor[q]
    let cap = Double(videoKbps["1080"]![q] * 1000)
    return Int(min(max(byPixels, 300_000), cap))
  }

  /// Размер кадра для [res]: длинная сторона не больше предустановки,
  /// пропорции те же, стороны чётные, меньшее видео не растягивается.
  /// `nil` — оставить как есть.
  static func scaledSize(_ res: String, width: Int, height: Int) -> (Int, Int)? {
    guard let side = longSide[res] else { return nil }
    let long = max(width, height)
    if width <= 0 || height <= 0 || long <= side { return nil }
    let scale = Double(side) / Double(long)
    func even(_ v: Double) -> Int { max(2, Int(v / 2) * 2) }
    return (even(Double(width) * scale), even(Double(height) * scale))
  }
}

/// Что сделать: цель и качество уже проверены по [MediaPresets].
struct MediaRequest {
  let id: String
  let input: URL
  let output: URL
  let target: String
  let audioKbps: Int
  let videoRes: String
  let videoQuality: String
  let jpegQuality: Int
}

final class MediaChannel: NSObject, FlutterStreamHandler {
  /// Каналы живут, пока живёт приложение.
  private static var instance: MediaChannel?

  /// Регистрирует каналы `tridot/media` и `tridot/media/events`.
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = MediaChannel()
    FlutterMethodChannel(name: "tridot/media", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in channel.handle(call, result: result) }
    FlutterEventChannel(name: "tridot/media/events", binaryMessenger: messenger)
      .setStreamHandler(channel)
    instance = channel
  }

  private var sink: FlutterEventSink?
  private let lock = NSLock()
  private var jobs: [String: MediaJob] = [:]
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "tridot-media"
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
  }()

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      // Загрузка LAME и опрос — не на главном потоке.
      DispatchQueue.global(qos: .userInitiated).async {
        let caps = MediaChannel.capabilities()
        DispatchQueue.main.async { result(caps) }
      }
    case "start":
      start(call, result: result)
    case "cancel":
      if let args = call.arguments as? [String: Any], let id = args["id"] as? String {
        lock.lock()
        let job = jobs[id]
        lock.unlock()
        job?.cancel()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Цели, которые этот Mac делает. MP3 — только если встроенный LAME
  /// загрузился (tridot_mp3.framework).
  static func supported() -> Set<String> {
    var targets: Set<String> = [
      MediaTarget.m4a, MediaTarget.wav, MediaTarget.mp4, MediaTarget.mov,
      MediaTarget.frameJpeg, MediaTarget.framePng,
    ]
    if Lame.shared != nil { targets.insert(MediaTarget.mp3) }
    return targets
  }

  private static func capabilities() -> [String: Any] {
    return [
      "targets": Array(supported()).sorted(),
      // Кодировщик H.264 в macOS (VideoToolbox) умеет 1080p всегда.
      "video1080": true,
      "api": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    ]
  }

  private func start(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let id = args["id"] as? String,
      let input = MediaChannel.inputFile(args["input"]),
      let output = MediaChannel.outputFile(args["output"], input: input),
      let target = args["target"] as? String
    else {
      result(FlutterError(code: MediaCode.failed.rawValue, message: nil, details: nil))
      return
    }
    guard MediaChannel.supported().contains(target) else {
      result(FlutterError(code: MediaCode.unsupported.rawValue, message: nil, details: nil))
      return
    }
    let request = MediaRequest(
      id: id,
      input: input,
      output: output,
      target: target,
      audioKbps: MediaPresets.pickAudioKbps(args["audioKbps"] as? Int),
      videoRes: MediaPresets.pickVideoRes(args["videoRes"] as? String),
      videoQuality: MediaPresets.pickVideoQuality(args["videoQuality"] as? String),
      jpegQuality: MediaPresets.pickJpegQuality(args["jpegQuality"] as? Int)
    )
    let job = MediaJob(request: request) { [weak self] value in
      self?.send(["id": id, "progress": value.map { $0 as Any } ?? NSNull()])
    }
    lock.lock()
    if jobs[id] != nil {
      lock.unlock()
      result(FlutterError(code: MediaCode.failed.rawValue, message: nil, details: nil))
      return
    }
    jobs[id] = job
    lock.unlock()
    queue.addOperation { [weak self] in self?.run(job) }
    result(nil)
  }

  private func run(_ job: MediaJob) {
    let id = job.request.id
    let code = job.run()
    lock.lock()
    jobs.removeValue(forKey: id)
    lock.unlock()
    if let code = code {
      send(["id": id, "error": code.rawValue])
    } else {
      send(["id": id, "done": true])
    }
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(event) }
  }

  /// Исходник: абсолютный путь. Доступ к нему даёт песочница (файл выбран
  /// пользователем или лежит в папке приложения); есть ли он — проверит
  /// задача (`missing`).
  static func inputFile(_ value: Any?) -> URL? {
    guard let path = value as? String, path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  /// Временный файл результата: абсолютный путь `….part` (его даёт
  /// JobPlacement.tempFile в Dart), папка уже есть, это не исходник.
  static func outputFile(_ value: Any?, input: URL) -> URL? {
    guard let path = value as? String, path.hasPrefix("/"), path.hasSuffix(".part") else {
      return nil
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if url.path == input.path { return nil }
    var isDir: ObjCBool = false
    let parent = url.deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue
    else { return nil }
    return url
  }
}

/// Встроенный кодировщик MP3 (ADR-026): libtridot_mp3 — LAME 3.100 и
/// тонкая обёртка (packages/tridot_lame, LGPL-2.0-or-later). Сборщик
/// Flutter кладёт её отдельным `Contents/Frameworks/tridot_mp3.framework`
/// — её можно пересобрать и заменить. Грузится через dlopen; не
/// загрузилась или не та версия — MP3 в списке целей нет.
final class Lame {
  typealias OpenFn = @convention(c) (
    Int32, Int32, Int32, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
  ) -> Int32
  typealias CapFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
  typealias EncodeFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<Int16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32
  ) -> Int32
  typealias FlushFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
  ) -> Int32
  typealias CloseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?

  /// TL_MAX_FRAMES из src/tridot_lame.h.
  static let maxFrames = 1 << 20

  /// Версия LAME, с которой собрано приложение.
  static let expectedVersion = "3.100"

  let open: OpenFn
  let outCap: CapFn
  let encode: EncodeFn
  let flush: FlushFn
  let lametag: FlushFn
  let close: CloseFn

  static let shared: Lame? = Lame.load()

  /// Где искать библиотеку: имя фреймворка даёт сборщик Flutter
  /// (`tridot_mp3`, при совпадении имён — с цифрой).
  private static func candidates() -> [String] {
    guard let frameworks = Bundle.main.privateFrameworksPath else { return [] }
    var paths = ["\(frameworks)/tridot_mp3.framework/tridot_mp3"]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
    for name in names.sorted()
    where name.hasPrefix("tridot_mp3") && name.hasSuffix(".framework") {
      let base = String(name.dropLast(".framework".count))
      let path = "\(frameworks)/\(name)/\(base)"
      if !paths.contains(path) { paths.append(path) }
    }
    return paths
  }

  private static func load() -> Lame? {
    for path in candidates() {
      guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
      if let lame = Lame(handle: handle) { return lame }
      dlclose(handle)
    }
    return nil
  }

  private init?(handle: UnsafeMutableRawPointer) {
    func symbol<T>(_ name: String, _ type: T.Type) -> T? {
      guard let pointer = dlsym(handle, name) else { return nil }
      return unsafeBitCast(pointer, to: type)
    }
    guard let open = symbol("tl_open", OpenFn.self),
      let outCap = symbol("tl_out_cap_h", CapFn.self),
      let encode = symbol("tl_encode", EncodeFn.self),
      let flush = symbol("tl_flush", FlushFn.self),
      let lametag = symbol("tl_lametag", FlushFn.self),
      let close = symbol("tl_close", CloseFn.self),
      let version = symbol("tl_version", VersionFn.self),
      let text = version(),
      String(cString: text) == Lame.expectedVersion
    else { return nil }
    self.open = open
    self.outCap = outCap
    self.encode = encode
    self.flush = flush
    self.lametag = lametag
    self.close = close
  }
}

/// Один кодировщик MP3 с постоянным битрейтом.
final class Mp3Encoder {
  private let lame: Lame
  private let channels: Int
  private var handle: UnsafeMutableRawPointer?
  private var buffer: [UInt8] = []

  init(lame: Lame, rate: Int, channels: Int, kbps: Int) throws {
    var created: UnsafeMutableRawPointer?
    let status = lame.open(Int32(rate), Int32(channels), Int32(kbps), 0, &created)
    guard status == 0, let handle = created else { throw MediaFail(code: .encoder) }
    self.lame = lame
    self.channels = channels
    self.handle = handle
  }

  deinit { close() }

  /// [frames] кадров PCM int16 (каналы чередуются) → байты MP3.
  func encode(_ pcm: UnsafePointer<Int16>, frames: Int) throws -> Data {
    var result = Data()
    var at = 0
    while at < frames {
      let count = min(Lame.maxFrames, frames - at)
      // Ёмкость — по частоте MP3: 8–24 кГц на высоком битрейте
      // пересэмплируются вверх, и байт выходит больше (tl_out_cap_h).
      let cap = Int(lame.outCap(handle, Int32(count)))
      guard cap > 0 else { throw MediaFail(code: .encoder) }
      if buffer.count < cap { buffer = [UInt8](repeating: 0, count: cap) }
      let lame = self.lame
      let handle = self.handle
      let source = pcm + at * channels
      let written = buffer.withUnsafeMutableBufferPointer {
        lame.encode(handle, source, Int32(count), $0.baseAddress, Int32(cap))
      }
      guard written >= 0 else { throw MediaFail(code: .encoder) }
      result.append(contentsOf: buffer[0..<Int(written)])
      at += count
    }
    return result
  }

  /// Остаток после последних кадров.
  func flush() throws -> Data { try tail(lame.flush) }

  /// Кадр «Info» (Xing/LAME) — пишется поверх начала файла.
  func lametag() throws -> Data { try tail(lame.lametag) }

  private func tail(_ call: Lame.FlushFn) throws -> Data {
    let cap = Int(lame.outCap(handle, 0))
    guard cap > 0 else { throw MediaFail(code: .encoder) }
    if buffer.count < cap { buffer = [UInt8](repeating: 0, count: cap) }
    let handle = self.handle
    let written = buffer.withUnsafeMutableBufferPointer {
      call(handle, $0.baseAddress, Int32(cap))
    }
    guard written >= 0 else { throw MediaFail(code: .encoder) }
    return Data(buffer[0..<Int(written)])
  }

  func close() {
    if let handle = handle { lame.close(handle) }
    handle = nil
  }
}
