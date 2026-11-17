import AVFoundation
import AppKit
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation

// Задачи конвертера на Mac (ADR-026, шаг S3): AVFoundation читает и
// декодирует исходник (AVAssetReader), пишет AAC, PCM и H.264
// (AVAssetWriter); MP3 кодирует встроенный LAME (MediaChannel.swift).
// Кадр из видео — AVAssetImageGenerator.

/// Одна задача: работает в своём потоке, флаг отмены проверяется на каждом
/// буфере. Временный файл при ошибке и отмене удаляется здесь; итоговое
/// имя даёт Dart (JobPlacement.commitFile).
final class MediaJob {
  let request: MediaRequest
  private let progress: (Double?) -> Void
  private let lock = NSLock()
  private var cancelledFlag = false
  private var lastReport = 0.0
  private var lastValue: Double? = -1

  init(request: MediaRequest, progress: @escaping (Double?) -> Void) {
    self.request = request
    self.progress = progress
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelledFlag
  }

  func cancel() {
    lock.lock()
    cancelledFlag = true
    lock.unlock()
  }

  func checkCancelled() throws {
    if isCancelled { throw MediaFail(code: .cancelled) }
  }

  /// Ход работы: не чаще 4 раз в секунду, без повторов, после отмены — нет.
  func report(_ value: Double?) {
    lock.lock()
    let now = ProcessInfo.processInfo.systemUptime
    if cancelledFlag || now - lastReport < 0.25 || value == lastValue {
      lock.unlock()
      return
    }
    lastReport = now
    lastValue = value
    lock.unlock()
    progress(value)
  }

  /// Выполняет задачу: `nil` — готово, иначе код ошибки.
  func run() -> MediaCode? {
    let files = FileManager.default
    do {
      var isDir: ObjCBool = false
      guard files.fileExists(atPath: request.input.path, isDirectory: &isDir), !isDir.boolValue
      else { throw MediaFail(code: .missing) }
      try? files.removeItem(at: request.output)
      let pipeline = MediaPipeline(job: self)
      switch request.target {
      case MediaTarget.mp3: try pipeline.mp3()
      case MediaTarget.m4a: try pipeline.audio(fileType: .m4a, aac: true)
      case MediaTarget.wav: try pipeline.audio(fileType: .wav, aac: false)
      case MediaTarget.mp4: try pipeline.video(fileType: .mp4)
      case MediaTarget.mov: try pipeline.video(fileType: .mov)
      case MediaTarget.frameJpeg: try pipeline.frame(png: false)
      case MediaTarget.framePng: try pipeline.frame(png: true)
      default: throw MediaFail(code: .unsupported)
      }
      try checkCancelled()
      let attributes = try? files.attributesOfItem(atPath: request.output.path)
      let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      guard size > 0 else { throw MediaFail(code: .failed) }
      return nil
    } catch {
      try? files.removeItem(at: request.output)
      let code = MediaJob.code(of: error)
      // Без путей и текстов исключений: только вид ошибки.
      if code != .cancelled { NSLog("TridotMedia %@: %@", request.target, code.rawValue) }
      return isCancelled ? .cancelled : code
    }
  }

  /// Код [MediaCode] для ошибки системы.
  static func code(of error: Error, fallback: MediaCode = .failed) -> MediaCode {
    if let fail = error as? MediaFail { return fail.code }
    if noSpace(error as NSError) { return .disk }
    if let av = error as? AVError {
      switch av.code {
      case .diskFull: return .disk
      case .encoderNotFound, .encoderTemporarilyUnavailable: return .encoder
      case .decoderNotFound, .decoderTemporarilyUnavailable, .fileFormatNotRecognized,
        .fileFailedToParse, .contentIsProtected:
        return .mediaOpen
      default: return fallback
      }
    }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain
      && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError)
    {
      return .missing
    }
    return fallback
  }

  private static func noSpace(_ error: NSError) -> Bool {
    var current: NSError? = error
    while let e = current {
      if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
      if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
      current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}

/// Результат асинхронного вызова для потока, который его ждёт.
private final class Box<T>: @unchecked Sendable {
  var value: Result<T, Error>?
}

/// Флаг «эта дорожка дописана» для блока requestMediaDataWhenReady.
private final class Pump: @unchecked Sendable {
  var finished = false
}

/// Ждёт асинхронную загрузку свойств AVFoundation в потоке задачи (не на
/// главном): так конвейер остаётся простым и последовательным.
private func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
  let box = Box<T>()
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    do {
      box.value = .success(try await operation())
    } catch {
      box.value = .failure(error)
    }
    done.signal()
  }
  done.wait()
  return try box.value!.get()
}

private struct MediaPipeline {
  let job: MediaJob

  private var request: MediaRequest { job.request }

  /// Частоты MPEG-1/2/2.5 (MP3) — их же берёт AAC. Другая частота
  /// приводится к 44,1 кГц, выше 48 кГц — к 48 кГц.
  static let mpegRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

  static func mpegRate(_ rate: Double) -> Double {
    if mpegRates.contains(rate) { return rate }
    return rate > 48000 ? 48000 : 44100
  }

  // MARK: - Общее

  private func openAsset() throws -> AVURLAsset {
    let asset = AVURLAsset(
      url: request.input,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let readable: Bool
    do {
      readable = try blocking { try await asset.load(.isReadable) }
    } catch {
      throw MediaFail(code: MediaJob.code(of: error, fallback: .mediaOpen))
    }
    // Формат, который Mac не открывает (например, WebM или MKV).
    if !readable { throw MediaFail(code: .mediaOpen) }
    return asset
  }

  private func tracks(_ asset: AVAsset, _ type: AVMediaType) throws -> [AVAssetTrack] {
    do {
      return try blocking { try await asset.loadTracks(withMediaType: type) }
    } catch {
      throw MediaFail(code: MediaJob.code(of: error, fallback: .mediaOpen))
    }
  }

  /// Длительность в секундах; неизвестна — 0 (ход работы без процентов).
  private func seconds(_ asset: AVAsset) -> Double {
    guard let time = try? blocking({ try await asset.load(.duration) }) else { return 0 }
    let value = CMTimeGetSeconds(time)
    return value.isFinite && value > 0 ? value : 0
  }

  /// Частота и число каналов звуковой дорожки.
  private func audioFormat(_ track: AVAssetTrack) -> (rate: Double, channels: Int) {
    let formats = (try? blocking { try await track.load(.formatDescriptions) }) ?? []
    for format in formats {
      if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
        basic.mSampleRate > 0, basic.mChannelsPerFrame > 0
      {
        return (basic.mSampleRate, Int(basic.mChannelsPerFrame))
      }
    }
    return (44100, 2)
  }

  private func reader(_ asset: AVAsset) throws -> AVAssetReader {
    do {
      return try AVAssetReader(asset: asset)
    } catch {
      throw MediaFail(code: MediaJob.code(of: error, fallback: .mediaOpen))
    }
  }

  private func writer(_ fileType: AVFileType) throws -> AVAssetWriter {
    do {
      return try AVAssetWriter(outputURL: request.output, fileType: fileType)
    } catch {
      throw MediaFail(code: MediaJob.code(of: error))
    }
  }

  private static func layout(_ channels: Int) -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag =
      channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    return withUnsafeBytes(of: &layout) { Data($0) }
  }

  /// PCM 16 бит, каналы чередуются. Больше двух каналов AVFoundation
  /// сводит в стерео сама (раскладка в настройках).
  private static func pcmSettings(rate: Double, channels: Int) -> [String: Any] {
    return [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: channels,
      AVChannelLayoutKey: layout(channels),
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  /// Битрейты, которые кодировщик AAC принимает при такой частоте и числе
  /// каналов (бит/с).
  private static func aacBitrates(rate: Double, channels: Int) -> [Int] {
    let bytes = UInt32(2 * channels)
    var source = AudioStreamBasicDescription(
      mSampleRate: rate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: bytes,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytes,
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 16,
      mReserved: 0
    )
    var target = AudioStreamBasicDescription()
    target.mSampleRate = rate
    target.mFormatID = kAudioFormatMPEG4AAC
    target.mChannelsPerFrame = UInt32(channels)
    var created: AudioConverterRef?
    guard AudioConverterNew(&source, &target, &created) == noErr, let converter = created else {
      return []
    }
    defer { AudioConverterDispose(converter) }
    var size: UInt32 = 0
    guard
      AudioConverterGetPropertyInfo(
        converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
      size > 0
    else { return [] }
    let count = Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
    guard
      AudioConverterGetProperty(
        converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr
    else { return [] }
    return ranges.map { Int($0.mMaximum) }.filter { $0 > 0 }
  }

  /// Настройки AAC: выбранный битрейт или ближайший меньший, который
  /// кодировщик принимает (у моно и низких частот предел ниже 320 кбит/с).
  private static func aacSettings(rate: Double, channels: Int, kbps: Int) -> [String: Any] {
    let wanted = kbps * 1000
    let allowed = aacBitrates(rate: rate, channels: channels)
    let bitrate =
      allowed.filter { $0 <= wanted }.max() ?? allowed.min()
      ?? min(wanted, channels == 1 ? 128_000 : 256_000)
    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: channels,
      AVChannelLayoutKey: layout(channels),
      AVEncoderBitRateKey: bitrate,
    ]
  }

  private func progress(_ buffer: CMSampleBuffer, _ duration: Double) {
    guard duration > 0 else {
      job.report(nil)
      return
    }
    let at = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
    if at.isFinite { job.report(min(max(at / duration, 0), 1)) }
  }

  /// Переливает дорожки читателя в писателя (каждая — в своей очереди) и
  /// закрывает файл. Ход работы — по первой паре.
  private func transfer(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
    duration: Double
  ) throws {
    guard reader.startReading() else {
      throw MediaFail(code: reader.error.map { MediaJob.code(of: $0, fallback: .mediaOpen) } ?? .mediaOpen)
    }
    guard writer.startWriting() else {
      reader.cancelReading()
      throw MediaFail(code: writer.error.map { MediaJob.code(of: $0) } ?? .encoder)
    }
    writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    let job = self.job
    for (index, (output, input)) in pairs.enumerated() {
      group.enter()
      let pump = Pump()
      let queue = DispatchQueue(label: "tridot-media-\(index)")
      input.requestMediaDataWhenReady(on: queue) {
        if pump.finished { return }
        func finish() {
          pump.finished = true
          if writer.status == .writing { input.markAsFinished() }
          group.leave()
        }
        while input.isReadyForMoreMediaData {
          if job.isCancelled || writer.status != .writing {
            finish()
            return
          }
          guard let buffer = output.copyNextSampleBuffer() else {
            finish()
            return
          }
          if index == 0 { self.progress(buffer, duration) }
          if !input.append(buffer) {
            finish()
            return
          }
        }
      }
    }
    // Упавший писатель может больше не позвать блоки дорожек — ждём
    // частями и смотрим на отмену и ошибки сами.
    while group.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
      if job.isCancelled || writer.status == .failed || reader.status == .failed { break }
    }
    if job.isCancelled {
      reader.cancelReading()
      writer.cancelWriting()
      throw MediaFail(code: .cancelled)
    }
    if reader.status == .failed {
      writer.cancelWriting()
      throw MediaFail(code: reader.error.map { MediaJob.code(of: $0, fallback: .mediaOpen) } ?? .mediaOpen)
    }
    if writer.status == .failed {
      reader.cancelReading()
      throw MediaFail(code: writer.error.map { MediaJob.code(of: $0, fallback: .encoder) } ?? .encoder)
    }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else {
      throw MediaFail(code: writer.error.map { MediaJob.code(of: $0) } ?? .failed)
    }
  }

  // MARK: - Звук: m4a (AAC) и wav (PCM 16 бит)

  func audio(fileType: AVFileType, aac: Bool) throws {
    let asset = try openAsset()
    guard let track = try tracks(asset, .audio).first else { throw MediaFail(code: .noStream) }
    let duration = seconds(asset)
    let source = audioFormat(track)
    let channels = max(1, min(source.channels, 2))
    let rate = aac ? MediaPipeline.mpegRate(source.rate) : source.rate
    let reader = try self.reader(asset)
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: [track],
      audioSettings: MediaPipeline.pcmSettings(rate: rate, channels: channels)
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw MediaFail(code: .mediaOpen) }
    reader.add(output)
    let writer = try self.writer(fileType)
    let settings =
      aac
      ? MediaPipeline.aacSettings(rate: rate, channels: channels, kbps: request.audioKbps)
      : MediaPipeline.pcmSettings(rate: rate, channels: channels)
    guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
      throw MediaFail(code: .encoder)
    }
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw MediaFail(code: .encoder) }
    writer.add(input)
    try transfer(reader: reader, writer: writer, pairs: [(output, input)], duration: duration)
  }

  // MARK: - MP3 (встроенный LAME)

  func mp3() throws {
    guard let lame = Lame.shared else { throw MediaFail(code: .unsupported) }
    let asset = try openAsset()
    guard let track = try tracks(asset, .audio).first else { throw MediaFail(code: .noStream) }
    let duration = seconds(asset)
    let source = audioFormat(track)
    let channels = max(1, min(source.channels, 2))
    // 256 и 320 кбит/с при частоте не MPEG-1 обёртка сама переведёт в
    // 44,1 кГц (tl_auto_rate).
    let rate = MediaPipeline.mpegRate(source.rate)
    let reader = try self.reader(asset)
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: [track],
      audioSettings: MediaPipeline.pcmSettings(rate: rate, channels: channels)
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw MediaFail(code: .mediaOpen) }
    reader.add(output)
    let encoder = try Mp3Encoder(
      lame: lame, rate: Int(rate), channels: channels, kbps: request.audioKbps)
    defer { encoder.close() }
    guard FileManager.default.createFile(atPath: request.output.path, contents: nil) else {
      throw MediaFail(code: .failed)
    }
    let file = try FileHandle(forWritingTo: request.output)
    defer { try? file.close() }
    guard reader.startReading() else {
      throw MediaFail(code: reader.error.map { MediaJob.code(of: $0, fallback: .mediaOpen) } ?? .mediaOpen)
    }
    defer { if reader.status == .reading { reader.cancelReading() } }
    var pcm: [Int16] = []
    func step() throws -> Bool {
      try job.checkCancelled()
      guard let buffer = output.copyNextSampleBuffer() else { return false }
      if let block = CMSampleBufferGetDataBuffer(buffer) {
        let length = CMBlockBufferGetDataLength(block)
        let samples = length / 2
        let frames = samples / channels
        if frames > 0 {
          if pcm.count < samples { pcm = [Int16](repeating: 0, count: samples) }
          let status = pcm.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(
              block, atOffset: 0, dataLength: frames * channels * 2,
              destination: raw.baseAddress!)
          }
          guard status == kCMBlockBufferNoErr else { throw MediaFail(code: .mediaOpen) }
          let encoded = try pcm.withUnsafeBufferPointer {
            try encoder.encode($0.baseAddress!, frames: frames)
          }
          if !encoded.isEmpty { try file.write(contentsOf: encoded) }
        }
      }
      progress(buffer, duration)
      return true
    }
    while try autoreleasepool(invoking: step) {}
    try job.checkCancelled()
    if reader.status == .failed {
      throw MediaFail(code: reader.error.map { MediaJob.code(of: $0, fallback: .mediaOpen) } ?? .mediaOpen)
    }
    let rest = try encoder.flush()
    if !rest.isEmpty { try file.write(contentsOf: rest) }
    // Кадр «Info» поверх первого кадра: точная длительность у плееров.
    let tag = try encoder.lametag()
    if !tag.isEmpty {
      try file.seek(toOffset: 0)
      try file.write(contentsOf: tag)
    }
    try file.synchronize()
  }

  // MARK: - Видео: mp4 и mov (H.264 + AAC)

  func video(fileType: AVFileType) throws {
    let asset = try openAsset()
    guard let videoTrack = try tracks(asset, .video).first else {
      throw MediaFail(code: .noStream)
    }
    let audioTrack = try tracks(asset, .audio).first
    let duration = seconds(asset)
    let natural = (try? blocking { try await videoTrack.load(.naturalSize) }) ?? .zero
    let transform = (try? blocking { try await videoTrack.load(.preferredTransform) }) ?? .identity
    let fps = Double((try? blocking { try await videoTrack.load(.nominalFrameRate) }) ?? 30)
    let width = Int(abs(natural.width).rounded())
    let height = Int(abs(natural.height).rounded())
    guard width > 0, height > 0 else { throw MediaFail(code: .mediaOpen) }
    func even(_ v: Int) -> Int { max(2, v / 2 * 2) }
    // Размер считается до поворота: длинная сторона от него не зависит.
    let size =
      MediaPresets.scaledSize(request.videoRes, width: width, height: height)
      ?? (even(width), even(height))
    let bitrate = MediaPresets.videoBitrate(
      request.videoRes, request.videoQuality, width: size.0, height: size.1, fps: fps)

    let reader = try self.reader(asset)
    // Декодер сразу отдаёт кадры нужного размера.
    let videoOutput = AVAssetReaderTrackOutput(
      track: videoTrack,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: size.0,
        kCVPixelBufferHeightKey as String: size.1,
      ]
    )
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else { throw MediaFail(code: .mediaOpen) }
    reader.add(videoOutput)

    let writer = try self.writer(fileType)
    writer.shouldOptimizeForNetworkUse = true
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoMaxKeyFrameIntervalDurationKey: 2,
    ]
    if (1...240).contains(fps) { compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded()) }
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: size.0,
      AVVideoHeightKey: size.1,
      AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
      AVVideoCompressionPropertiesKey: compression,
    ]
    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      throw MediaFail(code: .encoder)
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.transform = transform
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { throw MediaFail(code: .encoder) }
    writer.add(videoInput)
    var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

    if let audioTrack = audioTrack {
      let source = audioFormat(audioTrack)
      let channels = max(1, min(source.channels, 2))
      let rate = MediaPipeline.mpegRate(source.rate)
      let audioOutput = AVAssetReaderAudioMixOutput(
        audioTracks: [audioTrack],
        audioSettings: MediaPipeline.pcmSettings(rate: rate, channels: channels)
      )
      audioOutput.alwaysCopiesSampleData = false
      let kbps = MediaPresets.videoAudioKbps[MediaPresets.qualityIndex(request.videoQuality)]
      let audioSettings = MediaPipeline.aacSettings(rate: rate, channels: channels, kbps: kbps)
      if reader.canAdd(audioOutput),
        writer.canApply(outputSettings: audioSettings, forMediaType: .audio)
      {
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        if writer.canAdd(audioInput) {
          reader.add(audioOutput)
          writer.add(audioInput)
          pairs.append((audioOutput, audioInput))
        }
      }
    }
    try transfer(reader: reader, writer: writer, pairs: pairs, duration: duration)
  }

  // MARK: - Кадр из видео

  func frame(png: Bool) throws {
    let asset = try openAsset()
    guard try !tracks(asset, .video).isEmpty else { throw MediaFail(code: .noStream) }
    let duration = seconds(asset)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    job.report(nil)
    // Как на телефоне: кадр на первой секунде, у короткого видео — первый.
    var image: CGImage?
    for at in duration > 1 ? [1.0, 0.0] : [0.0] {
      try job.checkCancelled()
      let time = CMTime(seconds: at, preferredTimescale: 600)
      if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
        image = cg
        break
      }
    }
    guard let cgImage = image else { throw MediaFail(code: .mediaOpen) }
    try job.checkCancelled()
    let rep = NSBitmapImageRep(cgImage: cgImage)
    let data =
      png
      ? rep.representation(using: .png, properties: [:])
      : rep.representation(
        using: .jpeg,
        properties: [.compressionFactor: Double(request.jpegQuality) / 100])
    guard let bytes = data else { throw MediaFail(code: .encoder) }
    do {
      try bytes.write(to: request.output)
    } catch {
      throw MediaFail(code: MediaJob.code(of: error))
    }
  }
}
