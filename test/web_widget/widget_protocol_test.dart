import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/web_widget/widget_protocol.dart';

void main() {
  group('HostEvent.parse', () {
    test('чужие и битые сообщения отбрасываются', () {
      expect(HostEvent.parse(null), isNull);
      expect(HostEvent.parse('init'), isNull);
      expect(HostEvent.parse(<String, Object?>{'type': 'init'}), isNull);
      expect(
        HostEvent.parse(<String, Object?>{'svz': 2, 'type': 'back'}),
        isNull,
      );
      expect(
        HostEvent.parse(<String, Object?>{'svz': 1, 'type': 'unknown'}),
        isNull,
      );
      // init без адреса склада — не вход.
      expect(
        HostEvent.parse(<String, Object?>{'svz': 1, 'type': 'init'}),
        isNull,
      );
    });

    test('init: поля, тема, устройство, голос', () {
      final e = HostEvent.parse(<String, Object?>{
        'svz': 1,
        'type': 'init',
        'base': 'https://w.example/sub/',
        'sid': 'abc',
        'login': 'ivanov',
        'name': 'Иван\u202eПетров',
        'roleLabel': 'Кладовщик',
        'theme': 'dark',
        'device': 'phone',
        'voice': <String, Object?>{'available': true, 'reason': 'ok'},
      })! as HostInit;
      expect(e.base, 'https://w.example/sub/');
      expect(e.sid, 'abc');
      expect(e.name, 'Иван Петров', reason: 'знаки направления — пробел');
      expect(e.theme, 'dark');
      expect(e.phone, isTrue);
      expect(e.voice.available, isTrue);
      expect(e.voice.showButton, isTrue);
    });

    test('theme: только light или dark', () {
      HostEvent? parse(Object? theme) => HostEvent.parse(
            <String, Object?>{'svz': 1, 'type': 'theme', 'theme': theme},
          );
      expect((parse('dark')! as HostTheme).theme, 'dark');
      expect((parse('light')! as HostTheme).theme, 'light');
      expect(parse('blue'), isNull);
      expect(parse(null), isNull);
    });

    test('голос: причины и что показать', () {
      VoiceCaps caps(Object? v) => VoiceCaps.fromJson(v);
      expect(caps(null).showButton, isFalse);
      expect(caps(<String, Object?>{'reason': 'web'}).showButton, isFalse);
      final old = caps(<String, Object?>{'available': false, 'reason': 'sdk'});
      expect(old.showButton, isTrue);
      expect(old.keyboardHint, isTrue);
      final lang =
          caps(<String, Object?>{'available': false, 'reason': 'no-lang'});
      expect(lang.needsLanguage, isTrue);
      expect(caps(<String, Object?>{'reason': 'cloud'}).reason, 'web');
    });

    test('key, back, logout, visible, voice-ev', () {
      expect(
        (HostEvent.parse(<String, Object?>{
          'svz': 1,
          'type': 'key',
          'sid': 'k2',
        })! as HostKey)
            .sid,
        'k2',
      );
      final failed = HostEvent.parse(<String, Object?>{
        'svz': 1,
        'type': 'key',
        'error': 'Нужен вход',
      })! as HostKey;
      expect(failed.sid, isEmpty);
      expect(failed.error, 'Нужен вход');
      expect(
        HostEvent.parse(<String, Object?>{'svz': 1, 'type': 'back'}),
        isA<HostBack>(),
      );
      expect(
        HostEvent.parse(<String, Object?>{'svz': 1, 'type': 'logout'}),
        isA<HostLogout>(),
      );
      expect(
        (HostEvent.parse(<String, Object?>{
          'svz': 1,
          'type': 'visible',
          'on': true,
        })! as HostVisible)
            .on,
        isTrue,
      );
      final ev = HostEvent.parse(<String, Object?>{
        'svz': 1,
        'type': 'voice-ev',
        'id': 3,
        'ev': 'partial',
        'text': 'где лежит',
      })! as HostVoiceEvent;
      expect(ev.id, 3);
      expect(ev.kind, 'partial');
      expect(ev.text, 'где лежит');
      expect(
        HostEvent.parse(<String, Object?>{
          'svz': 1,
          'type': 'voice-ev',
          'id': 3,
          'ev': 'eval',
        }),
        isNull,
      );
    });
  });

  group('WidgetMessages', () {
    test('каждое сообщение с отметкой svz: 1', () {
      for (final m in <Map<String, Object?>>[
        WidgetMessages.hello('1.0.0'),
        WidgetMessages.needKey(),
        WidgetMessages.close(),
        WidgetMessages.open('#/entry/12'),
        WidgetMessages.updateReady('1.0.1'),
        WidgetMessages.voice('start', 1),
      ]) {
        expect(m['svz'], 1);
        expect(m['type'], isA<String>());
      }
      expect(WidgetMessages.hello('1.0.0')['api'], widgetApi);
    });

    test('linkHash: позиция и приход из карточки, id закодирован', () {
      expect(WidgetMessages.linkHash('sku', '67432'), '#/sku/67432');
      expect(WidgetMessages.linkHash('entry', '412'), '#/entry/412');
      // Кириллица и «/» в артикуле — %-кодом; склад раскодирует сам.
      expect(
        WidgetMessages.linkHash('sku', '101БРАК/2'),
        '#/sku/101%D0%91%D0%A0%D0%90%D0%9A%2F2',
      );
      expect(
        WidgetMessages.open(WidgetMessages.linkHash('sku', 'Ж 1'))['hash'],
        '#/sku/%D0%96%201',
      );
      // Ячейку и чужие виды склад не открывает — главная.
      expect(WidgetMessages.linkHash('cell', 'A-1'), '');
      expect(WidgetMessages.linkHash('url', 'https://evil.example/'), '');
      expect(WidgetMessages.linkHash('sku', ''), '');
      // Попытка выйти из адреса склада остаётся частью id.
      expect(
        WidgetMessages.linkHash('sku', 'javascript:alert(1)'),
        '#/sku/javascript%3Aalert%281%29',
      );
      // Слишком длинный — главная, а не обрезанный адрес.
      expect(WidgetMessages.linkHash('sku', 'Ж' * 60), '');
    });

    test('open: только переход внутри склада', () {
      expect(WidgetMessages.open('#/entry/12')['hash'], '#/entry/12');
      expect(WidgetMessages.open('https://evil.example/')['hash'], '');
      expect(WidgetMessages.open('javascript:alert(1)')['hash'], '');
      expect(WidgetMessages.open('#/a b')['hash'], '');
    });

    test('voice: только известные действия', () {
      expect(WidgetMessages.voice('stop', 2)['op'], 'stop');
      expect(WidgetMessages.voice('start', 2)['lang'], 'ru-RU');
      expect(() => WidgetMessages.voice('cloud', 2), throwsArgumentError);
    });
  });

  group('договор 2', () {
    test('signal: до 5 напоминаний, действия и чистка', () {
      final event = HostEvent.parse(<String, Object?>{
        'svz': 1,
        'type': 'signal',
        'reason': 'bell',
        'focus': 'task:t1:e',
        'items': <Object?>[
          for (var i = 0; i < 7; i++)
            <String, Object?>{
              'id': 'task:t$i:e',
              'title': 'Задача $i\u202e',
              'level': 'warn',
              'open': 'javascript:alert(1)',
              'actions': <Object?>[
                <String, Object?>{
                  'id': 'done',
                  'label': 'Готово',
                  'my': <String, Object?>{
                    'action': 'my_patch',
                    'body': <String, Object?>{'type': 'task'},
                  },
                },
                <String, Object?>{
                  'id': 'when',
                  'label': 'Срок',
                  'date': <String, Object?>{'label': 'Дата отгрузки'},
                  'my': <String, Object?>{
                    'action': 'my_put',
                    'body': <String, Object?>{},
                  },
                },
                <String, Object?>{'label': 'без id'},
              ],
            },
          'мусор',
        ],
      })! as HostSignal;
      expect(event.items, hasLength(5));
      expect(event.focus, 'task:t1:e');
      final first = event.items.first;
      expect(first.title, 'Задача 0');
      expect(first.level, 'warn');
      expect(first.open, '', reason: 'только адреса внутри склада');
      expect(first.actions, hasLength(2));
      expect(first.actions.last.dateLabel, 'Дата отгрузки');
    });

    test('open-project: только id хранилища', () {
      expect(
        (HostEvent.parse(<String, Object?>{
          'svz': 1,
          'type': 'open-project',
          'id': 'p_1700000000_ab',
        })! as HostOpenProject)
            .id,
        'p_1700000000_ab',
      );
      expect(
        HostEvent.parse(
          <String, Object?>{'svz': 1, 'type': 'open-project', 'id': '../x'},
        ),
        isNull,
      );
    });

    test('open-chat: только id хранилища', () {
      expect(
        (HostEvent.parse(<String, Object?>{
          'svz': 1,
          'type': 'open-chat',
          'id': 'session:1_ab',
        })! as HostOpenChat)
            .id,
        'session:1_ab',
      );
      expect(
        HostEvent.parse(
          <String, Object?>{'svz': 1, 'type': 'open-chat', 'id': '../x'},
        ),
        isNull,
      );
    });

    test('init: широкая панель, changed и layout', () {
      final init = HostEvent.parse(<String, Object?>{
        'svz': 1,
        'type': 'init',
        'base': 'https://w.example/',
        'layout': <String, Object?>{'can': true, 'wide': true},
      })! as HostInit;
      expect(init.canWide, isTrue);
      expect(init.wide, isTrue);
      expect(
        (HostEvent.parse(<String, Object?>{
          'svz': 1,
          'type': 'init',
          'base': 'https://w.example/',
        })! as HostInit)
            .canWide,
        isFalse,
      );
      expect(
        WidgetMessages.changed(<String>['my', 'evil'])['what'],
        <String>['my'],
      );
      expect(WidgetMessages.layout(wide: true)['wide'], isTrue);
      expect(WidgetMessages.hello('1.0.0')['caps'], widgetCaps);
    });
  });
}
