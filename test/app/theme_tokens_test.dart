// Палитра «П2» (ADR-027): тёмная и светлая темы. Литералы цветов есть
// только в app_palette.dart и assistant_theme.dart; контраст каждой
// допустимой пары «текст — фон» проверен в обеих темах.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/core/personas/persona.dart';

// Относительная яркость и контраст по WCAG 2.x.
double _channel(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Iterable<File> _dart(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'));

String _path(File f) => f.path.replaceAll(r'\', '/');

const _themes = <String, AppPalette>{
  'тёмная': AppPalette.dark,
  'светлая': AppPalette.light,
};

/// Фоны, на которых стоит текст: имя → цвет.
Map<String, Color> _surfaces(AppPalette p) => <String, Color>{
      'background': p.background,
      'workspace': p.workspace,
      'raised': p.raised,
    };

/// Вложенные фоны: пузырь, чип, поле в карточке.
Map<String, Color> _nested(AppPalette p) => <String, Color>{
      'bubble': p.bubble,
      'fieldOnRaised': p.fieldOnRaised,
    };

/// Текстовые токены, допустимые на [_surfaces].
Map<String, Color> _texts(AppPalette p) => <String, Color>{
      'textStrong': p.textStrong,
      'text': p.text,
      'muted': p.muted,
      'faint': p.faint,
      'accent': p.accent,
      'cmdTint': p.cmdTint,
      'success': p.success,
      'warning': p.warning,
      'danger': p.danger,
      'sado': p.sado,
      'liorio': p.liorio,
      'noda': p.noda,
    };

/// Текстовые токены, допустимые на вложенных фонах ([_nested]). `faint`
/// там запрещён: в тёмной теме на пузыре меньше 4,5:1.
Map<String, Color> _nestedTexts(AppPalette p) => <String, Color>{
      'textStrong': p.textStrong,
      'text': p.text,
      'muted': p.muted,
      'accent': p.accent,
      'cmdTint': p.cmdTint,
    };

void main() {
  group('ограждения', () {
    test('Color(0x… только в app_palette.dart и assistant_theme.dart', () {
      // Весь lib/, включая main.dart (оверлей строки состояния).
      final offenders = <String>[
        for (final file in _dart('lib'))
          if (!_path(file).endsWith('/app_palette.dart') &&
              !_path(file).endsWith('/assistant_theme.dart') &&
              file.readAsStringSync().contains('Color(0x'))
            _path(file),
      ];
      expect(offenders, isEmpty);
    });

    test('прежних токенов AssistantColors в lib/ нет', () {
      final offenders = <String>[
        for (final file in _dart('lib'))
          if (file.readAsStringSync().contains('AssistantColors')) _path(file),
      ];
      expect(offenders, isEmpty);
    });

    test('цвет помощника — через PersonaColors, а не Color(x.accentColor)', () {
      final pattern = RegExp(r'Color\(\w+!?\.accent(Color|Background)\)');
      final offenders = <String>[
        for (final file in _dart('lib/app'))
          if (!_path(file).endsWith('/app_palette.dart') &&
              pattern.hasMatch(file.readAsStringSync()))
            _path(file),
      ];
      expect(offenders, isEmpty);
    });

    test('тонких рамок нет: поверхности разделяет заливка (S3)', () {
      // Рамка допустима: фокус поля и найденный пузырь (тема, лента),
      // контур неотмеченной галочки или кружка задачи, точки ПИН-кода,
      // обводка знаков внахлёст (ADR-027).
      const allowed = <String>{
        'assistant_theme.dart',
        'home_page.dart',
        'task_tile.dart',
        'today_panel.dart',
        'my_relay_tabs.dart',
        'pin_pad.dart',
        'personas_section.dart',
        'bulk_checklist_card.dart',
        // Рамка фокуса поиска по сессиям (видимый фокус с клавиатуры).
        'relay_drawer.dart',
      };
      final pattern = RegExp(
        r'Border\.all\(|side:\s*BorderSide\(color',
      );
      final offenders = <String>[
        for (final file in _dart('lib/app'))
          if (!allowed.contains(_path(file).split('/').last) &&
              pattern.hasMatch(file.readAsStringSync()))
            _path(file),
      ];
      expect(offenders, isEmpty);
    });

    test('текста мельче 13 нет (fontSize-литералы в lib/app)', () {
      final pattern = RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)(?![\d.*])');
      final offenders = <String>[];
      for (final file in _dart('lib/app')) {
        for (final match in pattern.allMatches(file.readAsStringSync())) {
          if (double.parse(match.group(1)!) < 13) {
            offenders.add('${_path(file)}: ${match.group(0)}');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('палитры', () {
    test('тёмная П2: чёрный фон, лист #1C1C1E, без зеленоватого оттенка', () {
      const p = AppPalette.dark;
      expect(p.brightness, Brightness.dark);
      expect(p.background.toARGB32(), 0xFF000000);
      expect(p.workspace.toARGB32(), 0xFF1C1C1E);
      expect(p.raised.toARGB32(), 0xFF2C2C2E);
      expect(p.bubble.toARGB32(), 0xFF3A3A3C);
      expect(p.text.toARGB32(), 0xFFEBEBF0);
      expect(p.muted.toARGB32(), 0xFFAEAEB2);
      expect(p.accent.toARGB32(), 0xFFB69CFF);
      expect(p.sado, p.accent);
    });

    test('светлая П2: фон #F2F2F7, белый лист', () {
      const p = AppPalette.light;
      expect(p.brightness, Brightness.light);
      expect(p.background.toARGB32(), 0xFFF2F2F7);
      expect(p.workspace.toARGB32(), 0xFFFFFFFF);
      expect(p.raised.toARGB32(), 0xFFF2F2F7);
      expect(p.bubble.toARGB32(), 0xFFE9E9ED);
      expect(p.text.toARGB32(), 0xFF1C1C1E);
      expect(p.accent.toARGB32(), 0xFF6A40D8);
      expect(p.sado, p.accent);
    });

    test('серые поверхности нейтральны: R, G и B почти равны', () {
      for (final p in _themes.values) {
        for (final color in <Color>[p.background, p.workspace, p.bubble]) {
          final channels = <double>[color.r, color.g, color.b];
          expect(
            channels.reduce(math.max) - channels.reduce(math.min),
            lessThan(0.03),
            reason: '$color',
          );
        }
      }
    });

    test('вложенная поверхность заметно отличается от родителя', () {
      for (final MapEntry(key: name, value: p) in _themes.entries) {
        expect(p.workspace, isNot(p.background), reason: name);
        expect(p.raised, isNot(p.workspace), reason: name);
        expect(p.fieldOnRaised, isNot(p.raised), reason: name);
      }
    });

    test('круглые кнопки на панели поля видны кругом, значок — читается', () {
      // «+», крестик голосового ввода, пустая отправка и выключенный
      // микрофон — заливкой fieldOnRaised на панели raised.
      for (final MapEntry(key: name, value: p) in _themes.entries) {
        expect(
          contrast(p.fieldOnRaised, p.raised),
          greaterThan(1.1),
          reason: name,
        );
        expect(
          contrast(p.icon, p.fieldOnRaised),
          greaterThanOrEqualTo(3),
          reason: name,
        );
      }
    });

    test('lerp: края — сами палитры, середина — между ними', () {
      const dark = AppPalette.dark;
      const light = AppPalette.light;
      expect(dark.lerp(light, 0), dark);
      expect(dark.lerp(light, 1).workspace, light.workspace);
      final mid = dark.lerp(light, 0.5);
      expect(mid.workspace, isNot(dark.workspace));
      expect(mid.workspace, isNot(light.workspace));
      expect(dark.copyWith(accent: light.accent).accent, light.accent);
    });
  });

  group('помощники', () {
    test('цвета ядра — из палитры обеих тем', () {
      for (final (persona, dark, light) in <(Persona, Color, Color)>[
        (Personas.sado, AppPalette.dark.sado, AppPalette.light.sado),
        (Personas.liorio, AppPalette.dark.liorio, AppPalette.light.liorio),
        (Personas.noda, AppPalette.dark.noda, AppPalette.light.noda),
      ]) {
        expect(
          PersonaColors.ofBrightness(persona, Brightness.dark).$1,
          dark,
        );
        expect(
          PersonaColors.ofBrightness(persona, Brightness.light).$1,
          light,
        );
      }
      expect(
        PersonaColors.ofBrightness(Personas.noda, Brightness.light).$2,
        AppPalette.light.nodaBg,
      );
    });

    test('цвета помощников заданы один раз — в persona_palette.dart', () {
      final persona = File('lib/core/personas/persona.dart').readAsStringSync();
      final palette = File('lib/app/app_palette.dart').readAsStringSync();
      for (final hex in <String>[
        'B69CFF',
        '2E2452',
        '6A40D8',
        '8ED1F2',
        '123444',
        '085F84',
        'F5A8CB',
        '4A2334',
        'A8326A',
      ]) {
        expect(persona.contains(hex), isFalse, reason: 'persona.dart: $hex');
        expect(palette.contains(hex), isFalse, reason: 'app_palette: $hex');
      }
    });
  });

  for (final MapEntry(key: theme, value: p) in _themes.entries) {
    group('контраст (WCAG): $theme тема', () {
      test('проверка формулы: белый на чёрном — 21:1', () {
        expect(
          contrast(const Color(0xFFFFFFFF), const Color(0xFF000000)),
          closeTo(21, 0.01),
        );
      });

      test('текст на фоне, листе и карточке — не ниже 4,5:1', () {
        for (final MapEntry(key: token, value: color) in _texts(p).entries) {
          for (final MapEntry(key: surface, value: bg)
              in _surfaces(p).entries) {
            expect(
              contrast(color, bg),
              greaterThanOrEqualTo(4.5),
              reason: '$token на $surface',
            );
          }
        }
      });

      test('на пузыре и поле в карточке — только допустимые, ≥ 4,5:1', () {
        for (final MapEntry(key: token, value: color)
            in _nestedTexts(p).entries) {
          for (final MapEntry(key: surface, value: bg) in _nested(p).entries) {
            expect(
              contrast(color, bg),
              greaterThanOrEqualTo(4.5),
              reason: '$token на $surface',
            );
          }
        }
      });

      test('акцент и кнопки: текст на заливке не ниже 4,5:1', () {
        expect(contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));
        expect(contrast(p.onPrimary, p.primary), greaterThanOrEqualTo(4.5));
        expect(contrast(p.mark, p.markBg), greaterThanOrEqualTo(4.5));
      });

      test('помощник на своём фоне знака — не ниже 4,5:1', () {
        for (final (name, accent, bg) in <(String, Color, Color)>[
          ('sado', p.sado, p.sadoBg),
          ('liorio', p.liorio, p.liorioBg),
          ('noda', p.noda, p.nodaBg),
        ]) {
          expect(contrast(accent, bg), greaterThanOrEqualTo(4.5), reason: name);
        }
      });

      test('иконки и контуры (нетекстовые) — не ниже 3:1', () {
        for (final MapEntry(key: surface, value: bg) in <String, Color>{
          ..._surfaces(p),
          'bubble': p.bubble,
        }.entries) {
          expect(
            contrast(p.icon, bg),
            greaterThanOrEqualTo(3),
            reason: 'icon на $surface',
          );
        }
        for (final bg in <Color>[p.workspace, p.raised]) {
          expect(contrast(p.border, bg), greaterThanOrEqualTo(3));
        }
        expect(contrast(p.heat3, p.workspace), greaterThanOrEqualTo(3));
        expect(contrast(p.accent, p.bubble), greaterThanOrEqualTo(3));
      });

      test('плитки иконок: белый глиф не ниже 3:1', () {
        for (final tile in <Color>[
          p.tileGray,
          p.tileViolet,
          p.tileGreen,
          p.tileBlue,
          p.tileRed,
          p.tileAmber,
        ]) {
          expect(
            contrast(const Color(0xFFFFFFFF), tile),
            greaterThanOrEqualTo(3),
            reason: '$tile',
          );
        }
      });
    });
  }

  test('тёмная: faint на пузыре ниже 4,5:1 — поэтому он там запрещён', () {
    const p = AppPalette.dark;
    expect(contrast(p.faint, p.bubble), lessThan(4.5));
  });

  group('тема собрана из палитры', () {
    for (final (name, theme, p) in <(String, ThemeData, AppPalette)>[
      ('тёмная', AssistantTheme.dark(), AppPalette.dark),
      ('светлая', AssistantTheme.light(), AppPalette.light),
    ]) {
      test(name, () {
        expect(theme.extension<AppPalette>(), p);
        expect(theme.brightness, p.brightness);
        expect(theme.colorScheme.brightness, p.brightness);
        expect(theme.colorScheme.primary, p.accent);
        expect(theme.colorScheme.onPrimary, p.onAccent);
        expect(theme.colorScheme.error, p.danger);
        expect(theme.dividerTheme.color, p.divider);
        expect(theme.dividerTheme.thickness, 0.5);
        expect(theme.scaffoldBackgroundColor, p.background);
        expect(theme.dialogTheme.backgroundColor, p.workspace);
        expect(theme.cardTheme.elevation, 0);
      });
    }

    for (final (name, theme, p) in <(String, ThemeData, AppPalette)>[
      ('тёмная', AssistantTheme.dark(), AppPalette.dark),
      ('светлая', AssistantTheme.light(), AppPalette.light),
    ]) {
      test('$name: поповеры на уровень контрастнее листа', () {
        final popover = p.isLight ? p.workspace : p.raised;
        expect(theme.popupMenuTheme.color, popover);
        expect(
          theme.menuTheme.style!.backgroundColor!.resolve(<WidgetState>{}),
          popover,
        );
        expect(
          theme.dropdownMenuTheme.menuStyle!.backgroundColor!
              .resolve(<WidgetState>{}),
          popover,
        );
        // В тёмной меню без тени — отделяет его только заливка.
        if (!p.isLight) expect(popover, isNot(p.workspace));
      });

      test('$name: поле — подпись внутри заливки и не мельче 13', () {
        final input = theme.inputDecorationTheme;
        for (final border in <InputBorder?>[
          input.border,
          input.enabledBorder,
          input.focusedBorder,
          input.errorBorder,
        ]) {
          expect(border, isA<FilledFieldBorder>());
          // Не контурная: поднятая подпись — не в «вырезе» линии.
          expect(border!.isOutline, isFalse);
        }
        // Material рисует поднятую подпись в 0,75 от её размера.
        expect(
          input.floatingLabelStyle!.fontSize! * 0.75,
          greaterThanOrEqualTo(13),
        );
        final focused = input.focusedBorder! as FilledFieldBorder;
        expect(focused.copyWith(), isA<FilledFieldBorder>());
        expect(
          focused.copyWith(borderSide: BorderSide.none).borderSide,
          BorderSide.none,
        );
      });
    }

    test('поля, кнопки и чипы — заливкой, без рамки', () {
      final theme = AssistantTheme.light();
      final input = theme.inputDecorationTheme;
      expect(input.filled, isTrue);
      expect(input.fillColor, AppPalette.light.raised);
      expect(
        (input.enabledBorder! as OutlineInputBorder).borderSide,
        BorderSide.none,
      );
      expect(
        (input.focusedBorder! as OutlineInputBorder).borderSide.color,
        AppPalette.light.accent,
      );
      expect(
        theme.outlinedButtonTheme.style!.side!.resolve(<WidgetState>{}),
        BorderSide.none,
      );
      expect(
        theme.outlinedButtonTheme.style!.backgroundColor!
            .resolve(<WidgetState>{}),
        AppPalette.light.bubble,
      );
      expect(theme.chipTheme.side, BorderSide.none);
      expect(
        theme.filledButtonTheme.style!.backgroundColor!
            .resolve(<WidgetState>{}),
        AppPalette.light.accent,
      );
    });

    test('свитч: включён — акцент, выключен — без контура', () {
      final theme = AssistantTheme.dark();
      final s = theme.switchTheme;
      expect(
        s.trackColor!.resolve(<WidgetState>{WidgetState.selected}),
        AppPalette.dark.accent,
      );
      expect(s.trackColor!.resolve(<WidgetState>{}), AppPalette.dark.bubble);
      expect(
        s.trackOutlineColor!.resolve(<WidgetState>{}),
        const Color(0x00000000),
      );
    });

    testWidgets('context.colors — палитра текущей темы', (tester) async {
      late AppPalette seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.light(),
          home: Builder(
            builder: (BuildContext context) {
              seen = context.colors;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, AppPalette.light);
    });
  });
}
