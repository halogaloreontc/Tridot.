// Палитра «П1» — единственный источник цветов: литералы цветов есть только
// в assistant_theme.dart, токены совпадают с картой П1.
import 'dart:io';

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
      (AssistantColors.border, 0xFF46504B),
      (AssistantColors.text, 0xFFDDE2DF),
      (AssistantColors.textStrong, 0xFFF5F7F6),
      (AssistantColors.muted, 0xFFAEB6B1),
      (AssistantColors.icon, 0xFFA0A9A3),
      (AssistantColors.faint, 0xFF838C86),
      (AssistantColors.cubeIdle, 0xFF8A9390),
      (AssistantColors.primary, 0xFFF5F7F6),
      (AssistantColors.onPrimary, 0xFF111312),
      (AssistantColors.liorio, 0xFF6CB8FF),
      (AssistantColors.liorioBg, 0xFF12304D),
      (AssistantColors.noda, 0xFFFFAE63),
      (AssistantColors.nodaBg, 0xFF40280F),
      (AssistantColors.success, 0xFF4FD18B),
      (AssistantColors.danger, 0xFFFF6B6B),
      (AssistantColors.heat1, 0xFF256E47),
      (AssistantColors.heat2, 0xFF33A267),
      (AssistantColors.heat3, 0xFF4FD18B),
    ];
    for (final (color, argb) in expected) {
      expect(color.toARGB32(), argb, reason: '$color');
    }
  });

  test('акценты помощников — из палитры', () {
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
    for (final hex in <String>['6CB8FF', '12304D', 'FFAE63', '40280F']) {
      expect(persona.contains(hex), isFalse, reason: 'persona.dart: $hex');
      expect(theme.contains(hex), isFalse, reason: 'assistant_theme: $hex');
    }
    expect(AssistantColors.markBg, AssistantColors.nodaBg);
    expect(AssistantColors.mark, AssistantColors.noda);
    expect(AssistantColors.borderFocus.toARGB32(), 0xFF8A9390);
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
