import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/manifest/app_profile.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/generic_slot.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/replies/reply_library.dart';

import 'fixtures.dart';

/// Слот приложения из профиля (ADR-043): тексты для мужского, женского,
/// среднего рода, множественного числа и несклоняемого имени.
void main() {
  AppProfile profile(
    String name,
    List<String>? forms, {
    AppGender? gender,
    String? inPhrase,
    List<String> addressing = const <String>[],
  }) {
    final raw = <String, Object?>{
      'id': 'testcrm',
      'name': name,
      if (forms != null)
        'forms': <String, Object?>{
          for (final (i, key) in NameForms.keys.indexed) key: forms[i],
        },
      if (gender != null) 'gender': gender.name,
      if (inPhrase != null) 'in': inPhrase,
      'addressing': addressing,
    };
    final parsed = AppProfile.parse(raw);
    if (parsed.warnings.isNotEmpty || parsed.profile == null) {
      throw StateError('$name: ${parsed.warnings}');
    }
    return parsed.profile!;
  }

  final service = profile(
    'автосервис',
    <String>[
      'автосервис',
      'автосервиса',
      'автосервису',
      'автосервис',
      'автосервисом',
      'автосервисе',
    ],
    gender: AppGender.m,
    inPhrase: 'в автосервисе',
    addressing: <String>['сервис'],
  );
  final base = profile(
    'база',
    <String>['база', 'базы', 'базе', 'базу', 'базой', 'базе'],
    gender: AppGender.f,
    inPhrase: 'в базе',
  );
  final registry = profile(
    'реестр-хранилище',
    <String>[
      'реестр-хранилище',
      'реестра-хранилища',
      'реестру-хранилищу',
      'реестр-хранилище',
      'реестром-хранилищем',
      'реестре-хранилище',
    ],
    gender: AppGender.n,
  );
  final books = profile(
    'записи',
    <String>['записи', 'записей', 'записям', 'записи', 'записями', 'записях'],
    gender: AppGender.pl,
  );
  final crm = profile('CRM', null);
  final storeroom = profile(
    'кладовая',
    <String>[
      'кладовая',
      'кладовой',
      'кладовой',
      'кладовую',
      'кладовой',
      'кладовой',
    ],
    gender: AppGender.f,
  );

  final library = ReplyLibrary.builtIn;

  String say(
    ConnectionSlot slot,
    String key, [
    Map<String, String> values = const <String, String>{},
    ReplyAddress address = ReplyAddress.formal,
  ]) =>
      library
          .withEntries(slot.replies, protectedIds: slot.protectedReplies)
          .render(
            Reply('${slot.id}.$key', values),
            ReplyVoice(address: address),
          );

  group('слот', () {
    final slot = ConnectionSlot.generic(service, 'testcrm');

    test('название, обращения, справка, только чтение', () {
      expect(slot.id, 'testcrm');
      expect(slot.appId, 'testcrm');
      expect(slot.title, 'Автосервис');
      expect(slot.aliases, <String>['в автосервисе', 'автосервис', 'сервис']);
      expect(slot.helpPhrases, contains('что умеет автосервис'));
      expect(slot.helpPhrases, contains('помощь по автосервису'));
      expect(slot.helpPhrases, contains('команды автосервиса'));
      expect(slot.helpPhrases, contains('что спросить у автосервиса'));
      expect(slot.helpPhrases, contains('что умеет сервис'));
      expect(slot.builtInAsset, isNull);
      expect(slot.builtInQr, isNull);
      expect(slot.commandReplies, isEmpty);
      expect(slot.queryLabel, GenericSlotTexts.queryLabel);
      expect(slot.tokenKey, 'testcrm.token');
      expect(slot.description, startsWith('Автосервис: только чтение'));
    });

    test('тот же набор ключей и защищённых записей, что у склада', () {
      String tail(String id, String prefix) => id.substring(prefix.length);
      final warehouse = ConnectionSlots.warehouse;
      expect(
        slot.replies.keys.map((String k) => tail(k, 'testcrm.')).toSet(),
        warehouse.replies.keys.map((String k) => tail(k, 'warehouse.')).toSet(),
      );
      expect(
        slot.protectedReplies.map((String k) => tail(k, 'testcrm.')).toSet(),
        warehouse.protectedReplies
            .map((String k) => tail(k, 'warehouse.'))
            .toSet(),
      );
    });

    test('записи разбираются каталогом рядом со складом', () {
      expect(
        () => ReplyLibrary.builtIn.withEntries(
          <String, String>{
            ...ConnectionSlots.warehouse.replies,
            ...slot.replies,
          },
          protectedIds: <String>{
            ...ConnectionSlots.warehouse.protectedReplies,
            ...slot.protectedReplies,
          },
        ),
        returnsNormally,
      );
    });

    test('ни слова о складе, кладовщике и QR склада', () {
      for (final p in <AppProfile>[service, base, registry, books, crm]) {
        final s = ConnectionSlot.generic(p, 'testcrm');
        for (final text in <String>[
          s.title,
          s.description,
          ...s.aliases,
          ...s.helpPhrases,
          ...s.replies.values,
        ]) {
          final lower = text.toLowerCase();
          expect(lower, isNot(contains('склад')), reason: text);
          expect(lower, isNot(contains('кладовщик')), reason: text);
          expect(lower, isNot(contains('показать qr')), reason: text);
          expect(lower, isNot(contains('роли →')), reason: text);
        }
      }
    });

    test('путь подключения', () {
      expect(
        say(slot, 'notConnected'),
        contains('Мой Связной → Помощники → Подключения → Автосервис'),
      );
    });

    test('плохой id не принимается', () {
      for (final id in <String>[
        'warehouse',
        'index',
        'tasks',
        'passwords',
        'Test',
        'test_crm',
        '2crm',
        '',
        'a' * 33,
      ]) {
        expect(
          () => ConnectionSlot.generic(service, id),
          throwsArgumentError,
          reason: id,
        );
      }
    });
  });

  group('тексты по роду', () {
    final m = ConnectionSlot.generic(service, 'testcrm');
    final f = ConnectionSlot.generic(base, 'testcrm');
    final n = ConnectionSlot.generic(registry, 'testcrm');
    final pl = ConnectionSlot.generic(books, 'testcrm');

    test('мужской: автосервис', () {
      expect(
        say(m, 'serverSaid', <String, String>{'error': 'нет доступа'}),
        'Автосервис ответил: нет доступа',
      );
      expect(
        say(m, 'notConnected'),
        'Автосервис не подключён. Подключите его: Мой Связной → Помощники → '
        'Подключения → Автосервис.',
      );
      expect(
        say(m, 'auth.token'),
        'Автосервис не принял пароль — подключитесь заново: Мой Связной → '
        'Помощники → Подключения → Автосервис.',
      );
      expect(
        say(m, 'timeout'),
        'Автосервис не ответил вовремя. Попробуйте ещё раз чуть позже.',
      );
      expect(
        say(m, 'offline'),
        'Нет связи с автосервисом. Проверьте интернет и спросите ещё раз.',
      );
      expect(
        say(m, 'help', <String, String>{'list': 'клиенты'}),
        'Автосервис понимает: клиенты.',
      );
      expect(say(m, 'total'), contains('автосервис пока не считает — он '));
      expect(
        say(m, 'busy', const <String, String>{}, ReplyAddress.informal),
        'Автосервис просит подождать: слишком много запросов. Попробуй через '
        'минуту.',
      );
    });

    test('женский: база', () {
      expect(
        say(f, 'serverSaid', <String, String>{'error': 'нет'}),
        'База ответила: нет',
      );
      expect(
        say(f, 'notConnected'),
        startsWith('База не подключена. '
            'Подключите её: '),
      );
      expect(say(f, 'auth.token'), startsWith('База не приняла пароль'));
      expect(say(f, 'timeout'), startsWith('База не ответила вовремя.'));
      expect(say(f, 'offline'), startsWith('Нет связи с базой.'));
      expect(say(f, 'total'), contains('база пока не считает — она '));
      expect(
          say(f, 'auth.role'),
          'Учётная запись ждёт роли — попросите администратора базы её '
          'назначить.');
    });

    test('средний: реестр-хранилище', () {
      expect(
        say(n, 'serverSaid', <String, String>{'error': 'нет'}),
        'Реестр-хранилище ответило: нет',
      );
      expect(
        say(n, 'notConnected'),
        startsWith('Реестр-хранилище не подключено. Подключите его: '),
      );
      expect(say(n, 'total'), contains('— оно отвечает'));
    });

    test('множественное: записи', () {
      expect(
        say(pl, 'serverSaid', <String, String>{'error': 'нет'}),
        'Записи ответили: нет',
      );
      expect(
        say(pl, 'notConnected'),
        startsWith('Записи не подключены. Подключите их: '),
      );
      expect(say(pl, 'timeout'), startsWith('Записи не ответили вовремя.'));
      expect(
        say(pl, 'help', <String, String>{'list': 'всё'}),
        'Записи понимают: всё.',
      );
      expect(say(pl, 'serverError'), startsWith('Записи отвечают с ошибкой.'));
      expect(say(pl, 'busy'), startsWith('Записи просят подождать'));
      expect(
        say(pl, 'total'),
        contains('записи пока не считают — они '
            'отвечают'),
      );
    });

    test('предлоги «с» и «со», «к» и «ко»', () {
      final s = ConnectionSlot.generic(storeroom, 'testcrm');
      expect(say(s, 'offline'), startsWith('Нет связи с кладовой.'));
      expect(GenericSlotTexts.withS('складом'), 'со складом');
      expect(GenericSlotTexts.withS('сервисом'), 'с сервисом');
      expect(GenericSlotTexts.withK('всем'), 'ко всем');
      expect(GenericSlotTexts.withK('базе'), 'к базе');
    });
  });

  group('несклоняемое имя: CRM', () {
    final s = ConnectionSlot.generic(crm, 'testcrm');

    test('латиница — как есть, без рода и падежей', () {
      expect(s.title, 'CRM');
      expect(s.aliases, <String>['CRM']);
      expect(s.helpPhrases, contains('что умеет CRM'));
      expect(s.helpPhrases, contains('помощь по CRM'));
      expect(
        say(s, 'serverSaid', <String, String>{'error': 'нет'}),
        'Ответ CRM: нет',
      );
      expect(
        say(s, 'notConnected'),
        'Нет подключения к CRM. Подключитесь: Мой Связной → Помощники → '
        'Подключения → CRM.',
      );
      expect(say(s, 'auth.token'), startsWith('Пароль для CRM не принят'));
      expect(say(s, 'timeout'), startsWith('Ответ от CRM не пришёл вовремя.'));
      expect(say(s, 'offline'), startsWith('Нет связи с CRM.'));
      expect(
        say(s, 'help', <String, String>{'list': 'клиенты'}),
        'Команды CRM: клиенты.',
      );
      expect(say(s, 'busy'), startsWith('Слишком много запросов к CRM'));
    });

    test('латинская марка не получает заглавную', () {
      final brand = profile('amoCRM', null);
      expect(ConnectionSlot.generic(brand, 'testcrm').title, 'amoCRM');
    });

    test('падежи без рода — тоже без согласования', () {
      final noGender = profile('база', <String>[
        'база',
        'базы',
        'базе',
        'базу',
        'базой',
        'базе',
      ]);
      final g = ConnectionSlot.generic(noGender, 'testcrm');
      expect(
        say(g, 'serverSaid', <String, String>{'error': 'нет'}),
        'Ответ базы: нет',
      );
      expect(say(g, 'notConnected'), startsWith('Нет подключения к базе.'));
    });
  });

  test('опасное имя не доходит до шаблонов', () {
    for (final name in <String>['{login}', 'CRM {вы:a|ты:b}', 'x|y', 'a}']) {
      final parsed = AppProfile.parse(
        <String, Object?>{'id': 'testcrm', 'name': name},
      );
      expect(parsed.profile, isNull, reason: name);
    }
    // Безопасное имя с «» проходит каталог без ошибок разметки.
    final quoted = profile('сервис «Тест»', null);
    final slot = ConnectionSlot.generic(quoted, 'testcrm');
    expect(
      () => library.withEntries(
        slot.replies,
        protectedIds: slot.protectedReplies,
      ),
      returnsNormally,
    );
  });

  group('idFor', () {
    test('из app.id: строчная латиница и цифры', () {
      expect(ConnectionSlots.idFor('severauto', <String>{}), 'severauto');
      expect(ConnectionSlots.idFor('Sever-Auto_1', <String>{}), 'severauto1');
      expect(ConnectionSlots.idFor('12crm', <String>{}), 'crm');
      expect(ConnectionSlots.idFor('---', <String>{}), isNotEmpty);
      expect(
        ConnectionSlots.idFor('a' * 40, <String>{}),
        hasLength(32),
      );
    });

    test('занятый — с числом', () {
      expect(
        ConnectionSlots.idFor('severauto', <String>{'severauto'}),
        'severauto2',
      );
      expect(
        ConnectionSlots.idFor(
          'severauto',
          <String>{'severauto', 'severauto2'},
        ),
        'severauto3',
      );
      final long = 'a' * 32;
      final id = ConnectionSlots.idFor(long, <String>{long});
      expect(id, hasLength(32));
      expect(id, endsWith('2'));
    });

    test('никогда не склад, не навык, не служебное имя', () {
      for (final appId in <String>[
        'warehouse',
        'index',
        'tasks',
        'passwords',
        'calc',
        'talk',
        'halowarekeep',
        'depotdesk',
      ]) {
        final id = ConnectionSlots.idFor(appId, <String>{});
        expect(id, isNot(appId));
        expect(ConnectionSlots.validId(id), isTrue, reason: id);
      }
    });

    test('не совпадает с разделом встроенного каталога', () {
      final sections = <String>{
        for (final key in ReplyLibrary.builtIn.neutral.entries.keys)
          key.split('.').first,
      };
      for (final section in sections) {
        expect(ConnectionSlots.idFor(section, <String>{}), isNot(section));
      }
    });

    test('годится в id записей каталога', () {
      final id = ConnectionSlots.idFor('Test CRM!', <String>{});
      expect(
        RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$')
            .hasMatch('$id.auth.token'),
        isTrue,
      );
    });
  });

  test('склад не изменился', () {
    final warehouse = ConnectionSlots.warehouse;
    expect(warehouse.id, 'warehouse');
    expect(warehouse.title, 'Склад');
    expect(warehouse.queryLabel, 'артикул или название');
    expect(warehouse.totalExample, 'сколько 64115');
    expect(warehouse.replies, hasLength(19));
    expect(
      () => ExtensionRegistry(connectors: <Connector>[warehouseConnector()]),
      returnsNormally,
    );
  });
}
