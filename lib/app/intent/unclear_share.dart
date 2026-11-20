import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Чем кончилось «Поделиться» файлом непонятых фраз.
enum UnclearShareOutcome {
  /// Отдали системе («Поделиться» на телефоне) или сохранили файл.
  done,

  /// Человек закрыл выбор места.
  cancelled,

  /// Не вышло.
  failed,
}

/// Отдать файл непонятых фраз (ADR-045, п. 8) — только по нажатию, после
/// просмотра. Телефон — системное «Поделиться», компьютер — «Сохранить
/// как…». Тесты подменяют реализацию.
abstract interface class UnclearSharer {
  /// Подпись кнопки: «Поделиться» или «Сохранить файл».
  String get actionTitle;

  Future<UnclearShareOutcome> share({
    required String fileName,
    required String text,
  });
}

/// На Android — копия во временной папке и `tridot/files` → `share`
/// (FileProvider, только чтение), на компьютере — `file_selector`.
final class IoUnclearSharer implements UnclearSharer {
  const IoUnclearSharer({
    MethodChannel channel = const MethodChannel('tridot/files'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  String get actionTitle =>
      Platform.isAndroid || Platform.isIOS ? 'Поделиться' : 'Сохранить файл';

  @override
  Future<UnclearShareOutcome> share({
    required String fileName,
    required String text,
  }) async {
    try {
      if (Platform.isAndroid) {
        final temp = await getTemporaryDirectory();
        final dir = Directory(p.join(temp.path, 'tridot-share'));
        await dir.create(recursive: true);
        final file = File(p.join(dir.path, fileName));
        await file.writeAsString(text, flush: true);
        final ok = await _channel.invokeMethod<bool>(
              'share',
              <String, Object?>{'path': file.path, 'name': fileName},
            ) ??
            false;
        // Канал уже сделал свою копию для другого приложения.
        try {
          await file.delete();
        } on Object {
          // Уберётся вместе с временной папкой.
        }
        return ok ? UnclearShareOutcome.done : UnclearShareOutcome.failed;
      }
      final location = await getSaveLocation(suggestedName: fileName);
      if (location == null) return UnclearShareOutcome.cancelled;
      await File(location.path).writeAsString(text, flush: true);
      return UnclearShareOutcome.done;
    } on Object {
      return UnclearShareOutcome.failed;
    }
  }
}
