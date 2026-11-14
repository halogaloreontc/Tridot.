/// Навык-расширение «Архиватор» (docs/PLANS.md, «Расширения»): ZIP —
/// создать (в том числе папку целиком), распаковать, посмотреть
/// содержимое. Выключен по умолчанию, ведёт его Лиорио (ведущий
/// расширений, ADR-016). Фраза открывает в чате карточку-форму
/// ([ExtensionCard]); работа идёт только по кнопке «Запустить».
library;

import '../../connectors/connector.dart';
import '../../jobs/extension_card.dart';

export 'zip_ops.dart';

final class ArchiverConnector implements Connector, FormConnector {
  ArchiverConnector();

  static const String id = ExtensionForms.archiver;

  static const String zipCommand = 'archiver.zip';
  static const String extractCommand = 'archiver.extract';
  static const String listCommand = 'archiver.list';

  /// Глагол и объект: явная команда.
  static const double confidence = 0.9;

  int _counter = 0;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Архиватор',
        description: 'ZIP: создать архив из файлов (на компьютере — и из '
            'целой папки), распаковать, посмотреть содержимое. Исходные '
            'файлы не меняются.',
        examples: <String>[
          'сожми в zip',
          'распакуй архив',
          'покажи что в архиве',
        ],
        kind: ExtensionKind.skill,
        defaultEnabled: false,
        offHint: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    final command = ArchiverPhrases.commandOf(utterance);
    if (command == null) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: command,
      confidence: confidence,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async =>
      _form(_actionOf(match.commandId), session, prefill: true);

  @override
  AssistantResponse openForm(String? action, AssistantSession session) =>
      _form(action ?? ExtensionForms.zip, session, prefill: false);

  static String _actionOf(String commandId) => switch (commandId) {
        extractCommand => ExtensionForms.extract,
        listCommand => ExtensionForms.list,
        _ => ExtensionForms.zip,
      };

  AssistantResponse _form(
    String action,
    AssistantSession session, {
    required bool prefill,
  }) {
    final now = session.clock.now();
    final card = ExtensionCard(
      id: 'j${now.microsecondsSinceEpoch}_${_counter++}',
      extensionId: id,
      updatedAt: now,
      values: <String, Object?>{'action': action},
    );
    final files = prefill ? _prefill(action, session) : const <JobFile>[];
    if (files.isNotEmpty) card.setValue('files', files);
    return session.reply(
      'archiver.form.$action',
      intent: switch (action) {
        ExtensionForms.extract => extractCommand,
        ExtensionForms.list => listCommand,
        _ => zipCommand,
      },
      status: AssistantStatus.completed,
      job: card,
    );
  }

  /// Файлы, найденные в сессии: для «распакуй» и «посмотри» — последний
  /// архив .zip (из сообщения, иначе из недавних), для «сожми» — файлы
  /// самого сообщения.
  static List<JobFile> _prefill(String action, AssistantSession session) {
    if (action == ExtensionForms.zip) {
      return List<JobFile>.of(session.attachments);
    }
    for (final files in <List<JobFile>>[
      session.attachments,
      session.recentAttachments,
    ]) {
      final zip = files.reversed.where((JobFile f) => f.isZip).firstOrNull;
      if (zip != null) return <JobFile>[zip];
    }
    return const <JobFile>[];
  }
}

/// Фразы архиватора: повелительное наклонение и объект — «сожми в zip»,
/// «распакуй архив», «покажи что в архиве». Инфинитив («сжать отчёт»),
/// задача («сдать документы в архив», «напомни распаковать коробки») и
/// покупка («купить архив») — не его фразы.
abstract final class ArchiverPhrases {
  static const Set<String> _fillers = <String>{
    'пожалуйста',
    'давай',
    'теперь',
    'а',
    'и',
    'ну',
    'еще',
  };

  /// Создать архив: нужен объект.
  static const Set<String> _zipVerbs = <String>{
    'сожми',
    'сожмите',
    'запакуй',
    'запакуйте',
    'упакуй',
    'упакуйте',
    'создай',
    'создайте',
    'сделай',
    'сделайте',
  };

  /// Создать архив: объект не нужен.
  static const Set<String> _zipOnly = <String>{
    'заархивируй',
    'заархивируйте',
    'архивируй',
    'архивируйте',
    'зазипуй',
  };

  static const Set<String> _extractVerbs = <String>{
    'распакуй',
    'распакуйте',
    'разожми',
    'разожмите',
    'извлеки',
    'извлеките',
  };

  static const Set<String> _extractOnly = <String>{
    'разархивируй',
    'разархивируйте',
  };

  static const Set<String> _listVerbs = <String>{
    'покажи',
    'покажите',
    'посмотри',
    'посмотрите',
    'открой',
    'откройте',
    'глянь',
    'просмотри',
  };

  static bool _isArchive(String w) =>
      w.startsWith('архив') ||
      w == 'zip' ||
      (w.startsWith('зип') && w.length <= 5);

  static bool _isFiles(String w) =>
      w.startsWith('файл') || w.startsWith('папк');

  /// Команда архиватора во фразе или `null`.
  static String? commandOf(Utterance utterance) {
    final words = utterance.words;
    if (words.isEmpty || words.length > 12) return null;
    // Задача, напоминание или покупка со словом «архив» — не команда.
    if (words.any(
      (String w) =>
          w.startsWith('задач') ||
          w.startsWith('напомн') ||
          w.startsWith('напомин') ||
          w.startsWith('куп'),
    )) {
      return null;
    }
    var start = 0;
    while (start < words.length - 1 && _fillers.contains(words[start])) {
      start++;
    }
    final verb = words[start];
    final rest = words.sublist(start + 1);
    final archive = rest.any(_isArchive);
    final files = rest.any(_isFiles);
    if (_zipOnly.contains(verb)) return ArchiverConnector.zipCommand;
    if (_extractOnly.contains(verb)) return ArchiverConnector.extractCommand;
    if (_zipVerbs.contains(verb)) {
      final make = verb.startsWith('созда') || verb.startsWith('сдела');
      // «Создай архив», «сделай zip»; «сожми файлы», «упакуй в zip».
      if (make
          ? archive && rest.isNotEmpty && _isArchive(rest.first)
          : archive || files) {
        return ArchiverConnector.zipCommand;
      }
      return null;
    }
    if (_extractVerbs.contains(verb)) {
      if (verb.startsWith('извлек') ? archive : archive || files) {
        return ArchiverConnector.extractCommand;
      }
      return null;
    }
    if (_listVerbs.contains(verb) && archive) {
      return ArchiverConnector.listCommand;
    }
    // «Что в архиве?», «что внутри zip».
    if (verb == 'что' && archive && rest.length <= 3) {
      return ArchiverConnector.listCommand;
    }
    return null;
  }
}
