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
}
