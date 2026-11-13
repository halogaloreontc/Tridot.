import '../connectors/utterance.dart';

/// Вариант ответа на уточняющий вопрос ([Clarification]).
final class ClarifyOption {
  const ClarifyOption({
    required this.label,
    required this.text,
    this.answers = const <String>{},
    this.connectorId,
  });

  /// Подпись кнопки и ответ, который её заменяет: «Пароли», «Все данные».
  /// Нажатие кнопки отправляет именно эту подпись — тот же путь, что
  /// набранный текст.
  final String label;

  /// Каноническая команда, которую маршрутизатор разберёт заново, если
  /// выбран этот вариант: «сделай резервную копию сейфа». Только шаблон
  /// коннектора, не фраза пользователя: в нём не может оказаться секрета.
  final String text;

  /// Слова ответа, по которым узнаётся вариант, кроме подписи: «паролей»,
  /// «сейф». Нижний регистр, «е» вместо «ё».
  final Set<String> answers;

  /// Коннектор, который, скорее всего, выполнит [text]; для голоса и
  /// подсказок. `null` — неизвестно.
  final String? connectorId;
}

/// Уточняющий вопрос с вариантами: «Копию чего: паролей или всех данных?».
///
/// Коннектор кладёт его в `PendingConfirmation.payload` через
/// `AssistantSession.requestConfirmation` (жизненный цикл — тот же:
/// ожидание живёт одно сообщение, снимается сменой чата и выключением
/// коннектора) и отдаёт в `AssistantResponse.clarification` — интерфейс
/// рисует кнопки вариантов. Маршрутизатор разбирает ответ до обычного
/// разбора: выбранный вариант ([choose]) — заново как [ClarifyOption.text],
/// «нет» — отмена, «да» или «хорошо» — переспрос с теми же вариантами,
/// любая другая фраза снимает вопрос и разбирается как обычно.
final class Clarification {
  Clarification({required this.questionId, required this.options})
      : assert(options.length >= 2, 'Уточнение — выбор из двух и больше');

  /// Запись каталога ответов с вопросом: `data.clarify.backup`.
  final String questionId;

  final List<ClarifyOption> options;

  /// Варианты для текста ответа: «Пароли» или «Все данные».
  String get optionsText {
    final quoted = <String>[
      for (final option in options) '«${option.label}»',
    ];
    if (quoted.length == 2) return '${quoted.first} или ${quoted.last}';
    return '${quoted.sublist(0, quoted.length - 1).join(', ')} или '
        '${quoted.last}';
  }

  /// Порядковые ответы: «первое», «2».
  static const List<Set<String>> _ordinals = <Set<String>>[
    <String>{'1', 'первое', 'первый', 'первая', 'первую', 'один'},
    <String>{'2', 'второе', 'второй', 'вторая', 'вторую', 'два'},
    <String>{'3', 'третье', 'третий', 'третья', 'третью', 'три'},
  ];

  /// Слова, которые не меняют выбор: «давай пароли», «вариант 2», «про
  /// данные».
  static const Set<String> _filler = <String>{
    'давай',
    'вариант',
    'про',
    'это',
    'ну',
    'пожалуйста',
    'конечно',
    'наверное',
    'мне',
    'нужно',
    'нужны',
    'надо',
    'для',
    'о',
    'об',
    'да',
    'только',
    'копию',
    'копия',
    'копии',
    'лучше',
    'тогда',
    'а',
    'их',
  };

  /// Какой вариант выбран ответом [utterance]; `null` — это не выбор
  /// (вопрос, отрицание, посторонняя фраза, слово не из ответов варианта
  /// или слова сразу двух вариантов).
  ClarifyOption? choose(Utterance utterance) {
    if (utterance.isQuestion || utterance.quotedTitles.isNotEmpty) {
      return null;
    }
    final words = utterance.words;
    if (words.isEmpty || words.length > 5) return null;
    if (words.contains('не') || words.contains('нет')) return null;
    final phrase = words.join(' ');
    for (final option in options) {
      if (_normalize(option.label) == phrase) return option;
    }
    final meaningful = <String>[
      for (final word in words)
        if (!_filler.contains(word)) word,
    ];
    if (meaningful.length == 1) {
      for (var i = 0; i < options.length && i < _ordinals.length; i++) {
        if (_ordinals[i].contains(meaningful.single)) return options[i];
      }
    }
    if (meaningful.isEmpty) return null;
    // Выбор — только если каждое значимое слово относится к одному
    // варианту: «давай пароли», «все данные». Любое другое слово —
    // «покажи задачи», «закрой сейф», «пароль от почты», «удали все
    // данные» — значит, это новая просьба: вопрос снимается, фраза
    // разбирается как обычно (и фраза с паролем не становится ответом
    // на меню).
    ClarifyOption? chosen;
    for (final option in options) {
      final label = _normalize(option.label).split(' ').toSet();
      final all = meaningful.every(
        (String w) => option.answers.contains(w) || label.contains(w),
      );
      if (!all) continue;
      if (chosen != null) return null;
      chosen = option;
    }
    return chosen;
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll('ё', 'е').trim();
}
