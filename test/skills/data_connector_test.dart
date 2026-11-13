import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_phrases.dart';

final DateTime _now = DateTime(2026, 11, 13, 12);

ConnectorMatch? _match(String text, {String? after}) =>
    const DataConnector().match(
      Utterance.analyze(text, now: _now)
          .withChat(null, recentConnectorId: after),
    );

void main() {
  const connector = DataConnector();

  test('паспорт: без сети, без секретов, включён всегда', () {
    final info = connector.info;
    expect(info.id, 'data');
    expect(info.title, 'Данные');
    expect(info.requiresNetwork, isFalse);
    expect(info.sensitive, isFalse);
    expect(info.required, isTrue);
    expect(info.kind, ExtensionKind.skill);
  });

  test('каждый пример распознаётся явно', () {
    for (final example in connector.info.examples) {
      final match = _match(example);
      expect(match, isNotNull, reason: example);
      expect(match!.implicit, isFalse, reason: example);
      expect(match.commandId, isNot(DataConnector.clarifyCommand));
    }
  });

  group('двусмысленные — вопрос', () {
    const phrases = <String, DataAction>{
      'сделай бэкап': DataAction.backup,
      'сделай резервную копию': DataAction.backup,
      'нужна копия': DataAction.backup,
      'сохрани копию': DataAction.backup,
      'бэкап сделай': DataAction.backup,
      'Лиорио, сделай бэкап': DataAction.backup,
      'как сделать копию, чтобы не пропало?': DataAction.backup,
      'восстанови из копии': DataAction.restore,
      'восстанови из бэкапа': DataAction.restore,
      'восстановление данных из копии': DataAction.restore,
      'верни всё из вчерашнего бэкапа, пожалуйста': DataAction.restore,
      'открой хранилище': DataAction.open,
      'хранилище': DataAction.open,
      'закрой хранилище': DataAction.lock,
      'заблокируй хранилище пожалуйста': DataAction.lock,
      'сделай копию хранилища': DataAction.backup,
      'хранилище не открывается': DataAction.access,
      'доступ к хранилищу пропал, не вхожу': DataAction.access,
      'разбил телефон и не могу зайти в хранилище': DataAction.move,
      'восстанови из копии, а то всё пропало': DataAction.restore,
      'нужна копия, срочно': DataAction.backup,
      'сделай бэкап, а то всё пропадёт': DataAction.backup,
    };
    for (final MapEntry(key: text, value: action) in phrases.entries) {
      test(text, () {
        final match = _match(text);
        expect(match, isNotNull);
        expect(match!.commandId, DataConnector.clarifyCommand);
        expect((match.payload! as DataRequest).action, action);
      });
    }

    test('без маркера — ниже порога спора и уступает', () {
      final match = _match('сделай бэкап')!;
      expect(match.implicit, isTrue);
      expect(match.confidence, lessThan(0.5));
    });

    test('команда с «хранилище» — явная, выше задач', () {
      final match = _match('закрой хранилище')!;
      expect(match.implicit, isFalse);
      expect(match.confidence, DataConnector.commandConfidence);
    });
  });

  group('явные — без вопроса', () {
    const phrases = <String, String>{
      'сделай резервную копию всех данных': 'data.backup',
      'восстанови все данные из копии': 'data.restore',
      'открой данные приложения': 'data.open',
      'запри данные приложения': 'data.lock',
      'задачи и чаты сохрани в копию': 'data.backup',
    };
    for (final MapEntry(key: text, value: command) in phrases.entries) {
      test(text, () => expect(_match(text)?.commandId, command));
    }

    test('варианты вопроса — сами явные команды', () {
      for (final text in DataPhrases.dataCommands.values) {
        expect(_match(text)?.implicit, isFalse, reason: text);
      }
      for (final text in DataPhrases.passwordsCommands.values) {
        final command = PasswordPhrases.parse(
          Utterance.analyze(text, now: _now),
        );
        expect(command, isNotNull, reason: text);
        expect(command!.implicit, isFalse, reason: text);
      }
    });
  });

  group('не данные', () {
    for (final text in <String>[
      'сделай копию договора',
      'восстанови задачу из копии',
      'купить хранилище для велосипеда',
      'облачное хранилище подорожало',
      'копия ключа от хранилища есть или нет',
      'закрой задачу хранилище',
      'бэкап паролей сделай',
      'сделай резервную копию сейфа',
      'открой хранилище паролей',
      'восстанови пароли из бэкапа',
      'загрузи данные из файла',
      'бэкап в облако можно делать или только локально?',
      'сделай бэкап базы на работе',
      // Копия бумаги, а не данных приложения: после запятой или «чтобы»
      // — только страх потерять данные.
      'нужна копия, паспорта и снилса',
      'нужна копия, срочно, для банка',
      'сделай копию чтобы отправить начальнику',
      'привет',
    ]) {
      test(text, () => expect(_match(text), isNull));
    }
  });

  group('«хранилище» с местом или временем — догадка, а не команда', () {
    for (final text in <String>[
      'закрой хранилище на складе',
      'запри хранилище в гараже',
      'открой хранилище в 10 утра',
      'открой хранилище с паспортом',
    ]) {
      test(text, () {
        final match = _match(text);
        if (match == null) return;
        expect(match.implicit, isTrue);
        expect(match.confidence, DataConnector.vagueConfidence);
      });
    }
    for (final text in <String>[
      'закрой хранилище',
      'восстанови хранилище из резервной копии',
      'восстанови хранилище на новый ноутбук',
    ]) {
      test('команда: $text', () {
        expect(_match(text)!.implicit, isFalse);
      });
    }
  });

  group('контекст сессии', () {
    test('после паролей — перенаправление к сейфу', () {
      final match = _match('сделай бэкап', after: 'passwords')!;
      final reroute = match.payload! as Reroute;
      expect(match.commandId, DataConnector.contextCommand);
      expect(reroute.connectorId, 'passwords');
      expect(reroute.text, 'сделай резервную копию сейфа');
      expect(reroute.noteReplyId, 'data.context.backup');
      expect((reroute.orElse! as DataRequest).action, DataAction.backup);
    });

    test('«хранилище» после паролей — сейф с пометкой', () {
      final reroute =
          _match('открой хранилище', after: 'passwords')!.payload! as Reroute;
      expect(reroute.text, 'открой сейф');
      expect(reroute.noteReplyId, 'data.context.passwords');
    });

    test('после данных — сразу команда данных', () {
      expect(_match('сделай бэкап', after: 'data')!.commandId, 'data.backup');
      expect(_match('открой хранилище', after: 'data')!.commandId, 'data.open');
    });

    test('контекст другого навыка — вопрос', () {
      expect(
        _match('сделай бэкап', after: 'tasks')!.commandId,
        DataConnector.clarifyCommand,
      );
    });

    test('явный объект важнее контекста', () {
      expect(
        _match('сделай резервную копию всех данных', after: 'passwords')!
            .commandId,
        'data.backup',
      );
    });
  });

  group('ответы', () {
    for (final MapEntry(key: text, value: reply) in const <String, String>{
      'сделай резервную копию всех данных': 'data.backup',
      'восстанови все данные из копии': 'data.restore',
      'открой данные приложения': 'data.open',
      'запри данные приложения': 'data.lock',
    }.entries) {
      test(text, () async {
        final session = AssistantSession();
        final response = await connector.run(_match(text)!, session);
        expect(response.replyId, reply);
        expect(response.clarification, isNull);
        expect(session.pendingConfirmation, isNull);
        expect(response.message, isNot(contains('Хранилищ')));
      });
    }

    test('без реестра навыков — вопроса нет: про все данные', () async {
      final session = AssistantSession();
      final response = await connector.run(_match('сделай бэкап')!, session);
      expect(response.intent, 'data.backup');
      expect(session.pendingConfirmation, isNull);
    });
  });
}
