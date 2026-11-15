import 'dart:async';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../../core/voice/voice_recognizer.dart';

/// Методы канала `tridot/voice`, которые вызывает Dart. Других нет: в
/// частности, нет ничего, что включило бы обычный (сетевой) распознаватель.
const Set<String> deviceVoiceMethods = <String>{
  'status',
  'download',
  'start',
  'stop',
  'cancel',
};

/// Распознавание телефона (ADR-023) через каналы `tridot/voice` и
/// `tridot/voice/events` (`VoiceChannel.kt`): только
/// `createOnDeviceSpeechRecognizer`, звук записывает и распознаёт система,
/// приложение его не видит. Где канала нет (не Android, тесты) —
/// [DeviceVoiceStatus.unavailable].
final class DeviceVoiceRecognizer implements OnDeviceRecognizer {
  DeviceVoiceRecognizer({
    MethodChannel method = const MethodChannel('tridot/voice'),
    EventChannel events = const EventChannel('tridot/voice/events'),
    Future<bool> Function()? permission,
    this.language = 'ru-RU',
    this.stopTimeout = const Duration(seconds: 4),
  })  : _method = method,
        _eventChannel = events,
        _permission = permission;

  final MethodChannel _method;
  final EventChannel _eventChannel;
  final Future<bool> Function()? _permission;

  /// Один запрос разрешения на всё время жизни: `AudioRecorder()` сразу
  /// заводит нативный рекордер, и новый на каждое нажатие копился бы до
  /// [dispose].
  AudioRecorder? _recorder;

  Future<bool> _hasPermission() {
    final permission = _permission;
    if (permission != null) return permission();
    return (_recorder ??= AudioRecorder()).hasPermission();
  }

  /// Язык распознавания (BCP-47).
  final String language;

  /// Сколько ждать итога после [stop].
  final Duration stopTimeout;

  DeviceVoiceStatus _status = DeviceVoiceStatus.unknown;
  int _session = 0;
  StreamController<VoiceEvent>? _events;
  StreamSubscription<Object?>? _native;
  String _lastPartial = '';
  Timer? _stopTimer;

  /// Последний известный статус ([checkStatus]).
  DeviceVoiceStatus get status => _status;

  @override
  VoiceSupport get support => _status == DeviceVoiceStatus.unavailable
      ? VoiceSupport.unsupported
      : VoiceSupport.supported;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) {
    assert(deviceVoiceMethods.contains(method), 'канал: $method');
    return _method.invokeMethod<T>(method, arguments);
  }

  @override
  Future<DeviceVoiceStatus> checkStatus() async {
    try {
      final answer = await _invoke<Map<Object?, Object?>>(
        'status',
        <String, Object?>{'language': language},
      );
      final api = answer?['api'];
      if (api is int) _api = api;
      _status = statusOf(answer);
    } on MissingPluginException {
      _status = DeviceVoiceStatus.unavailable;
    } on PlatformException {
      _status = DeviceVoiceStatus.unavailable;
    }
    return _status;
  }

  /// Ответ `status` канала — статус.
  static DeviceVoiceStatus statusOf(Map<Object?, Object?>? answer) {
    if (answer == null) return DeviceVoiceStatus.unavailable;
    final api = answer['api'];
    if (answer['available'] != true || (api is int && api < 31)) {
      return DeviceVoiceStatus.unavailable;
    }
    return switch (answer['language']) {
      'installed' => DeviceVoiceStatus.ready,
      'pending' => DeviceVoiceStatus.pending,
      'supported' => DeviceVoiceStatus.notInstalled,
      'unsupported' => DeviceVoiceStatus.unsupported,
      _ => DeviceVoiceStatus.unknown,
    };
  }

  late final Stream<Map<Object?, Object?>> _nativeEvents = _eventChannel
      .receiveBroadcastStream()
      .where((Object? event) => event is Map)
      .map((Object? event) => event! as Map<Object?, Object?>)
      .asBroadcastStream();

  @override
  Stream<DeviceLanguageDownload> downloadLanguage() async* {
    final String? answer;
    // Подписка до запроса: успех у уже скачанного языка приходит сразу.
    final updates = StreamController<DeviceLanguageDownload>();
    final subscription = _nativeEvents.listen(
      (Map<Object?, Object?> event) {
        if (event['type'] != 'download') return;
        switch (event['state']) {
          case 'progress':
            final value = event['value'];
            if (value is int) updates.add(DeviceDownloadProgress(value));
          case 'success':
            updates.add(const DeviceDownloadSuccess());
            unawaited(updates.close());
          case 'scheduled':
            updates.add(const DeviceDownloadScheduled());
            unawaited(updates.close());
          case 'error':
            updates.add(const DeviceDownloadError());
            unawaited(updates.close());
        }
      },
      onError: (Object _) {
        updates.add(const DeviceDownloadError());
        unawaited(updates.close());
      },
    );
    try {
      try {
        answer = await _invoke<String>(
          'download',
          <String, Object?>{'language': language},
        );
      } on Object {
        yield const DeviceDownloadError();
        return;
      }
      switch (answer) {
        case 'requested':
          break;
        case 'unsupported':
        default:
          yield const DeviceDownloadError();
          return;
      }
      if (await _hasProgressEvents()) {
        yield* updates.stream;
      } else {
        // Android 13: системный запрос без новостей — итог узнаём
        // проверкой языка при возврате в приложение.
        yield const DeviceDownloadScheduled();
      }
    } finally {
      await subscription.cancel();
      if (!updates.isClosed) unawaited(updates.close());
    }
  }

  /// Новости загрузки есть с Android 14 (уровень API — из `status`).
  int? _api;

  Future<bool> _hasProgressEvents() async {
    if (_api == null) {
      try {
        final answer = await _invoke<Map<Object?, Object?>>(
          'status',
          <String, Object?>{'language': language},
        );
        final api = answer?['api'];
        _api = api is int ? api : 0;
      } on Object {
        _api = 0;
      }
    }
    return (_api ?? 0) >= 34;
  }

  @override
  Future<VoicePermission> ensurePermission() async {
    try {
      return await _hasPermission()
          ? VoicePermission.granted
          : VoicePermission.denied;
    } on Object {
      return VoicePermission.denied;
    }
  }

  @override
  Future<void> load(String modelDir) async {}

  @override
  Stream<VoiceEvent> start() {
    _closeCurrent();
    final session = ++_session;
    final controller = StreamController<VoiceEvent>();
    _events = controller;
    _lastPartial = '';
    _native = _nativeEvents.listen(
      (Map<Object?, Object?> event) => _onNative(session, event),
      onError: (Object _) => _fail(session, VoiceErrorCode.engine),
    );
    unawaited(_begin(session));
    return controller.stream;
  }

  Future<void> _begin(int session) async {
    try {
      final code = await _invoke<int>(
        'start',
        <String, Object?>{'session': session, 'language': language},
      );
      if (code != null && code != 0) {
        _status = DeviceVoiceStatus.unavailable;
        _fail(session, VoiceErrorCode.engine);
      }
    } on MissingPluginException {
      _status = DeviceVoiceStatus.unavailable;
      _fail(session, VoiceErrorCode.engine);
    } on PlatformException {
      _fail(session, VoiceErrorCode.engine);
    }
  }

  void _onNative(int session, Map<Object?, Object?> event) {
    if (event['session'] != session || session != _session) return;
    switch (event['type']) {
      case 'partial':
        final text = event['text'];
        if (text is String) {
          _lastPartial = text;
          _events?.add(VoicePartial(text));
        }
      case 'final':
        final text = event['text'];
        _finish(session, text is String ? text : _lastPartial);
      case 'error':
        final code = event['code'];
        final mapped = errorOf(code is int ? code : -1);
        if (mapped == null) {
          // Тишина или ничего не разобрано — пустой итог, как у Vosk.
          _finish(session, '');
        } else {
          _fail(session, mapped);
        }
      case 'end':
        _closeCurrent();
    }
  }

  /// Код ошибки SpeechRecognizer — ошибка для человека; `null` — «речи не
  /// было» (пустой итог).
  static VoiceErrorCode? errorOf(int code) => switch (code) {
        6 || 7 => null,
        3 || 9 => VoiceErrorCode.microphone,
        8 || 10 => VoiceErrorCode.busy,
        12 => VoiceErrorCode.languageUnsupported,
        13 => VoiceErrorCode.languageUnavailable,
        _ => VoiceErrorCode.engine,
      };

  void _finish(int session, String text) {
    if (session != _session) return;
    _events?.add(VoiceFinal(text));
    _closeCurrent();
  }

  void _fail(int session, VoiceErrorCode code) {
    if (session != _session) return;
    if (code == VoiceErrorCode.languageUnsupported) {
      _status = DeviceVoiceStatus.unsupported;
    } else if (code == VoiceErrorCode.languageUnavailable) {
      _status = DeviceVoiceStatus.notInstalled;
    }
    _events?.add(VoiceError(code));
    _closeCurrent();
  }

  void _closeCurrent() {
    _stopTimer?.cancel();
    _stopTimer = null;
    final native = _native;
    _native = null;
    if (native != null) unawaited(native.cancel());
    final events = _events;
    _events = null;
    if (events != null) unawaited(events.close());
  }

  @override
  Future<void> stop() async {
    final session = _session;
    if (_events == null) return;
    _stopTimer?.cancel();
    // Итог не пришёл вовремя — последнее промежуточное, сессия отменяется.
    _stopTimer = Timer(stopTimeout, () {
      if (session != _session || _events == null) return;
      final text = _lastPartial;
      _finish(session, text);
      unawaited(_quiet('cancel', session));
    });
    try {
      await _invoke<void>('stop', <String, Object?>{'session': session});
    } on Object {
      _finish(session, _lastPartial);
    }
  }

  @override
  Future<void> cancel() async {
    final session = _session;
    final active = _events != null;
    // Новый номер: поздние события этой сессии больше никуда не идут.
    _session++;
    _closeCurrent();
    if (active) await _quiet('cancel', session);
  }

  Future<void> _quiet(String method, int session) async {
    try {
      await _invoke<void>(method, <String, Object?>{'session': session});
    } on Object {
      // Канала нет или сессия уже кончилась.
    }
  }

  @override
  Future<void> unload() async {}

  @override
  Future<void> dispose() async {
    await cancel();
    final recorder = _recorder;
    _recorder = null;
    await recorder?.dispose();
  }
}
