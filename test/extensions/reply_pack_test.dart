import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/replies/reply_library.dart';

String repliesPack({
  String id = 'replies.pirate',
  Object? entries,
}) =>
    jsonEncode(<String, Object?>{
      'format': 'assistant-pack/1',
      'id': id,
      'type': 'replies',
      'title': 'Пиратский',
      'author': 'Я',
      'language': 'ru',
      'version': '1.0.0',
      'description': 'Йо-хо-хо.',
      'entries': entries ??
          <String, Object?>{
            'task.created': <String>[
              'Йо-хо! {м:Записал|ж:Записала} в судовой журнал: «{title}». {э:🏴‍☠️}',
              'Так точно, «{title}» на борту!',
            ],
            'task.ask.rescheduleWhen': 'На какую склянку переносим?',
          },
    });

final class _Echo implements Connector {
  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'echo',
        title: 'Эхо',
        description: 'Повторяет.',
        replies: <String, String>{
          'echo.said': 'Вы сказали: {text}.',
          'echo.refused': 'Повторять это нельзя.',
        },
        protectedReplies: <String>{'echo.refused'},
      );

  @override
  ConnectorMatch? match(Utterance utterance) => null;

  @override
  Future<AssistantResponse> run(ConnectorMatch m, AssistantSession s) =>
      throw UnimplementedError();
}

void main() {
  test('пак ответов разбирается и даёт стиль', () {
    final result = PackFormat.parse(repliesPack());
    expect(result.errors, isEmpty);
    final pack = result.pack!;
    expect(pack.type, PackFormat.repliesType);
    expect(pack.entries, isEmpty);
    final catalog = pack.replyCatalog();
    expect(catalog.style, 'replies.pirate');
    expect(catalog.title, 'Пиратский');
    expect(catalog.builtIn, isFalse);
    final library = ReplyLibrary.builtIn.withStyles(<ReplyCatalog>[catalog]);
    expect(
      library.render(
        const Reply('task.created', <String, String>{'title': 'Ром'}),
        const ReplyVoice(style: 'replies.pirate', gender: ReplyGender.female),
        turn: 1,
      ),
      anyOf(
        'Йо-хо! Записала в судовой журнал: «Ром». 🏴‍☠️',
        'Так точно, «Ром» на борту!',
      ),
    );
    // Записи, которых нет в паке, — нейтральные.
    expect(
      library.render(
        const Reply('task.list.empty'),
        const ReplyVoice(style: 'replies.pirate'),
      ),
      'Активных задач пока нет.',
    );
  });

  test('сохранённый пак ответов разбирается снова тем же', () {
    final pack = PackFormat.parse(repliesPack()).pack!;
    final again = PackFormat.parse(pack.encode()).pack!;
    expect(again.replies, pack.replies);
    expect(again.encode(), pack.encode());
  });

  group('проверка пака ответов', () {
    List<String> errors(Object? entries, {String id = 'replies.pirate'}) =>
        PackFormat.parse(repliesPack(entries: entries, id: id)).errors;

    test('неизвестная запись и неизвестная подстановка', () {
      final found = errors(<String, Object?>{
        'task.unknown': 'x',
        'task.created': 'Готово: {name}',
      });
      expect(found, contains(contains('entries.task.unknown')));
      expect(found, contains(contains('неизвестная подстановка {name}')));
    });

    test('сломанная разметка и потерянный факт', () {
      final found = errors(<String, Object?>{
        'task.created': '{м:Записал «{title}»',
        'task.completed': <String>['«{title}» готово', 'Готово!'],
      });
      expect(found, contains(contains('не закрыта')));
      expect(found, contains(contains('entries.task.completed[1]')));
    });

    test('вопрос остаётся вопросом, эмодзи только в метке', () {
      final found = errors(<String, Object?>{
        'task.ask.rescheduleWhen': 'Переношу.',
        'task.created': '«{title}» ⚓',
      });
      expect(found, contains(contains('вопросом')));
      expect(found, contains(contains('вне метки')));
    });

    test('entries — объект, не список; не пустой; до 3 вариантов', () {
      expect(errors(<Object?>[]), contains(contains('объект')));
      expect(errors(<String, Object?>{}), contains(contains('ни одной')));
      expect(
        errors(<String, Object?>{
          'task.list.empty': <String>['a', 'b', 'c', 'd'],
        }),
        contains(contains('от 1 до 3')),
      );
      expect(
        errors(<String, Object?>{'task.list.empty': 'а' * 501}),
        contains(contains('длиннее 500')),
      );
    });

    test('предупреждения и вопросы-подтверждения пак не переопределяет', () {
      // «Готово!» вместо «На ноль делить нельзя» и «Отметил» вместо вопроса.
      for (final entries in <Map<String, Object?>>[
        <String, Object?>{'calc.divisionByZero': 'Готово!'},
        <String, Object?>{
          'task.ask.confirmComplete': 'Что? Отметил «{title}» выполненной.',
        },
        <String, Object?>{'task.due.inPast': 'Хорошо.'},
        <String, Object?>{'talk.status.problem': 'Всё хорошо: {problems}?'},
      ]) {
        expect(
          errors(entries),
          contains(contains('не переопределяет')),
          reason: '$entries',
        );
      }
    });

    test('без эмодзи пак не теряет точку и не склеивает слова', () {
      expect(
        errors(<String, Object?>{'task.created': 'Готово{э:✅}«{title}»'}),
        contains(contains('приклеена')),
      );
      expect(
        errors(<String, Object?>{'task.created': 'Готово, «{title}» {э:✅}'}),
        contains(contains('кончаться')),
      );
    });

    test('факт в форме числа не теряется', () {
      expect(
        errors(<String, Object?>{
          'task.overdue':
              'Просрочены {мн:count|одна задача|две задачи|{count} задач}: '
                  '{titles}.',
        }),
        contains(contains('{count}')),
      );
    });

    test('id встроенного стиля занят', () {
      expect(
        errors(null, id: 'friendly'),
        contains(contains('встроенным стилем')),
      );
    });

    test('общие пределы пака: 1 МБ', () {
      final big = <String, Object?>{
        for (var i = 0; i < 3000; i++) 'task.x$i': 'а' * 400,
      };
      expect(errors(big), <String>['Файл пака больше 1 МБ.']);
    });
  });

  group('в реестре', () {
    Future<ExtensionRegistry> registry() async {
      final packs = PackStore.memory(builtIn: <String>[repliesPack()]);
      final registry = ExtensionRegistry(
        connectors: <Connector>[_Echo()],
        packs: packs,
      );
      await packs.load();
      return registry;
    }

    test('включённый пак ответов — ещё один стиль, выключенный — нет',
        () async {
      final extensions = await registry();
      expect(
        extensions.replyLibrary.styles.map((ReplyCatalog c) => c.style),
        <String>[...ReplyStyles.builtIn, 'replies.pirate'],
      );
      extensions.apply(extensions.choiceWith('replies.pirate', false));
      expect(extensions.replyLibrary.hasStyle('replies.pirate'), isFalse);
      // Выключенный стиль не ломает ответы: говорит нейтрально.
      expect(
        extensions.replyLibrary.render(
          const Reply('task.list.empty'),
          const ReplyVoice(style: 'replies.pirate'),
        ),
        'Активных задач пока нет.',
      );
    });

    test('записи коннекторов в каталоге и в проверке паков', () async {
      final extensions = await registry();
      expect(
        extensions.replyLibrary.render(
          const Reply('echo.said', <String, String>{'text': 'да'}),
          const ReplyVoice(style: 'replies.pirate'),
        ),
        'Вы сказали: да.',
      );
      final result = await extensions.importPack(
        repliesPack(
          id: 'replies.echo',
          entries: <String, Object?>{'echo.said': 'Эхо: «{text}»!'},
        ),
      );
      expect(result.errors, isEmpty);
      expect(
        extensions.replyLibrary.render(
          const Reply('echo.said', <String, String>{'text': 'да'}),
          const ReplyVoice(style: 'replies.echo'),
        ),
        'Эхо: «да»!',
      );
      final bad = await extensions.importPack(
        repliesPack(
          id: 'replies.bad',
          entries: <String, Object?>{'echo.said': 'Эхо: {who}'},
        ),
      );
      expect(bad.errors, contains(contains('неизвестная подстановка {who}')));
      // Предупреждение коннектора (protectedReplies) пак не переопределяет.
      final warn = await extensions.importPack(
        repliesPack(
          id: 'replies.warn',
          entries: <String, Object?>{'echo.refused': 'Повторил!'},
        ),
      );
      expect(warn.errors, contains(contains('не переопределяет')));
    });
  });
}
