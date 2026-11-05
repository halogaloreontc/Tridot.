import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

/// Коннектор, который откликается на одно слово и может спросить «да/нет».
final class _Stub implements Connector {
  _Stub(
    this.id,
    this.word, {
    this.kind = ExtensionKind.skill,
    this.defaultEnabled = true,
    this.required = false,
    this.asks = false,
  });

  final String id;
  final String word;
  final ExtensionKind kind;
  final bool defaultEnabled;
  final bool required;
  final bool asks;
  final List<Object?> answers = <Object?>[];

  @override
  ConnectorInfo get info => ConnectorInfo(
        id: id,
        title: id,
        description: 'Заглушка $id',
        kind: kind,
        defaultEnabled: defaultEnabled,
        required: required,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    if (!utterance.hasAnyWord(<String>{word})) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: '$id.cmd',
      confidence: 0.9,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    if (match.payload case final ConfirmationAnswer answer) {
      answers.add(answer.confirmed);
      return AssistantResponse(
        message: '$id: ответ',
        intent: match.commandId,
        status: AssistantStatus.completed,
      );
    }
    session.select(id, '$id-item');
    if (asks) {
      session.requestConfirmation(
        PendingConfirmation(connectorId: id, commandId: '$id.cmd'),
      );
    }
    return AssistantResponse(
      message: '$id: выполнено',
      intent: match.commandId,
      status: AssistantStatus.completed,
    );
  }
}

String _pack(String id) => jsonEncode(<String, Object?>{
      'format': 'assistant-pack/1',
      'id': id,
      'type': 'jokes',
      'title': 'Пак $id',
      'author': 'Автор',
      'language': 'ru',
      'version': '2.1.0',
      'entries': <Object?>[
        <String, Object?>{
          'id': 'e1',
          'text': 'шутка',
          'tags': <String>['кофе'],
        },
      ],
    });

void main() {
  group('ExtensionChoice', () {
    const on = ExtensionInfo(
      id: 'on',
      kind: ExtensionKind.skill,
      title: 'on',
      description: '',
    );
    const off = ExtensionInfo(
      id: 'off',
      kind: ExtensionKind.connector,
      title: 'off',
      description: '',
      defaultEnabled: false,
    );
    const must = ExtensionInfo(
      id: 'must',
      kind: ExtensionKind.skill,
      title: 'must',
      description: '',
      required: true,
    );

    test('по умолчанию', () {
      const choice = ExtensionChoice();
      expect(choice.isEnabled(on), isTrue);
      expect(choice.isEnabled(off), isFalse);
      expect(choice.isEnabled(must), isTrue);
    });

    test('выключенное и явно включённое хранятся раздельно', () {
      var choice = const ExtensionChoice().withEnabled(on, false);
      expect(choice.disabled, <String>{'on'});
      expect(choice.isEnabled(on), isFalse);
      choice = choice.withEnabled(off, true);
      expect(choice.enabled, <String>{'off'});
      expect(choice.isEnabled(off), isTrue);
      choice = choice.withEnabled(on, true).withEnabled(off, false);
      expect(choice.disabled, isEmpty);
      expect(choice.enabled, isEmpty);
    });

    test('обязательное не выключается', () {
      expect(
        () => const ExtensionChoice().withEnabled(must, false),
        throwsStateError,
      );
      const choice = ExtensionChoice(disabled: <String>{'must'});
      expect(choice.isEnabled(must), isTrue);
    });

    test('новое расширение, включённое по умолчанию, появляется включённым',
        () {
      // Пользователь выключил «on» до того, как в приложении появилось «new».
      const choice = ExtensionChoice(disabled: <String>{'on'});
      const fresh = ExtensionInfo(
        id: 'new',
        kind: ExtensionKind.skill,
        title: 'new',
        description: '',
      );
      expect(choice.isEnabled(fresh), isTrue);
      expect(choice.isEnabled(on), isFalse);
    });
  });

  group('AppSettings', () {
    test('выбор расширений сохраняется и читается', () {
      const settings = AppSettings(
        disabledExtensions: <String>{'calc', 'jokes.basic'},
        enabledExtensions: <String>{'warehouse'},
      );
      final json = jsonDecode(jsonEncode(settings.toJson()));
      final restored = AppSettings.fromJson(json as Map<String, dynamic>);
      expect(restored.disabledExtensions, <String>{'calc', 'jokes.basic'});
      expect(restored.enabledExtensions, <String>{'warehouse'});
      expect(json['disabled_extensions'], <String>['calc', 'jokes.basic']);
    });

    test('битые значения — пустые наборы, остальное не страдает', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'reduce_motion': true,
        'disabled_extensions': 'calc',
        'enabled_extensions': <Object?>[1, null, '', 'ok', 'ok', 'x' * 65],
      });
      expect(settings.reduceMotion, isTrue);
      expect(settings.disabledExtensions, isEmpty);
      expect(settings.enabledExtensions, <String>{'ok'});
      final old = AppSettings.fromJson(<String, dynamic>{});
      expect(old.disabledExtensions, isEmpty);
      expect(old.enabledExtensions, isEmpty);
    });
  });

  group('ExtensionRegistry', () {
    test('группы, включённые коннекторы, паки', () async {
      final packs = PackStore.memory(builtIn: <String>[_pack('jokes.basic')]);
      await packs.load();
      final registry = ExtensionRegistry(
        connectors: <Connector>[
          _Stub('tasks', 'задачи', required: true),
          _Stub('calc', 'калк'),
          _Stub('wh', 'склад', kind: ExtensionKind.connector),
          _Stub('beta', 'бета', defaultEnabled: false),
        ],
        packs: packs,
      );
      expect(
        registry.ofKind(ExtensionKind.skill).map((e) => e.id),
        <String>['tasks', 'calc', 'beta'],
      );
      expect(
        registry.ofKind(ExtensionKind.connector).map((e) => e.id),
        <String>['wh'],
      );
      final jokes = registry.ofKind(ExtensionKind.pack).single;
      expect(jokes.id, 'jokes.basic');
      expect(jokes.version, '2.1.0');
      expect(jokes.builtIn, isTrue);
      expect(
        registry.enabledConnectors.map((c) => c.info.id),
        <String>['tasks', 'calc', 'wh'],
      );
      expect(registry.packEntries(tags: <String>{'кофе'}), hasLength(1));

      registry.apply(registry.choiceWith('jokes.basic', false));
      expect(registry.packEntries(), isEmpty);
      registry.apply(registry.choiceWith('beta', true));
      expect(registry.isEnabled('beta'), isTrue);
      expect(() => registry.choiceWith('tasks', false), throwsStateError);
      expect(() => registry.choiceWith('nope', true), throwsArgumentError);
    });

    test('повтор id — ошибка; id навыков заняты для паков', () async {
      expect(
        () => ExtensionRegistry(
          connectors: <Connector>[_Stub('a', 'x'), _Stub('a', 'y')],
        ),
        throwsArgumentError,
      );
      final registry = ExtensionRegistry(
        connectors: <Connector>[_Stub('calc', 'x')],
      );
      final result = await registry.importPack(_pack('calc'));
      expect(result.ok, isFalse);
    });

    test('импорт и удаление пака оповещают слушателей', () async {
      final registry = ExtensionRegistry(connectors: <Connector>[]);
      var calls = 0;
      void listener() => calls++;
      registry.addListener(listener);
      expect((await registry.importPack(_pack('my.pack'))).ok, isTrue);
      expect(registry.info('my.pack')!.builtIn, isFalse);
      expect(await registry.removePack('my.pack'), isTrue);
      registry.apply(const ExtensionChoice(disabled: <String>{'x'}));
      registry.apply(const ExtensionChoice(disabled: <String>{'x'}));
      expect(calls, 3, reason: 'тот же выбор не оповещает');
      registry.removeListener(listener);
    });
  });

  group('выбор для удалённого пака', () {
    test('удалённый и снова добавленный пак приходит включённым', () async {
      final registry = ExtensionRegistry(connectors: <Connector>[]);
      expect((await registry.importPack(_pack('my.pack'))).ok, isTrue);
      registry.apply(registry.choiceWith('my.pack', false));
      expect(registry.isEnabled('my.pack'), isFalse);
      expect(await registry.removePack('my.pack'), isTrue);
      expect(registry.choice.disabled, isEmpty);
      expect((await registry.importPack(_pack('my.pack'))).ok, isTrue);
      expect(registry.isEnabled('my.pack'), isTrue);
    });

    test('новый пак со следом в сохранённом выборе — включён', () async {
      final registry = ExtensionRegistry(
        connectors: <Connector>[],
        choice: const ExtensionChoice(disabled: <String>{'my.pack'}),
      );
      expect((await registry.importPack(_pack('my.pack'))).ok, isTrue);
      expect(registry.isEnabled('my.pack'), isTrue);
    });

    test('замена пака сохраняет выключенное состояние', () async {
      final registry = ExtensionRegistry(connectors: <Connector>[]);
      await registry.importPack(_pack('my.pack'));
      registry.apply(registry.choiceWith('my.pack', false));
      final result = await registry.importPack(_pack('my.pack'), replace: true);
      expect(result.ok, isTrue);
      expect(registry.isEnabled('my.pack'), isFalse);
    });

    test('ExtensionChoice.without', () {
      const choice = ExtensionChoice(
        disabled: <String>{'a', 'b'},
        enabled: <String>{'c'},
      );
      expect(choice.without('a').disabled, <String>{'b'});
      expect(choice.without('c').enabled, isEmpty);
      expect(identical(choice.without('z'), choice), isTrue);
    });
  });

  group('маршрутизатор и выключение на ходу', () {
    final clock = FixedClock(DateTime(2026, 11, 5, 12));

    test('выключенный коннектор не спрашивается, включённый — сразу', () async {
      final calc = _Stub('calc', 'калк');
      final registry = ExtensionRegistry(
        connectors: <Connector>[_Stub('tasks', 'задачи', required: true), calc],
      );
      final assistant = AssistantController(extensions: registry, clock: clock);
      expect((await assistant.handle('калк')).intent, 'calc.cmd');

      registry.apply(registry.choiceWith('calc', false));
      expect((await assistant.handle('калк')).intent, 'unknown');
      expect(assistant.connectors.map((c) => c.id), <String>['tasks']);

      registry.apply(registry.choiceWith('calc', true));
      expect((await assistant.handle('калк')).intent, 'calc.cmd');
    });

    test('ожидание выключенного снимается, другого — остаётся', () async {
      final asker = _Stub('asker', 'спроси', asks: true);
      final other = _Stub('other', 'другой', asks: true);
      final registry = ExtensionRegistry(
        connectors: <Connector>[asker, other],
      );
      final assistant = AssistantController(extensions: registry, clock: clock);

      await assistant.handle('спроси');
      expect(assistant.session.pendingConfirmation?.connectorId, 'asker');
      registry.apply(registry.choiceWith('other', false));
      expect(
        assistant.session.pendingConfirmation?.connectorId,
        'asker',
        reason: 'выключили другой коннектор',
      );
      expect(assistant.session.selectedItemFor('asker'), 'asker-item');

      registry.apply(registry.choiceWith('asker', false));
      expect(assistant.session.pendingConfirmation, isNull);
      expect(
        assistant.session.selectedItemFor('asker'),
        'asker-item',
        reason: 'выбор не сбрасывается',
      );

      registry.apply(const ExtensionChoice());
      await assistant.handle('да');
      expect(
        asker.answers,
        isEmpty,
        reason: '«да» не дошло до старого вопроса',
      );
    });

    test('конструктор с connectors по-прежнему работает', () async {
      final assistant = AssistantController(
        connectors: <Connector>[_Stub('a', 'склад')],
        clock: clock,
      );
      expect(assistant.extensions.connectors, hasLength(1));
      expect((await assistant.handle('склад')).intent, 'a.cmd');
    });
  });
}
