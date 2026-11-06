import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/replies/builtin_replies.g.dart';
import 'package:local_assistant/core/replies/reply_library.dart';

/// Правдоподобные факты для каждой подстановки: числа — числами, чтобы
/// работала форма числа.
const Map<String, String> facts = <String, String>{
  'title': 'Купить хлеб «Бородинский»',
  'due': 'завтра в 10:00',
  'project': 'работа',
  'query': 'отчёт',
  'name': 'звонок',
  'candidates': '«Позвонить маме» или «Позвонить клиенту»',
  'count': '3',
  'titles': '«Отчёт», «Счёт»',
  'example': 'Добавь задачу позвонить клиенту завтра в 11:00',
  'first': 'Задачи',
  'second': 'Склад',
  'error': 'Хранилище недоступно',
  'expr': '10 / 3',
  'result': '3,333333333',
  'max': '200',
  'daypart': 'Добрый вечер',
  'said': 'Доброе утро',
  'time': '22:00',
  'pun': 'Дедлайн близко — пора дедлать.',
  'active': '5',
  'overdue': '2',
  'problems': '«Склад» не работает: нет связи с сервером (с 14:05)',
  'other': 'Noda',
  'skills': '«Задачи» — например, «Покажи задачи»',
  'joke': 'Кофе-брейк — это когда кофе работает, а я отдыхаю.',
  'unchecked': '«Пример склада»',
};

/// Подстановки-числа с формами слова: проверяются при 1, 2, 3, 5, 11, 21.
const Set<String> countFacts = <String>{'count', 'active', 'overdue'};
const List<String> countSamples = <String>['1', '2', '3', '5', '11', '21'];

String catalog({
  String style = 'friendly',
  required String entries,
}) =>
    '{"format":"assistant-replies/1","style":"$style","title":"Т",'
    '"entries":{$entries}}';

List<String> errorsOf(String source) =>
    ReplyFormat.parse(source, schema: ReplyLibrary.builtIn.schema).errors;

void main() {
  final library = ReplyLibrary.builtIn;

  group('встроенные каталоги', () {
    test('копия в builtin_replies.g.dart совпадает с assets/replies', () {
      final files = Directory('assets/replies')
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))
          .map((File f) => f.uri.pathSegments.last.replaceAll('.json', ''))
          .toSet();
      expect(files, ReplyStyles.builtIn.toSet());
      for (final style in ReplyStyles.builtIn) {
        expect(
          builtInReplyCatalogs[style],
          File('assets/replies/$style.json').readAsStringSync(),
          reason: '$style: запустите dart run tool/gen_replies.dart',
        );
      }
    });

    test('каталоги зарегистрированы в pubspec.yaml', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('- assets/replies/'),
      );
    });

    test('четыре стиля, каждая запись стиля есть в нейтральном', () {
      expect(
        library.styles.map((ReplyCatalog c) => c.style),
        ReplyStyles.builtIn,
      );
      for (final catalog in library.styles) {
        expect(
          library.neutral.entries.keys,
          containsAll(catalog.entries.keys),
          reason: catalog.style,
        );
        for (final variants in catalog.entries.values) {
          expect(variants.length, inInclusiveRange(1, 3));
        }
      }
    });

    test('нейтральный стиль: один вариант и нет эмодзи', () {
      for (final MapEntry(:key, :value) in library.neutral.entries.entries) {
        expect(value, hasLength(1), reason: key);
        expect(value.single.hasEmoji, isFalse, reason: key);
      }
    });

    test('нейтральный, Liorio, «вы» — прежние тексты слово в слово', () {
      String neutral(String id, [Map<String, String> v = const {}]) =>
          library.render(Reply(id, v), const ReplyVoice());
      expect(
        neutral('common.welcome', <String, String>{'example': 'X'}),
        'Я готов к работе. Создайте задачу, например: X',
      );
      expect(
        neutral('task.created.withDueAndProject', <String, String>{
          'title': 'Отчёт',
          'due': 'завтра',
          'project': 'работа',
        }),
        'Создал задачу «Отчёт» на завтра в проекте #работа.',
      );
      expect(
        neutral('router.ambiguous', <String, String>{
          'first': 'Задачи',
          'second': 'Склад',
        }),
        'Не понял, к чему относится команда: «Задачи» или «Склад»? '
        'Уточните, пожалуйста.',
      );
      expect(
        neutral('task.ask.didYouMean', <String, String>{'title': 'Т'}),
        'Вы про задачу «Т»? Напишите её название точнее или выберите '
        'задачу в списке.',
      );
      expect(
        neutral('task.title.multiple'),
        'В команде несколько названий. Давайте по одной задаче за раз.',
      );
    });

    test('Noda и «ты» меняют только обёртку', () {
      expect(
        library.render(
          const Reply('task.notFound', <String, String>{'query': 'хлеб'}),
          const ReplyVoice(
            gender: ReplyGender.female,
            address: ReplyAddress.informal,
          ),
        ),
        'Не нашла активную задачу «хлеб».',
      );
      expect(
        library.render(
          const Reply('task.ask.didYouMean', <String, String>{'title': 'Т'}),
          const ReplyVoice(address: ReplyAddress.informal),
        ),
        'Ты про задачу «Т»? Напиши её название точнее или выбери задачу '
        'в списке.',
      );
    });
  });

  test(
      'инвариант: в любом стиле, роде, обращении и с эмодзи или без '
      'факты на месте, вопросы — вопросы, «≈» не пропадает', () {
    var checked = 0;
    for (final MapEntry(key: id, value: base)
        in library.neutral.entries.entries) {
      final spec = library.schema[id]!;
      final counted = spec.placeholders.any(countFacts.contains);
      for (final sample in counted ? countSamples : const <String>['']) {
        final values = <String, String>{
          for (final name in spec.placeholders)
            name: countFacts.contains(name)
                ? sample
                : facts[name] ?? (throw StateError('нет факта для {$name}')),
        };
        final neutralText = base.single.render(values);
        final neutralEnds = ReplySchema.endsSentence(neutralText);
        for (final catalog in library.styles) {
          final variants = library.variants(id, catalog.style);
          for (var turn = 0; turn < variants.length; turn++) {
            for (final gender in ReplyGender.values) {
              for (final address in ReplyAddress.values) {
                for (final emoji in <bool>[true, false]) {
                  final text = library.render(
                    Reply(id, values),
                    ReplyVoice(
                      style: catalog.style,
                      gender: gender,
                      address: address,
                      emoji: emoji,
                    ),
                    turn: turn,
                  );
                  final where = '$id/${catalog.style}/$turn/$gender/$address/'
                      '${emoji ? 'эмодзи' : 'без эмодзи'}: $text';
                  expect(text.trim(), isNotEmpty, reason: where);
                  for (final value in values.values) {
                    expect(text, contains(value), reason: where);
                  }
                  if (neutralText.contains('?')) {
                    expect(text, contains('?'), reason: where);
                  }
                  if (neutralText.contains('≈')) {
                    expect(text, contains('≈'), reason: where);
                  }
                  if (!emoji) {
                    expect(
                      ReplyTemplate.pictographs.hasMatch(text),
                      isFalse,
                      reason: where,
                    );
                    // Конец предложения не пропадает вместе с эмодзи.
                    if (neutralEnds) {
                      expect(
                        ReplySchema.endsSentence(text),
                        isTrue,
                        reason: where,
                      );
                    }
                    // Убранная метка не склеивает слова и не оставляет
                    // двойных пробелов.
                    expect(text, isNot(contains('  ')), reason: where);
                  }
                  if (catalog.style == ReplyStyles.brief) {
                    expect(
                      text.length,
                      lessThanOrEqualTo(
                        library
                            .render(
                              Reply(id, values),
                              ReplyVoice(gender: gender, address: address),
                            )
                            .length,
                      ),
                      reason: 'краткий не длиннее нейтрального: $where',
                    );
                  }
                  checked++;
                }
              }
            }
          }
        }
      }
    }
    expect(checked, greaterThan(1000));
  });

  group('выбор варианта', () {
    const reply = Reply('task.created', <String, String>{'title': 'Хлеб'});
    const voice = ReplyVoice(style: ReplyStyles.friendly);

    test('детерминированный: тот же номер реплики — тот же текст', () {
      expect(
        library.render(reply, voice, turn: 7),
        library.render(reply, voice, turn: 7),
      );
    });

    test('соседние реплики звучат по-разному', () {
      expect(
        library.render(reply, voice, turn: 1),
        isNot(library.render(reply, voice, turn: 2)),
      );
    });

    test('нет записи в стиле — нейтральный текст', () {
      final custom = ReplyFormat.parse(
        catalog(
          style: 'mine',
          entries: '"task.completed": "Сделано: «{title}»."',
        ),
        schema: library.schema,
      ).catalog!;
      final withMine = library.withStyles(<ReplyCatalog>[custom]);
      expect(
        withMine.render(reply, const ReplyVoice(style: 'mine')),
        'Создал задачу «Хлеб».',
      );
      expect(
        withMine.render(
          const Reply('task.completed', <String, String>{'title': 'Хлеб'}),
          const ReplyVoice(style: 'mine'),
        ),
        'Сделано: «Хлеб».',
      );
    });

    test('неизвестный стиль — нейтральный', () {
      expect(
        library.render(reply, const ReplyVoice(style: 'нет-такого')),
        'Создал задачу «Хлеб».',
      );
    });

    test('стабильный хеш не зависит от запуска', () {
      expect(ReplyLibrary.stableHash('task.created'), 465310546);
    });
  });

  group('ошибки загрузки каталога', () {
    test('неизвестная подстановка', () {
      expect(
        errorsOf(catalog(entries: '"task.created": "Готово: {name}."')),
        contains(contains('неизвестная подстановка {name}')),
      );
    });

    test('потерян факт в одном из вариантов рода', () {
      expect(
        errorsOf(
          catalog(
            entries: '"task.created": "{м:Создал «{title}»|ж:Создала}."',
          ),
        ),
        contains(contains('{title}')),
      );
    });

    test('уточнение перестало быть вопросом', () {
      expect(
        errorsOf(
          catalog(entries: '"task.ask.confirmComplete": "Отмечаю «{title}»."'),
        ),
        contains(contains('вопросом')),
      );
    });

    test('«≈» убран из приближённого ответа', () {
      expect(
        errorsOf(
          catalog(entries: '"calc.result.approx": "{expr} = {result}"'),
        ),
        contains(contains('«≈»')),
      );
    });

    test('сломанная разметка, неизвестный id, эмодзи вне метки', () {
      final errors = errorsOf(
        catalog(
          entries: '"task.created": "{м:Создал «{title}»", '
              '"task.unknown": "x", '
              '"task.completed": "«{title}» ✅", '
              '"task.list.empty": ["a", "b", "c", "d"]',
        ),
      );
      expect(errors, contains(contains('entries.task.created')));
      expect(errors, contains(contains('неизвестная запись')));
      expect(errors, contains(contains('вне метки')));
      expect(errors, contains(contains('от 1 до 3')));
    });

    test('факт внутри формы числа или число словом — ошибка', () {
      // count=2 дал бы «две задачи» без числа, count=1 — без {titles}.
      expect(
        errorsOf(
          catalog(
            entries: '"task.overdue": "Просрочены {мн:count|одна задача|'
                'две задачи|{count} задач}: {titles}."',
          ),
        ),
        contains(contains('{count}')),
      );
      expect(
        errorsOf(
          catalog(
            entries: '"task.overdue": "{count} {мн:count|задача: {titles}|'
                'задачи: {titles}|задач}."',
          ),
        ),
        contains(contains('{titles}')),
      );
      // Подстановка во всех формах — можно.
      expect(
        errorsOf(
          catalog(
            entries: '"task.overdue": "{мн:count|{count} задача|{count} '
                'задачи|{count} задач}: {titles}."',
          ),
        ),
        isEmpty,
      );
    });

    test('без эмодзи конец предложения не пропадает', () {
      expect(
        errorsOf(
          catalog(entries: '"task.created": "Готово, «{title}» {э:✅}"'),
        ),
        contains(contains('кончаться')),
      );
      expect(
        errorsOf(
          catalog(entries: '"task.created": "Готово, «{title}». {э:✅}"'),
        ),
        isEmpty,
      );
      // У нейтрального без точки в конце («{expr} = {result}») — можно.
      expect(
        errorsOf(catalog(entries: '"calc.result": "{expr} = {result} {э:🧮}"')),
        isEmpty,
      );
    });

    test('метка эмодзи, приклеенная к словам, — ошибка загрузки', () {
      expect(
        errorsOf(catalog(entries: '"task.created": "Готово{э:✅}«{title}»."')),
        contains(contains('приклеена')),
      );
    });

    test('предупреждения и вопросы-подтверждения отмечены в нейтральном', () {
      for (final id in <String>[
        'calc.divisionByZero',
        'calc.tooBig',
        'calc.negativeRoot',
        'task.due.inPast',
        'task.ask.confirmComplete',
        'talk.status.problem',
        'common.confirm.unclear',
      ]) {
        expect(library.schema[id]!.protected, isTrue, reason: id);
      }
      expect(library.schema['task.created']!.protected, isFalse);
      // Встроенный стиль может сказать предупреждение по-своему.
      expect(
        errorsOf(
          catalog(entries: '"calc.divisionByZero": "На ноль — никак."'),
        ),
        isEmpty,
      );
      // Поле protected — только у нейтрального каталога.
      expect(
        ReplyFormat.parse(
          '{"format":"assistant-replies/1","style":"friendly","title":"Т",'
          '"protected":["task.created"],"entries":{}}',
          schema: library.schema,
        ).errors,
        contains(contains('protected')),
      );
    });

    test('битый встроенный каталог не принимается', () {
      expect(
        () => ReplyLibrary.fromSources(<String>[
          catalog(style: 'neutral', entries: '"task.created": "{title"'),
        ]),
        throwsFormatException,
      );
    });

    test('записи коннектора: разметка проверяется, встроенный id занят', () {
      expect(
        library.withEntries(
          <String, String>{'demo.hello': 'Привет, {who}!'},
        ).render(
          const Reply('demo.hello', <String, String>{'who': 'мир'}),
          const ReplyVoice(style: ReplyStyles.business),
        ),
        'Привет, мир!',
      );
      expect(
        () => library.withEntries(<String, String>{'task.created': 'x'}),
        throwsFormatException,
      );
      expect(
        () => library.withEntries(<String, String>{'demo.bad': '{м:x}'}),
        throwsFormatException,
      );
    });
  });
}
