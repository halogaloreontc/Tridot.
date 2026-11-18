import 'package:flutter/material.dart';

import '../../core/personas/persona.dart';
import '../assistant_theme.dart';

/// Метка помощника: буква имени в кружке его цвета.
class PersonaMark extends StatelessWidget {
  const PersonaMark({
    super.key,
    required this.persona,
    this.size = 18,
    this.round = false,
    this.ring,
  });

  final Persona persona;
  final double size;

  /// Круглый знак (аватары на карточке «Мой …»), иначе — скруглённый
  /// квадрат.
  final bool round;

  /// Обводка вокруг круглого знака цветом фона под ним: знаки внахлёст.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final accent = PersonaColors.of(persona, context).$1;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: round ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: round ? null : BorderRadius.circular(size * .3),
            color: PersonaColors.of(persona, context).$2,
            border: ring == null ? null : Border.all(color: ring!, width: 2),
          ),
          // Буква не растёт с крупным шрифтом: знак фиксированного
          // размера.
          child: Center(
            child: MediaQuery.withNoTextScaling(
              child: Text(
                persona.russianInitial,
                style: TextStyle(
                  fontSize: size * .5,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Точка помощника (ADR-027): тихий знак его цвета у имени — в ленте, в
/// шапке сессии. Буквы и рамки нет.
class PersonaDot extends StatelessWidget {
  const PersonaDot({super.key, required this.persona, this.size = 8});

  final Persona persona;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: PersonaColors.of(persona, context).$1,
            ),
          ),
        ),
      );
}
