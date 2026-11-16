import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/app_info.dart';
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
  'note': '22 шт в ОК, арт. 67782',
  'items': 'Молоко, Хлеб',
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
  'date': 'суббота, 14 ноября',
  'pun': 'Дедлайн близко — пора дедлать.',
  'active': '5',
  'overdue': '2',
  'problems': '«Склад» не работает: нет связи с сервером (с 14:05)',
  'other': 'Нода',
  'main': 'Связной',
  'duties': 'оповещения (напоминания, будильник, просрочки, сигналы склада)',
  'team': 'Связной, Лиорио и Нода',
  'appPrepositional': 'Tridot',
  'appGenitive': 'Tridot',
  'skills': '«Задачи» — например, «Покажи задачи»',
  'roles': 'с задачами и со складом',
  'app': 'Склад',
  'role': 'Кладовщик',
  'button': 'Подключить склад',
  'joke': 'Кофе-брейк — это когда кофе работает, а я отдыхаю.',
  'unchecked': '«Пример склада»',
  'shift': 'на 1 час позже',
  'total': '5',
  'day': 'сегодня',
  'tags': '#работа',
  // Действия склада (ADR-013).
  'qty': '3',
  'from': '215-1-1-1',
  'to': '215-3-2-1',
  'marks': 'SV и 1С',
  'no': '318-26',
  'place': 'в 215-1-1-1',
  'list': '1) 64115 · УЦЕНКА · 2 шт.; 2) 64115 · 3 шт.',
  'have': '5',
  'doc': 'ПЕР-00042',
  'left': '2',
  'stage': 'проведён',
  'login': 'ivanov',
  'now': 'petrov',
  // Будильник (ADR-029).
  'details': ' по будням с подписью «спортзал»',
  'duration': '5 минут',
  'when': 'завтра в 7:00',
  'what': 'цены товара',
  // Погода (ADR-030).
  'temp': '+2°',
  'feels': '−1°',
  'sky': 'пасмурно',
  'min': '−3°',
  'chance': '40%',
  'kind': 'дождь',
  'wind': '3 м/с, порывы до 8 м/с',
  'advice': 'Подойдёт тёплая куртка. Пригодится зонт.',
  'last': '21 ноября',
  'right': 'перемещение товара',
  // Навык «Пароли» (ADR-014): только синтетика, без паролей.
  'service': 'Почта',
  'hint': 'CANARY-подсказка',
  'minutes': '5',
  'seconds': '15',
  'code': 'io',
  // Удаление файла сессии (ADR-028).
  'folder': 'Загрузки',
  // Конвертер (ADR-026).
  'format': 'WebM',
  'formats': 'картинки png, jpeg, webp, bmp, gif — в png или jpeg; звук и '
      'видео — в mp3, m4a, wav, mp4',
  'quality': 'MP3, 320 кбит/с',
  'reason': 'в системе нет кодировщика для WebM — подойдёт MP4',
  'strength': 'высокая',
  'bits': '76',
  'weak': '2',
  'reused': '1',
  'places': '3',
  'old': '4',
  'streak': '3',
  'days': '7',
  // Уточняющий вопрос с вариантами.
  'options': '«Пароли» или «Все данные»',
};

/// Подстановки-числа с формами слова: проверяются при 1, 2, 3, 5, 11, 21.
const Set<String> countFacts = <String>{
  'count',
  'active',
  'overdue',
  'total',
  'places',
};
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

    test('путь к ролям — «Мой Связной → Помощники → Роли», как в приложении',
        () {
      // Роли живут во вкладке «Помощники» (ADR-027, поправка): прежнего
      // «Настройки → Роли» нет. Название раздела — AppInfo.hubName: сменят
      // его — тест напомнит поправить и ответы.
      for (final style in ReplyStyles.builtIn) {
        final text = builtInReplyCatalogs[style]!;
        expect(text, isNot(contains('Настройки → Роли')), reason: style);
        const tail = ' → Помощники → Роли';
        var found = 0;
        for (var at = text.indexOf(tail);
            at >= 0;
            at = text.indexOf(tail, at + 1)) {
          found++;
          expect(
            text.substring(0, at).endsWith(AppInfo.hubName),
            isTrue,
            reason: '$style: ${text.substring(math.max(0, at - 20), at)}',
          );
        }
        expect(found, greaterThan(0), reason: style);
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

  test('«Пароли» на «ты»: ни одного «-ите/-йте» вне выбора обращения', () {
    final formal = RegExp(r'[А-Яа-яЁё]+(?:ите|йте|ьте)(?![А-Яа-яЁё])');
    // Не глаголы: «на сайте».
    const nouns = <String>{'сайте'};
    var checked = 0;
    for (final MapEntry(key: id, value: _) in library.neutral.entries.entries) {
      if (!id.startsWith('passwords.')) continue;
      final spec = library.schema[id]!;
      final values = <String, String>{
        for (final name in spec.placeholders)
          name: countFacts.contains(name) ? '2' : facts[name] ?? 'Почта',
      };
      for (final catalog in library.styles) {
        final variants = library.variants(id, catalog.style);
        for (var turn = 0; turn < variants.length; turn++) {
          final text = library.render(
            Reply(id, values),
            ReplyVoice(style: catalog.style, address: ReplyAddress.informal),
            turn: turn,
          );
          expect(
            formal
                .allMatches(text)
                .map((Match m) => m.group(0)!.toLowerCase())
                .where((String w) => !nouns.contains(w)),
            isEmpty,
            reason: '$id/${catalog.style}/$turn: $text',
          );
          checked++;
        }
      }
    }
    expect(checked, greaterThan(100));
  });

  test(
      '«Пароли» зовутся сейфом: слово «хранилище» оставлено за '
      '«Хранилищем контекста»', () {
    final storage = RegExp('хранилищ', caseSensitive: false);
    var checked = 0;
    for (final style in ReplyStyles.builtIn) {
      // Сырой JSON: и тексты, и варианты рода/обращения/эмодзи.
      final raw =
          jsonDecode(File('assets/replies/$style.json').readAsStringSync())
              as Map<String, Object?>;
      final entries = raw['entries']! as Map<String, Object?>;
      for (final MapEntry(:key, :value) in entries.entries) {
        if (!key.startsWith('passwords.')) continue;
        final texts = value is List ? value : <Object?>[value];
        for (final text in texts) {
          expect('$text', isNot(contains(storage)), reason: '$style/$key');
          checked++;
        }
      }
    }
    expect(checked, greaterThan(50));
    // Отрицательная проверка самого правила: «сейф» не ловится.
    expect('Сейф заперт.', isNot(contains(storage)));
    expect('Хранилище заперто.', contains(storage));
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

  group('Связной, Лиорио и Нода (ADR-016)', () {
    test('ReplyVoice.copyWith меняет только род', () {
      const voice = ReplyVoice(
        style: ReplyStyles.brief,
        address: ReplyAddress.informal,
        emoji: false,
      );
      final female = voice.copyWith(gender: ReplyGender.female);
      expect(female.gender, ReplyGender.female);
      expect(female.style, ReplyStyles.brief);
      expect(female.address, ReplyAddress.informal);
      expect(female.emoji, isFalse);
      expect(voice.copyWith().gender, ReplyGender.male);
    });

    test('о помощнике — в его роде, стилем говорящего', () {
      // Краткий стиль называет помощника без слова «помощник».
      for (final style in ReplyStyles.builtIn) {
        if (style == ReplyStyles.brief) continue;
        for (final gender in ReplyGender.values) {
          final text = library.render(
            const Reply('talk.who.helper', <String, String>{
              'name': 'Нода',
              'duties': 'оповещения (напоминания, просрочки)',
            }),
            ReplyVoice(style: style, gender: gender),
          );
          final female = gender == ReplyGender.female;
          expect(
            text,
            contains(female ? 'помощница' : 'помощник'),
            reason: '$style: $text',
          );
          if (!female) {
            expect(text, isNot(contains('помощница')), reason: text);
          }
        }
      }
    });

    test('обратного рода больше нет: о другом — без «{м:…ая|ж:…ой}»', () {
      for (final style in ReplyStyles.builtIn) {
        final raw = File('assets/replies/$style.json').readAsStringSync();
        expect(raw, isNot(contains('{м:вторая')), reason: style);
        expect(raw, isNot(contains('{м:Вторая')), reason: style);
        expect(raw, isNot(contains('{м:Основная')), reason: style);
        // Имя главного в тексте не пишется: его могут переименовать и
        // выбрать род. Название раздела «Мой Связной» — не имя, оно
        // постоянное (AppInfo.hubName).
        expect(
          raw.replaceAll(AppInfo.hubName, ''),
          isNot(contains('Связн')),
          reason: style,
        );
      }
    });

    test('Связной о себе — во всех стилях и в обоих родах', () {
      for (final id in <String>[
        'common.welcome',
        'talk.greet',
        'talk.who.main',
        'talk.set.mainFixed',
        'talk.set.modeSolo',
        'session.handoff.note',
      ]) {
        expect(library.schema.contains(id), isTrue, reason: id);
        for (final style in ReplyStyles.builtIn) {
          expect(
            library.variants(id, style),
            isNotEmpty,
            reason: '$id/$style',
          );
        }
      }
      expect(
        library.render(
          const Reply('session.handoff.note', <String, String>{
            'roles': '«Кладовщик»',
            'name': 'Лиорио',
          }),
          const ReplyVoice(gender: ReplyGender.female),
        ),
        '«Кладовщик» ведёт Лиорио — такие фразы передам',
      );
    });
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
