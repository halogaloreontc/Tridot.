import 'package:flutter/services.dart';

import '../../core/skills/converter/platform_media_job.dart';

/// [MediaBridge] через каналы платформы `tridot/media` и
/// `tridot/media/events` (ADR-026). Где их нет (Windows, Linux, iOS, тесты)
/// — [capabilities] отвечает `null`: системного конвертера нет.
final class ChannelMediaBridge implements MediaBridge {
  ChannelMediaBridge({
    MethodChannel method = const MethodChannel('tridot/media'),
    EventChannel events = const EventChannel('tridot/media/events'),
  })  : _method = method,
        _eventChannel = events;

  final MethodChannel _method;
  final EventChannel _eventChannel;

  @override
  late final Stream<Map<Object?, Object?>> events = _eventChannel
      .receiveBroadcastStream()
      .where((Object? event) => event is Map)
      .map((Object? event) => event! as Map<Object?, Object?>);

  @override
  Future<Map<Object?, Object?>?> capabilities() async {
    try {
      return await _method.invokeMapMethod<Object?, Object?>('capabilities');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> start(Map<String, Object?> arguments) async {
    try {
      await _method.invokeMethod<void>('start', arguments);
    } on PlatformException catch (error) {
      throw MediaBridgeException(error.code);
    } on MissingPluginException {
      throw const MediaBridgeException('unsupported');
    }
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _method.invokeMethod<void>('cancel', <String, Object?>{'id': id});
    } on Object {
      // Задачи уже нет или канала нет — отменять нечего.
    }
  }
}
