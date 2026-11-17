import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/app_palette.dart';
import 'package:local_assistant/core/formatting/plural.dart';
import 'package:local_assistant/core/formatting/today_format.dart';

/// Ресурсы виджетов рабочего стола Android (ADR-034) сверяются с
/// приложением: цвета — с палитрой, слова — с форматтерами Dart, правила
/// копии и манифест — с решением. Сами виджеты рисуют тесты Robolectric
/// (`cd android && ./gradlew :app:testDebugUnitTest --tests '*homescreen*'`).
const String _res = 'android/app/src/main/res';
const String _kotlin =
    'android/app/src/main/kotlin/com/example/local_assistant/homescreen';

String _read(String path) => File(path).readAsStringSync();

/// `<color name="…">#RRGGBB</color>` → цвет.
Map<String, Color> _colors(String path) => <String, Color>{
      for (final match in RegExp(
        r'<color name="(\w+)">#([0-9A-Fa-f]{6,8})</color>',
      ).allMatches(_read(path)))
        match.group(1)!: Color(
          int.parse(
            match.group(2)!.length == 6
                ? 'FF${match.group(2)}'
                : match.group(2)!,
            radix: 16,
          ),
        ),
    };

String _string(String name) {
  final match = RegExp('<string name="$name">(.*?)</string>')
      .firstMatch(_read('$_res/values/hw_strings.xml'));
  expect(match, isNotNull, reason: name);
  return match!.group(1)!;
}

List<String> _array(String name) {
  final body = RegExp(
    '<string-array name="$name">(.*?)</string-array>',
    dotAll: true,
  ).firstMatch(_read('$_res/values/hw_strings.xml'))!.group(1)!;
  return <String>[
    for (final item in RegExp('<item>(.*?)</item>').allMatches(body))
      item.group(1)!,
  ];
}

List<File> _layouts() => Directory('$_res/layout')
    .listSync()
    .whereType<File>()
    .where((file) => file.uri.pathSegments.last.startsWith('hw_'))
    .toList();

void main() {
  test('цвета виджетов — палитра приложения, светлая и тёмная', () {
    Map<String, Color> expected(AppPalette p) => <String, Color>{
          'hw_bg': p.workspace,
          'hw_field': p.raised,
          'hw_text_strong': p.textStrong,
          'hw_text': p.text,
          'hw_muted': p.muted,
          'hw_faint': p.faint,
          'hw_icon': p.icon,
          'hw_accent': p.accent,
          'hw_on_accent': p.onAccent,
          'hw_danger': p.danger,
          'hw_border': p.border,
          'hw_divider': p.divider,
        };
    final light = _colors('$_res/values/hw_colors.xml');
    final dark = _colors('$_res/values-night/hw_colors.xml');
    for (final MapEntry(:key, :value) in expected(AppPalette.light).entries) {
      expect(light[key], value, reason: 'светлая $key');
    }
    for (final MapEntry(:key, :value) in expected(AppPalette.dark).entries) {
      expect(dark[key], value, reason: 'тёмная $key');
    }
    expect(dark.keys.toSet(), light.keys.toSet());
  });

  test('слова виджета — те же, что в приложении', () {
    // Дата в шапке: «пн, 16 ноября», как todayDateLabel.
    final weekdays = _array('hw_weekdays');
    final months = _array('hw_months');
    expect(weekdays, hasLength(7));
    expect(months, hasLength(12));
    for (var day = 0; day < 7; day++) {
      final date = DateTime(2026, 11, 16 + day);
      expect(
        '${weekdays[date.weekday - 1]}, ${date.day} ${months[date.month - 1]}',
        todayDateLabel(date),
      );
    }
    for (var month = 1; month <= 12; month++) {
      final date = DateTime(2026, month, 3);
      expect(todayDateLabel(date), endsWith(' 3 ${months[month - 1]}'));
    }
    expect(_string('hw_date'), r'· %1$s, %2$d %3$s');
    // «N дел» после отметки на виджете — как deeds().
    String form(int n) {
      final mod100 = n % 100;
      final mod10 = n % 10;
      final name = mod100 >= 11 && mod100 <= 14
          ? 'hw_deeds_many'
          : mod10 == 1
              ? 'hw_deeds_one'
              : mod10 >= 2 && mod10 <= 4
                  ? 'hw_deeds_few'
                  : 'hw_deeds_many';
      return _string(name).replaceAll(r'%1$d', '$n');
    }

    for (final n in <int>[0, 1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111]) {
      expect(form(n), deeds(n), reason: '$n');
    }
    // Тот же выбор формы — в Kotlin (HomeScreenRenderer.deeds).
    final renderer = _read('$_kotlin/HomeScreenRenderer.kt');
    expect(renderer, contains('mod100 in 11..14 -> R.string.hw_deeds_many'));
    expect(renderer, contains('mod10 == 1 -> R.string.hw_deeds_one'));
    expect(renderer, contains('mod10 in 2..4 -> R.string.hw_deeds_few'));
  });

  test('снимок и очередь не уходят в резервную копию', () {
    const rule = '<exclude domain="sharedpref" path="tridot_homescreen.xml" />';
    expect(
      rule.allMatches(_read('$_res/xml/backup_rules.xml')),
      hasLength(1),
    );
    final extraction = _read('$_res/xml/data_extraction_rules.xml');
    for (final section in <String>['cloud-backup', 'device-transfer']) {
      final body = RegExp('<$section>(.*?)</$section>', dotAll: true)
          .firstMatch(extraction)!
          .group(1)!;
      expect(body, contains(rule), reason: section);
    }
  });

  test('приёмники виджетов не экспортируются, провайдеры описаны', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    for (final (name, info) in <(String, String?)>[
      ('TodayWidget', 'hw_today_info'),
      ('QuickWidget', 'hw_quick_info'),
      ('ComboWidget', 'hw_combo_info'),
      ('HomeScreenActionReceiver', null),
    ]) {
      // Приёмник — до следующего <receiver> или <provider>.
      final start = manifest.indexOf('android:name=".homescreen.$name"');
      expect(start, greaterThan(0), reason: name);
      final ends = <int>[
        for (final tag in <String>['<receiver', '<provider', '</application>'])
          if (manifest.indexOf(tag, start) case final int at when at > 0) at,
      ];
      final body = manifest.substring(
        start,
        ends.reduce((a, b) => a < b ? a : b),
      );
      expect(body, contains('android:exported="false"'), reason: name);
      if (info == null) {
        expect(body, isNot(contains('<intent-filter>')), reason: name);
        continue;
      }
      expect(
        body,
        contains('android.appwidget.action.APPWIDGET_UPDATE'),
        reason: name,
      );
      expect(body, contains('android:resource="@xml/$info"'), reason: name);
      final provider = _read('$_res/xml/$info.xml');
      expect(provider, contains('android:updatePeriodMillis="0"'));
      // Только рабочий стол, не экран блокировки: там видно всем.
      expect(
        provider,
        contains('android:widgetCategory="home_screen|not_keyguard"'),
      );
      for (final reference in RegExp(r'@(layout|string)/(\w+)')
          .allMatches(provider)
          .map((m) => (m.group(1)!, m.group(2)!))) {
        if (reference.$1 == 'layout') {
          expect(
            File('$_res/layout/${reference.$2}.xml').existsSync(),
            isTrue,
            reason: reference.$2,
          );
        } else {
          expect(_string(reference.$2), isNotEmpty);
        }
      }
    }
  });

  test(
      'макеты виджетов: системный шрифт, текст не мельче 13, только '
      'виды RemoteViews', () {
    expect(Directory('$_res/font').existsSync(), isFalse);
    const allowed = <String>{
      'FrameLayout',
      'LinearLayout',
      'TextView',
      'ImageView',
      'include',
    };
    final layouts = _layouts();
    expect(layouts.length, greaterThanOrEqualTo(15));
    for (final file in layouts) {
      final text = file.readAsStringSync();
      final name = file.uri.pathSegments.last;
      expect(text, isNot(contains('@font/')), reason: name);
      for (final tag in RegExp(r'<([A-Za-z.]+)[\s>/]').allMatches(text)) {
        expect(allowed, contains(tag.group(1)), reason: '$name: ${tag[1]}');
      }
      for (final size in RegExp(r'textSize="(\d+)sp"').allMatches(text)) {
        expect(int.parse(size.group(1)!), greaterThanOrEqualTo(13));
      }
    }
    final styles = _read('$_res/values/hw_styles.xml');
    for (final size in RegExp(r'"android:textSize">(\d+)sp<').allMatches(
      styles,
    )) {
      expect(int.parse(size.group(1)!), greaterThanOrEqualTo(13));
    }
    for (final family
        in RegExp(r'"android:fontFamily">([\w-]+)<').allMatches(styles)) {
      expect(family.group(1), startsWith('sans-serif'));
    }
  });

  test('Kotlin виджетов не пишет в журнал и говорит на том же канале', () {
    final sources = Directory(_kotlin)
        .listSync()
        .whereType<File>()
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(sources, isNot(contains('Log.')));
    expect(sources, isNot(contains('println')));
    expect(sources, contains('const val NAME = "tridot/homescreen"'));
    final dart = _read('lib/app/homescreen/home_screen_channel.dart');
    expect(dart, contains("MethodChannel('tridot/homescreen')"));
    for (final method in <String>[
      '"state"',
      '"sync"',
      '"pending"',
      '"ack"',
      '"pin"',
      '"takeLaunch"',
      '"launch"',
      '"pendingChanged"',
      '"needSnapshot"',
    ]) {
      expect(sources, contains(method), reason: method);
    }
  });
}
