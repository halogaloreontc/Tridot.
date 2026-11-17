import 'package:path/path.dart' as p;

import '../jobs/extension_card.dart';
import '../models/action_card.dart';
import 'attachments.dart';
import 'chat_models.dart';

/// Откуда файл в «Файлах сессии».
enum SessionFileSource {
  /// Сделало расширение: результат готовой карточки (конвертер, архиватор,
  /// загрузчик видео).
  output,

  /// Прикрепил пользователь.
  attachment,
}

/// Файл сессии для правой панели (ADR-028): результат карточки
/// расширения или вложение сообщения. Только проекция сообщений чата —
/// своего хранения у него нет.
final class SessionFile {
  const SessionFile({
    required this.id,
    required this.source,
    required this.name,
    required this.kind,
    required this.at,
    required this.messageId,
    this.archive = false,
    this.size,
    this.extensionId,
    this.attachment,
    this.absolute,
  });

  /// `out:<id карточки>:<номер>` или `att:<id вложения>`.
  final String id;
  final SessionFileSource source;

  /// Имя для показа.
  final String name;
  final AttachmentKind kind;

  /// Архив (`.zip`, `.7z`, `.tar` …): своя плитка.
  final bool archive;

  /// Размер в байтах: у вложений — сохранённый; у результатов `null`
  /// (узнаёт панель).
  final int? size;

  /// Когда файл появился: карточка закончилась или файл прикрепили.
  final DateTime at;

  /// Сообщение, к которому файл привязан («Показать в сообщении»).
  final String messageId;

  /// Расширение-автор (только у результатов).
  final String? extensionId;

  /// Вложение (только у вложений).
  final ChatAttachment? attachment;

  /// Абсолютный путь результата (только у результатов).
  final String? absolute;

  bool get isOutput => source == SessionFileSource.output;

  static const Set<String> _archives = <String>{
    'zip', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'rar', //
  };

  /// Имя похоже на архив.
  static bool isArchiveName(String name) =>
      _archives.contains(AttachmentKind.extensionOf(name));

  @override
  String toString() => 'SessionFile($id, $name)';
}

/// Файлы сессии: что сделали расширения и что прикрепили (ADR-028).
abstract final class SessionFiles {
  /// Файлы чата [thread], новые первыми; результаты и вложения отдельно.
  ///
  /// Результат — путь из `job.outputs` готовой карточки
  /// ([CardState.done]); один и тот же путь у нескольких карточек —
  /// один раз, по самой новой. Вложение — каждое [ChatAttachment]
  /// сообщений. Исходники карточки, которые сами вложения, уже есть среди
  /// вложений и не повторяются.
  static ({List<SessionFile> outputs, List<SessionFile> attachments}) of(
    ChatThread thread,
  ) {
    final outputs = <String, SessionFile>{};
    final attachments = <SessionFile>[];
    for (final message in thread.messages) {
      for (final attachment in message.attachments) {
        attachments.add(
          SessionFile(
            id: 'att:${attachment.id}',
            source: SessionFileSource.attachment,
            name: attachment.name,
            kind: attachment.kind,
            archive: SessionFile.isArchiveName(attachment.name),
            size: attachment.size,
            at: attachment.addedAt,
            messageId: message.id,
            attachment: attachment,
          ),
        );
      }
      final job = message.job;
      if (job == null || job.state != CardState.done) continue;
      for (final (i, path) in job.outputs.indexed) {
        if (path.isEmpty) continue;
        final name = ActionCard.cardText(p.basename(path), max: 200);
        final file = SessionFile(
          id: 'out:${job.id}:$i',
          source: SessionFileSource.output,
          name: name.isEmpty ? path : name,
          kind: AttachmentKind.of(name),
          archive: SessionFile.isArchiveName(name),
          at: job.updatedAt,
          messageId: message.id,
          extensionId: job.extensionId,
          absolute: path,
        );
        final before = outputs[path];
        if (before == null || !before.at.isAfter(file.at)) {
          // Позже в ленте или новее — побеждает; ключ переезжает в конец.
          outputs.remove(path);
          outputs[path] = file;
        }
      }
    }
    return (
      outputs: _newestFirst(outputs.values.toList()),
      attachments: _newestFirst(attachments),
    );
  }

  /// Новые первыми; при равном времени — что ниже в ленте, то выше.
  static List<SessionFile> _newestFirst(List<SessionFile> files) {
    final indexed = files.indexed.toList()
      ..sort(((int, SessionFile) a, (int, SessionFile) b) {
        final byTime = b.$2.at.compareTo(a.$2.at);
        return byTime != 0 ? byTime : b.$1.compareTo(a.$1);
      });
    return <SessionFile>[for (final (_, file) in indexed) file];
  }
}
