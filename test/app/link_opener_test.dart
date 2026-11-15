// Своя страница и приложение погоды (ADR-030): команда для каждой системы
// списком аргументов, без оболочки; не https — не открывается.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/links/link_opener.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';

final class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<Object>? _flat((String, List<String>)? argv) =>
    argv == null ? null : <Object>[argv.$1, ...argv.$2];

List<Object> _call((String, List<String>, bool) c) =>
    <Object>[c.$1, ...c.$2, c.$3];

const String url = 'https://example.com/weather?city=kzn&days=7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('argv по системам', () {
    expect(
      _flat(LinkOpener.urlArgv(JobPlatform.linux, url)),
      <Object>['xdg-open', url],
    );
    // Не explorer: он теряет параметры адреса.
    expect(
      _flat(LinkOpener.urlArgv(JobPlatform.windows, url)),
      <Object>['rundll32', 'url.dll,FileProtocolHandler', url],
    );
    expect(LinkOpener.urlArgv(JobPlatform.android, url), isNull);
    expect(LinkOpener.urlArgv(JobPlatform.macos, url), isNull);
  });

  (LinkOpener, List<(String, List<String>, bool)>) desktop(JobPlatform p) {
    final calls = <(String, List<String>, bool)>[];
    final opener = LinkOpener(
      platform: p,
      start: (
        String exe,
        List<String> args, {
        bool runInShell = false,
        ProcessStartMode mode = ProcessStartMode.normal,
      }) async {
        calls.add((exe, args, runInShell));
        expect(mode, ProcessStartMode.detached);
        return _FakeProcess();
      },
      run: (String exe, List<String> args) async =>
          ProcessResult(0, exe == 'reg' ? 0 : 1, '', ''),
    );
    return (opener, calls);
  }

  test('Linux: xdg-open без оболочки', () async {
    final (opener, calls) = desktop(JobPlatform.linux);
    expect(await opener.openUrl(url), isTrue);
    expect(_call(calls.single), <Object>['xdg-open', url, false]);
  });

  test('не https — не открывается нигде', () async {
    for (final bad in <String>[
      'http://example.com/w',
      'javascript:alert(1)',
      'file:///etc/passwd',
      'https://user:pass@example.com/',
      'https://localhost/w',
      'https://example.com/a b',
    ]) {
      for (final p in <JobPlatform>[JobPlatform.linux, JobPlatform.windows]) {
        final (opener, calls) = desktop(p);
        expect(await opener.openUrl(bad), isFalse, reason: bad);
        expect(calls, isEmpty, reason: bad);
      }
    }
  });

  test('Windows: «Погода MSN», если она есть', () async {
    final (opener, calls) = desktop(JobPlatform.windows);
    final apps = await opener.weatherApps();
    expect(apps.single.id, LinkOpener.msnWeather);
    expect(await opener.openApp(LinkOpener.msnWeather), isTrue);
    expect(
      _call(calls.single),
      <Object>['rundll32', 'url.dll,FileProtocolHandler', 'msnweather:', false],
    );
    expect(await opener.openApp('com.other'), isFalse);
  });

  test('Linux: приложений погоды нет', () async {
    final (opener, _) = desktop(JobPlatform.linux);
    expect(opener.supportsApps, isFalse);
    expect(await opener.weatherApps(), isEmpty);
    expect(await opener.openApp('x'), isFalse);
  });

  group('Android: канал tridot/links', () {
    const channel = MethodChannel('tridot/links.test');
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return switch (call.method) {
          'openUrl' => true,
          'weatherApps' => <Object?>[
              <String, Object?>{
                'id': 'ru.yandex.weatherplugin',
                'label': 'Яндекс Погода',
              },
              'мусор',
            ],
          'pickApp' => <String, Object?>{'id': 'com.x', 'label': 'X'},
          'openApp' => false,
          _ => null,
        };
      });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final opener = LinkOpener(platform: JobPlatform.android, channel: channel);

    test('openUrl — только проверенный адрес', () async {
      expect(await opener.openUrl(url), isTrue);
      expect(await opener.openUrl('http://example.com'), isFalse);
      expect(calls.map((MethodCall c) => c.method), <String>['openUrl']);
      expect(calls.single.arguments, <String, Object?>{'url': url});
    });

    test('список приложений, выбор и запуск', () async {
      final apps = await opener.weatherApps();
      expect(apps.single.label, 'Яндекс Погода');
      expect((await opener.pickApp())?.id, 'com.x');
      expect(await opener.openApp('ru.yandex.weatherplugin'), isFalse);
      expect(
        calls.last.arguments,
        <String, Object?>{'package': 'ru.yandex.weatherplugin'},
      );
    });

    test('нет канала — false, а не падение', () async {
      final missing = LinkOpener(
        platform: JobPlatform.android,
        channel: const MethodChannel('tridot/links.none'),
      );
      expect(await missing.openUrl(url), isFalse);
      expect(await missing.weatherApps(), isEmpty);
      expect(await missing.pickApp(), isNull);
    });
  });
}
