import 'dart:typed_data';

import '../../connectors/connector.dart';
import '../../gen/gen_model.dart';
import '../../gen/table_ask.dart';
import '../../gen/table_data.dart';
import '../../gen/table_query.dart';
import '../../jobs/extension_card.dart';

/// Читает файл вложения; `null` — файла нет или не прочитать.
typedef TableFileReader = Future<Uint8List?> Function(JobFile file);

/// Модель «Продвинутой», если она скачана и загружена; иначе `null`.
typedef GenModelSource = Future<GenModel?> Function();

/// Навык «Таблица» (ADR-046): вопрос к приложенной таблице CSV. Модель
/// переводит вопрос в запрос, считает [TableQuery.run] — без выдуманных
/// чисел. Только чтение; таблица и вопрос не уходят с устройства.
final class TableConnector implements Connector, ConnectorHealth, IntentTarget {
  const TableConnector({required this.read, required this.model});

  static const String id = 'table';
  static const String commandId = 'table.ask';

  /// С указанием на таблицу и вопросом: явная команда.
  static const double confidence = 0.9;

  final TableFileReader read;
  final GenModelSource model;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Таблица',
        description: 'Отвечает на вопросы по приложенной таблице CSV: '
            'суммы, количество, средние. Нужна модель «Продвинутая».',
        examples: <String>[
          'сколько всего единиц в таблице?',
          'по таблице: на какую сумму поставила Ромашка?',
          'какая средняя цена в таблице',
        ],
        kind: ExtensionKind.skill,
      );

  @override
  Future<HealthReport> health() async => const HealthReport.ok();

  /// Как выполнить команду по подсказке запасного слоя (ADR-045): «по
  /// таблице» + фраза.
  static const Map<String, IntentRecipe> intentRecipes = <String, IntentRecipe>{
    commandId: IntentRecipe(
      carriers: <String>['по таблице'],
      example: 'по таблице: сколько всего строк?',
    ),
  };

  @override
  ConnectorMatch? matchAs(
    String commandId,
    Utterance utterance,
    UtteranceAnalyzer analyze,
  ) =>
      matchByRecipe(this, intentRecipes, commandId, utterance, analyze);

  @override
  String? intentExample(String commandId) => intentRecipes[commandId]?.example;

  static final RegExp _marker = RegExp(
    r'(?<![а-яё])(?:в|по|из)\s+таблиц[еыа](?![а-яё])',
    caseSensitive: false,
  );

  static final RegExp _question = RegExp(
    r'\?|(?<![а-яё])(?:сколько|какой|какая|какое|какие|кто|что|где|чей|'
    r'средн[а-яё]*|сумм[а-яё]*|итог[а-яё]*|максим[а-яё]*|миним[а-яё]*|'
    r'найди|посмотри|посчитай|подсчитай|узнай|покажи)(?![а-яё])',
    caseSensitive: false,
  );

  /// Вопрос с указанием на таблицу; «заполнить таблицу», «таблица
  /// умножения» — не его.
  static bool recognize(String text) =>
      _marker.hasMatch(text) && _question.hasMatch(text);

  @override
  ConnectorMatch? match(Utterance utterance) {
    if (!recognize(utterance.original)) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: commandId,
      confidence: confidence,
      payload: utterance.original,
      // «По таблице» — обращение к источнику, как «склад, …» (ADR-043):
      // «сколько стоит сок по таблице» — не цена товара на складе.
      aliased: true,
    );
  }

  /// Последняя таблица CSV: из сообщения, иначе из недавних сообщений.
  static JobFile? tableFile(AssistantSession session) {
    for (final files in <List<JobFile>>[
      session.attachments,
      session.recentAttachments,
    ]) {
      for (final file in files.reversed) {
        if (!file.folder && file.name.toLowerCase().endsWith('.csv')) {
          return file;
        }
      }
    }
    return null;
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final question = match.payload! as String;
    final file = tableFile(session);
    if (file == null) {
      return session.reply(
        'table.noFile',
        intent: commandId,
        status: AssistantStatus.needsClarification,
      );
    }
    final bytes = await read(file);
    final table = bytes == null ? null : TableData.fromCsv(bytes);
    if (table == null) {
      return session.reply(
        'table.unreadable',
        values: <String, String>{'file': file.name},
        intent: commandId,
        status: AssistantStatus.noAction,
      );
    }
    final gen = await model();
    if (gen == null) {
      return session.reply(
        'table.noModel',
        intent: commandId,
        status: AssistantStatus.noAction,
      );
    }
    final TableAnswer? answer;
    try {
      answer = await TableAsk.ask(gen, table, question);
    } on Object {
      return session.reply(
        'table.failed',
        intent: commandId,
        status: AssistantStatus.noAction,
      );
    }
    if (answer == null) {
      return session.reply(
        'table.notUnderstood',
        values: <String, String>{'columns': table.columns.join(', ')},
        intent: commandId,
        status: AssistantStatus.noAction,
      );
    }
    final value = answerText(answer);
    if (value == null) {
      return session.reply(
        'table.nothing',
        values: <String, String>{'how': describe(answer.query)},
        intent: commandId,
        status: AssistantStatus.completed,
      );
    }
    return session.reply(
      'table.answer',
      values: <String, String>{
        'answer': value,
        'how': describe(answer.query),
        'rows': '${answer.matched}',
        'file': file.name,
      },
      intent: commandId,
      status: AssistantStatus.completed,
    );
  }

  /// Ответ строкой; `null` — подходящих строк или чисел нет.
  static String? answerText(TableAnswer answer) {
    final values = answer.values;
    if (values != null) {
      if (values.isEmpty) return null;
      const limit = 10;
      final shown = values.take(limit).join(', ');
      return values.length > limit
          ? '$shown и ещё ${values.length - limit}'
          : shown;
    }
    final v = answer.value;
    if (v == null) return null;
    return formatNumber(v);
  }

  /// «15 500», «75», «4 510,5» — разряды узким пробелом, дробь до двух знаков.
  static String formatNumber(num v) {
    final rounded = (v * 100).round() / 100;
    final negative = rounded < 0;
    final abs = rounded.abs();
    final whole = abs.truncate();
    final frac = ((abs - whole) * 100).round();
    final digits = '$whole';
    final groups = <String>[];
    for (var end = digits.length; end > 0; end -= 3) {
      groups.insert(0, digits.substring(end - 3 < 0 ? 0 : end - 3, end));
    }
    final body = groups.join(' ');
    final tail = frac == 0
        ? ''
        : ',${frac.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
    return '${negative ? '−' : ''}$body$tail';
  }

  /// Что посчитано: «сумма «сумма», где «поставщик» содержит «Ромашка»».
  static String describe(TableQuery q) {
    final what = switch (q.op) {
      TableOp.sum => 'сумма «${q.column}»',
      TableOp.count => 'число строк',
      TableOp.avg => 'среднее «${q.column}»',
      TableOp.min => 'минимум «${q.column}»',
      TableOp.max => 'максимум «${q.column}»',
      TableOp.list => 'значения «${q.column}»',
    };
    if (q.filters.isEmpty) return what;
    final conditions = q.filters.map((f) {
      final how = switch (f.cmp) {
        TableCmp.eq => '=',
        TableCmp.ne => '≠',
        TableCmp.gt => '>',
        TableCmp.lt => '<',
        TableCmp.ge => '≥',
        TableCmp.le => '≤',
        TableCmp.contains => 'содержит',
      };
      return '«${f.column}» $how «${f.value}»';
    }).join(' и ');
    return '$what, где $conditions';
  }
}
