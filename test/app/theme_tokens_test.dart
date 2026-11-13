// Палитра «П1» — единственный источник цветов: литералы цветов есть только
// в assistant_theme.dart, токены совпадают с картой П1.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/core/personas/persona.dart';

void main() {
  test('в lib/app нет Color(0x… вне assistant_theme.dart', () {
    final offenders = <String>[];
    for (final entity in Directory('lib/app').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('assistant_theme.dart')) continue;
      final text = entity.readAsStringSync();
      if (text.contains('Color(0x')) offenders.add(entity.path);
    }
    expect(offenders, isEmpty);
  });

  test('токены совпадают с палитрой П1', () {
    const expected = <(Color, int)>[
      (AssistantColors.sidebar, 0xFF0B0C0C),
      (AssistantColors.panel, 0xFF0F1110),
      (AssistantColors.workspace, 0xFF131514),
      (AssistantColors.raised, 0xFF1C1F1E),
      (AssistantColors.bubble, 0xFF2A2F2D),
      (AssistantColors.divider, 0xFF262A28),
      (AssistantColors.borderSoft, 0xFF303633),
      (AssistantColors.railPill, 0xD90F1110),
      (AssistantColors.border, 0xFF46504B),
      (AssistantColors.text, 0xFFDDE2DF),
      (AssistantColors.textStrong, 0xFFF5F7F6),
      (AssistantColors.muted, 0xFFAEB6B1),
      (AssistantColors.icon, 0xFFA0A9A3),
      (AssistantColors.faint, 0xFF838C86),
      (AssistantColors.cubeIdle, 0xFF8A9390),
      (AssistantColors.primary, 0xFFF5F7F6),
      (AssistantColors.onPrimary, 0xFF111312),
      (AssistantColors.sado, 0xFFB69CFF),
      (AssistantColors.sadoBg, 0xFF2A1D4D),
      (AssistantColors.sadoOnLight, 0xFF6A40D8),
      (AssistantColors.liorio, 0xFF6CB8FF),
      (AssistantColors.liorioBg, 0xFF12304D),
      (AssistantColors.noda, 0xFFFFAE63),
      (AssistantColors.nodaBg, 0xFF40280F),
      (AssistantColors.success, 0xFF4FD18B),
      (AssistantColors.danger, 0xFFFF6B6B),
      (AssistantColors.heat1, 0xFF256E47),
      (AssistantColors.heat2, 0xFF33A267),
      (AssistantColors.heat3, 0xFF4FD18B),
      (AssistantColors.scrimLight, 0x4D000000),
      (AssistantColors.shadow, 0x99000000),
    ];
    for (final (color, argb) in expected) {
      expect(color.toARGB32(), argb, reason: '$color');
    }
  });

  test('акценты помощников — из палитры', () {
    expect(Personas.sado.accentColor, AssistantColors.sado.toARGB32());
    expect(Personas.sado.accentBackground, AssistantColors.sadoBg.toARGB32());
    expect(Personas.liorio.accentColor, AssistantColors.liorio.toARGB32());
    expect(
      Personas.liorio.accentBackground,
      AssistantColors.liorioBg.toARGB32(),
    );
    expect(Personas.noda.accentColor, AssistantColors.noda.toARGB32());
    expect(Personas.noda.accentBackground, AssistantColors.nodaBg.toARGB32());
  });

  test('цвета помощников заданы один раз — в persona_palette.dart', () {
    final persona = File('lib/core/personas/persona.dart').readAsStringSync();
    final theme = File('lib/app/assistant_theme.dart').readAsStringSync();
    for (final hex in <String>[
      'B69CFF',
      '2A1D4D',
      '6A40D8',
      '6CB8FF',
      '12304D',
      'FFAE63',
      '40280F',
    ]) {
      expect(persona.contains(hex), isFalse, reason: 'persona.dart: $hex');
      expect(theme.contains(hex), isFalse, reason: 'assistant_theme: $hex');
    }
    expect(AssistantColors.markBg, AssistantColors.nodaBg);
    expect(AssistantColors.mark, AssistantColors.noda);
    expect(AssistantColors.borderFocus.toARGB32(), 0xFF8A9390);
  });

  group('контраст акцентов помощников (WCAG, не ниже 4,5:1)', () {
    // Относительная яркость и контраст по WCAG 2.x.
    double channel(double c) => c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    double luminance(Color c) =>
        0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    double contrast(Color a, Color b) {
      final la = luminance(a);
      final lb = luminance(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    const darkSurfaces = <String, Color>{
      'workspace': AssistantColors.workspace,
      'panel': AssistantColors.panel,
      'sidebar': AssistantColors.sidebar,
      'raised': AssistantColors.raised,
      'bubble': AssistantColors.bubble,
    };
    const accents = <String, (Color, Color)>{
      'sado': (AssistantColors.sado, AssistantColors.sadoBg),
      'liorio': (AssistantColors.liorio, AssistantColors.liorioBg),
      'noda': (AssistantColors.noda, AssistantColors.nodaBg),
    };

    test('проверка формулы: белый на чёрном — 21:1', () {
      expect(
        contrast(const Color(0xFFFFFFFF), const Color(0xFF000000)),
        closeTo(21, 0.01),
      );
    });

    for (final MapEntry(key: name, value: (accent, background))
        in accents.entries) {
      test('$name на тёмных поверхностях и на своём фоне знака', () {
        for (final MapEntry(key: surface, value: color)
            in darkSurfaces.entries) {
          expect(
            contrast(accent, color),
            greaterThanOrEqualTo(4.5),
            reason: '$name на $surface',
          );
        }
        expect(contrast(accent, background), greaterThanOrEqualTo(4.5));
      });
    }

    test('Садо: худший тёмный фон — пузырь, около 5,96:1', () {
      expect(
        contrast(AssistantColors.sado, AssistantColors.bubble),
        closeTo(5.96, 0.05),
      );
    });

    test('Садо на светлом фоне — отдельный токен', () {
      const light = <Color>[Color(0xFFFFFFFF), AssistantColors.textStrong];
      for (final color in light) {
        expect(
          contrast(AssistantColors.sadoOnLight, color),
          greaterThanOrEqualTo(4.5),
        );
        // Тёмный акцент на светлом не годится — потому и токен.
        expect(contrast(AssistantColors.sado, color), lessThan(4.5));
      }
    });
  });

  test('тема собрана из токенов', () {
    final theme = AssistantTheme.dark();
    expect(theme.colorScheme.primary, AssistantColors.primary);
    expect(theme.colorScheme.onPrimary, AssistantColors.onPrimary);
    expect(theme.colorScheme.error, AssistantColors.danger);
    expect(theme.dividerTheme.color, AssistantColors.divider);
    expect(theme.scaffoldBackgroundColor, AssistantColors.background);
  });
}
