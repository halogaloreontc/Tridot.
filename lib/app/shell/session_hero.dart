import 'package:flutter/material.dart';

import '../../core/formatting/plural.dart';
import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../widgets/personas_section.dart';

/// Пустая новая сессия (макет «Д») — она же приветствие: знак помощника,
/// «Что сделать?» и, если какую-то роль ведёт второй помощник, строка об
/// этом. Ниже — короткие строки от второго помощника ([notifier]):
/// «Просрочена 1 задача ›» ([overdue]) и «Пора потренировать пароль ›»
/// ([onTraining]). Сами по себе в сессию они ничего не пишут.
final class SessionHero extends StatelessWidget {
  const SessionHero({
    super.key,
    required this.persona,
    this.note,
    this.notifier,
    this.overdue = 0,
    this.onOverdue,
    this.onTraining,
  });

  final Persona persona;

  /// «Кладовщик» ведёт Нода — передам сам»; `null` — без строки.
  final String? note;

  /// Кто пишет первым (второй помощник, в соло — единственный): его знак у
  /// строк о просроченных и тренировке. `null` — без знака.
  final Persona? notifier;

  /// Сколько задач просрочено; 0 — строки нет.
  final int overdue;

  /// Нажатие на строку о просроченных («Мой Связной» → «Сводка»).
  final VoidCallback? onOverdue;

  /// Пора потренировать пароль: нажатие задаёт вопрос; `null` — строки
  /// нет.
  final VoidCallback? onTraining;

  /// «Просрочена 1 задача», «Просрочены 2 задачи», «Просрочено 5 задач».
  static String overdueLabel(int n) =>
      '${ruPlural(n, 'Просрочена', 'Просрочены', 'Просрочено')} $n '
      '${ruPlural(n, 'задача', 'задачи', 'задач')}';

  /// Строка о ролях второго помощника: `null`, если все роли ведёт
  /// основной.
  static String? noteFor(
    Iterable<(String roleTitle, Persona owner)> roles,
    Persona main,
  ) {
    final others = <String, List<String>>{};
    for (final (title, owner) in roles) {
      if (owner.id == main.id) continue;
      others.putIfAbsent(owner.russianName, () => <String>[]).add('«$title»');
    }
    if (others.isEmpty) return null;
    return others.entries
        .map(
          (MapEntry<String, List<String>> e) =>
              '${e.value.join(', ')} ведёт ${e.key} — передам сам',
        )
        .join('; ');
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        key: const Key('session-hero'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            PersonaMark(persona: persona, size: 48),
            const SizedBox(height: 12),
            Semantics(
              header: true,
              child: const Text(
                'Что сделать?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: AssistantColors.textStrong,
                ),
              ),
            ),
            if (note != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                note!,
                key: const Key('session-hero-note'),
                textAlign: TextAlign.center,
                style: technicalTextStyle,
              ),
            ],
            if (overdue > 0 || onTraining != null) const SizedBox(height: 16),
            if (overdue > 0)
              _HeroLine(
                key: const Key('session-hero-overdue'),
                persona: notifier,
                text: overdueLabel(overdue),
                color: AssistantColors.danger,
                semantics: '${overdueLabel(overdue)}. Открыть «Сводку»',
                onTap: onOverdue,
              ),
            if (onTraining != null)
              _HeroLine(
                key: const Key('session-hero-training'),
                persona: notifier,
                text: 'Пора потренировать пароль',
                color: AssistantColors.text,
                semantics: 'Пора потренировать пароль. Начать',
                onTap: onTraining,
              ),
          ],
        ),
      ),
    );
  }
}

/// Строка второго помощника под «Что сделать?»: знак, текст и «›». Цель
/// нажатия не ниже 44.
final class _HeroLine extends StatelessWidget {
  const _HeroLine({
    super.key,
    required this.persona,
    required this.text,
    required this.color,
    required this.semantics,
    required this.onTap,
  });

  final Persona? persona;
  final String text;
  final Color color;
  final String semantics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantics,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (persona != null) ...<Widget>[
                  PersonaMark(persona: persona!, size: 16),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: technicalTextStyle.copyWith(color: color),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 16, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
