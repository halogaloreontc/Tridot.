/// Звук и видео конвертера средствами системы (ADR-026): на телефоне —
/// MediaCodec, Media3 Transformer и встроенный LAME (Kotlin), на Mac —
/// AVFoundation (Swift). Тяжёлая работа идёт в потоках системы: Dart только
/// запускает задачу, получает ход работы и итог по [MediaBridge] и
/// переименовывает готовый временный файл в результат
/// ([JobPlacement.commitFile]: чужой файл не заменяется, «(2)»).
///
/// Договор канала (`tridot/media`, `tridot/media/events`) — в
/// android/app/src/main/kotlin/.../media/MediaChannel.kt.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../jobs/extension_card.dart';
import '../../jobs/job_placement.dart';
import '../../jobs/job_runner.dart';
import 'convert_targets.dart';

/// Ошибка запуска на стороне системы: код [JobCodes].
final class MediaBridgeException implements Exception {
  const MediaBridgeException(this.code);

  final String code;

  @override
  String toString() => 'MediaBridgeException($code)';
}

/// Связь с системным конвертером; в приложении — каналы платформы
/// (lib/app/jobs/media_channel_bridge.dart), в тестах — подделка.
abstract interface class MediaBridge {
  /// Что система умеет: `{targets: [...], video1080: bool}`; `null` —
  /// конвертера в этой сборке нет.
  Future<Map<Object?, Object?>?> capabilities();

  /// Запускает задачу; неверный путь или цель — [MediaBridgeException].
  Future<void> start(Map<String, Object?> arguments);

  /// Отменяет задачу [id]; неизвестная — ничего.
  Future<void> cancel(String id);

  /// События всех задач: `{id, progress}`, `{id, done: true}`,
  /// `{id, error: код}`.
  Stream<Map<Object?, Object?>> get events;
}

/// Что сообщила система ([MediaBridge.capabilities]); пусто, ошибка или
/// не ответила за [timeout] — [NativeMediaCaps.none]. Цели, которых
/// конвертер не знает или которые здесь не делаются никогда, отбрасываются.
Future<NativeMediaCaps> loadNativeMediaCaps(
  MediaBridge bridge, {
  required JobPlatform platform,
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final map = await bridge.capabilities().timeout(timeout);
    if (map == null) return NativeMediaCaps.none;
    return nativeMediaCapsOf(map, platform);
  } on Object {
    return NativeMediaCaps.none;
  }
}

/// [NativeMediaCaps] из ответа системы.
NativeMediaCaps nativeMediaCapsOf(
  Map<Object?, Object?> map,
  JobPlatform platform,
) {
  final targets = <String>{
    if (map['targets'] case final List<Object?> list)
      for (final target in list)
        if (target is String &&
            ConvertTargets.all.contains(target) &&
            !ConvertTargets.isImageTarget(target) &&
            !ConvertCaps.impossible(platform, target))
          target,
  };
  if (targets.isEmpty) return NativeMediaCaps.none;
  return NativeMediaCaps(
    targets: targets,
    video1080: map['video1080'] != false,
  );
}

/// Системный конвертер этого устройства: что он умеет и кто запускает
/// задачи.
final class NativeMedia {
  const NativeMedia({required this.caps, required this.runner});

  final NativeMediaCaps caps;
  final JobRunner runner;
}

/// Задачи конвертера, которые делает система.
final class PlatformMediaJobRunner implements JobRunner {
  PlatformMediaJobRunner(
    this.bridge, {
    this.cancelGrace = const Duration(seconds: 5),
  });

  final MediaBridge bridge;

  /// Сколько после отмены ждать, пока система перестанет писать
  /// временный файл, чтобы убрать его ещё раз.
  final Duration cancelGrace;

  final Map<String, _NativeRun> _runs = <String, _NativeRun>{};
  StreamSubscription<Map<Object?, Object?>>? _events;
  int _serial = 0;

  /// Коды, которые может прислать система; прочее — [JobCodes.failed].
  static const Set<String> _codes = <String>{
    JobCodes.missing,
    JobCodes.noStream,
    JobCodes.media,
    JobCodes.mediaOpen,
    JobCodes.encoder,
    JobCodes.disk,
    JobCodes.tooBig,
    JobCodes.tooBigWav,
    JobCodes.noMemory,
    JobCodes.unsupported,
    JobCodes.cancelled,
    JobCodes.failed,
  };

  static String _code(Object? code) =>
      code is String && _codes.contains(code) ? code : JobCodes.failed;

  /// Аргументы `start` для задачи [request] с id [id].
  static Map<String, Object?> argumentsOf(JobRequest request, String id) {
    final target = request.action;
    final options = ConvertOptions.fromMap(
      request.options,
      target,
      ConvertTargets.kindOf(request.sources.single.name),
    );
    return <String, Object?>{
      'id': id,
      'input': request.sources.single.path,
      'output': request.temp,
      'target': target,
      'audioKbps': options.audioKbps,
      'videoRes': options.videoRes,
      'videoQuality': options.videoQuality,
      'jpegQuality': options.jpegQuality,
    };
  }

  @override
  Stream<JobEvent> start(JobRequest request) {
    final id = '${request.cardId}-${++_serial}';
    final run = _NativeRun(request, id);
    // Прежняя задача той же карточки (её уже отменили) больше не наша.
    _runs.remove(request.cardId)?.finish(const JobFailed(JobCodes.cancelled));
    _runs[request.cardId] = run;
    unawaited(_start(run));
    return run.controller.stream;
  }

  Future<void> _start(_NativeRun run) async {
    final request = run.request;
    final temp = request.temp;
    if (temp == null ||
        request.target == null ||
        request.sources.length != 1 ||
        !ConvertTargets.all.contains(request.action)) {
      _finish(run, const JobFailed(JobCodes.failed));
      return;
    }
    if (!File(request.sources.single.path).existsSync()) {
      _finish(run, const JobFailed(JobCodes.missing));
      return;
    }
    IsolateJobRunner.removeQuietly(temp);
    _listen();
    run.controller.add(
      JobProgress(
        ConvertTargets.isFrame(request.action) ? null : 0,
        'Конвертация',
      ),
    );
    try {
      await bridge.start(argumentsOf(request, run.id));
    } on MediaBridgeException catch (error) {
      IsolateJobRunner.removeQuietly(temp);
      _finish(run, JobFailed(_code(error.code)));
    } on Object {
      IsolateJobRunner.removeQuietly(temp);
      _finish(run, const JobFailed(JobCodes.failed));
    }
  }

  void _listen() {
    _events ??= bridge.events.listen(
      _onEvent,
      onError: (Object _) => _lost(),
      onDone: _lost,
    );
  }

  /// Поток событий оборвался (движок перезапущен): итога не будет.
  void _lost() {
    _events = null;
    for (final run in _runs.values.toList()) {
      IsolateJobRunner.removeQuietly(run.request.temp!);
      _finish(run, const JobFailed(JobCodes.failed));
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    final id = event['id'];
    final run = _runs.values.where((_NativeRun r) => r.id == id).firstOrNull;
    if (run == null || run.finished) return;
    final temp = run.request.temp!;
    if (event['done'] == true) {
      final produced = File(temp);
      if (!produced.existsSync() || produced.lengthSync() == 0) {
        IsolateJobRunner.removeQuietly(temp);
        _finish(run, const JobFailed(JobCodes.failed));
        return;
      }
      try {
        // Имя могли занять, пока шла работа: чужой файл не заменяется.
        final result = JobPlacement.commitFile(temp, run.request.target!);
        _finish(
          run,
          JobDone(outputs: <String>[result], outputDir: p.dirname(result)),
        );
      } on Object catch (error) {
        IsolateJobRunner.removeQuietly(temp);
        _finish(run, JobFailed(JobCodes.of(error)));
      }
      return;
    }
    if (event.containsKey('error')) {
      IsolateJobRunner.removeQuietly(temp);
      _finish(run, JobFailed(_code(event['error'])));
      return;
    }
    final value = event['progress'];
    run.controller.add(
      JobProgress(
        value is num ? value.toDouble().clamp(0, 0.99) : null,
        'Конвертация',
      ),
    );
  }

  void _finish(_NativeRun run, JobEvent event) {
    if (identical(_runs[run.request.cardId], run)) {
      _runs.remove(run.request.cardId);
    }
    run.finish(event);
  }

  @override
  void cancel(String cardId) {
    final run = _runs.remove(cardId);
    if (run == null || run.finished) return;
    run.finish(const JobFailed(JobCodes.cancelled));
    unawaited(bridge.cancel(run.id).catchError((Object _) {}));
    final temp = run.request.temp!;
    // Система могла ещё держать файл: убираем и сейчас, и чуть позже.
    IsolateJobRunner.removeQuietly(temp);
    Timer(cancelGrace, () => IsolateJobRunner.removeQuietly(temp));
  }
}

final class _NativeRun {
  _NativeRun(this.request, this.id);

  final JobRequest request;

  /// Id задачи у системы: карточка и номер запуска.
  final String id;
  final StreamController<JobEvent> controller = StreamController<JobEvent>();
  bool finished = false;

  void finish(JobEvent event) {
    if (finished) return;
    finished = true;
    controller
      ..add(event)
      ..close();
  }
}
