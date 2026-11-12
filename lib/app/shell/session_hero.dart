import 'package:flutter/material.dart';

import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../widgets/personas_section.dart';

/// Пустая новая сессия (макет «Д»): знак помощника, «Что сделать?» и,
/// если какую-то роль ведёт второй помощник, строка об этом.
final class SessionHero extends StatelessWidget {
  const SessionHero({super.key, required this.persona, this.note});

  final Persona persona;

  /// «Кладовщик» ведёт Нода — передам сам»; `null` — без строки.
  final String? note;

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
          ],
        ),
      ),
    );
  }
}
