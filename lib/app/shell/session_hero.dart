import 'package:flutter/material.dart';

import '../../core/formatting/plural.dart';
import '../../core/personas/persona.dart';
import '../../core/replies/reply_library.dart';
import '../assistant_theme.dart';
import '../widgets/personas_section.dart';

/// Пустая новая сессия (макет «Д») — она же приветствие: знак главного,
/// «Что сделать?» и, если какую-то роль ведёт помощник, строка об этом.
/// Ниже — короткие строки от ведущего оповещений ([notifier]): «Просрочена
/// 1 задача ›» ([overdue]) и «Пора потренировать пароль ›» ([onTraining]).
/// Сами по себе в сессию они ничего не пишут.
///
/// Пока род главного не выбран, под «Что сделать?» — карточка «Связной
/// или Связная?» ([onSadoGender]): не модальное окно, её можно не
/// замечать.
final class SessionHero extends StatelessWidget {
  const SessionHero({
    super.key,
    required this.persona,
    this.note,
    this.notifier,
    this.overdue = 0,
    this.onOverdue,
    this.onTraining,
    this.onSadoGender,
    this.projectName,
  });

  /// Пустая сессия начата в проекте-папке: подпись «Проект «…»» под
  /// «Что сделать?»; `null` — вне проектов.
  final String? projectName;

  /// Главный — Связной: его знак крупно.
  final Persona persona;

  /// «Кладовщик» ведёт Лиорио — такие фразы передам»; `null` — без строки.
  final String? note;

  /// Ведущий оповещений (в Соло — Связной): его знак у строк о просроченных
  /// и тренировке. `null` — без знака.
  final Persona? notifier;

  /// Род главного ещё не выбран: карточка выбора, нажатие — выбранный род;
  /// `null` — карточки нет.
  final ValueChanged<ReplyGender>? onSadoGender;

  /// Сколько задач просрочено; 0 — строки нет.
  final int overdue;

  /// Нажатие на строку о просроченных («Мой …» → «Сводка»).
  final VoidCallback? onOverdue;

  /// Пора потренировать пароль: нажатие задаёт вопрос; `null` — строки
  /// нет.
  final VoidCallback? onTraining;

  /// «Просрочена 1 задача», «Просрочены 2 задачи», «Просрочено 5 задач».
  static String overdueLabel(int n) =>
      '${ruPlural(n, 'Просрочена', 'Просрочены', 'Просрочено')} $n '
      '${ruPlural(n, 'задача', 'задачи', 'задач')}';

  /// Строка о ролях, которые ведёт не главный: `null`, если все роли у
  /// [main]. Текст одной строки — [line] (запись каталога
  /// `session.handoff.note` голосом главного): роли через запятую и кто их
  /// ведёт.
  static String? noteFor(
    Iterable<(String roleTitle, Persona owner)> roles,
    Persona main, {
    required String Function(String roles, Persona owner) line,
  }) {
    final others = <String, (Persona, List<String>)>{};
    for (final (title, owner) in roles) {
      if (owner.id == main.id) continue;
      others
          .putIfAbsent(owner.id, () => (owner, <String>[]))
          .$2
          .add('«$title»');
    }
    if (others.isEmpty) return null;
    return others.values
        .map(((Persona, List<String>) e) => line(e.$2.join(', '), e.$1))
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
            if (projectName != null) ...<Widget>[
              const SizedBox(height: 6),
              Row(
                key: const Key('hero-project'),
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: AssistantColors.muted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        style: metaTextStyle,
                        children: <InlineSpan>[
                          const TextSpan(text: 'Проект «'),
                          // Название проекта — шрифтом названия (ADR-021).
                          TextSpan(
                            text: projectName,
                            style: projectNameStyle(
                              fontSize: 15,
                              color: AssistantColors.muted,
                            ),
                          ),
                          const TextSpan(text: '»'),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            if (note != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                note!,
                key: const Key('session-hero-note'),
                textAlign: TextAlign.center,
                style: metaTextStyle,
              ),
            ],
            if (onSadoGender != null) ...<Widget>[
              const SizedBox(height: 16),
              _GenderChoice(name: persona.russianName, onChosen: onSadoGender!),
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

/// «Связной или Связная?» (имя не меняли) или «Мира — он или она?»
/// (своё имя) и два чипа. Выбор пишется в настройки, и
/// карточка исчезает.
final class _GenderChoice extends StatelessWidget {
  const _GenderChoice({required this.name, required this.onChosen});

  final String name;
  final ValueChanged<ReplyGender> onChosen;

  @override
  Widget build(BuildContext context) {
    // Имя не меняли — вопрос о самом имени: «Связной или Связная?»
    // (ADR-017). Своё имя от рода не зависит.
    final builtin = Personas.sado.isDefaultName(name);
    final question = builtin
        ? '${Personas.sado.defaultNameFor(ReplyGender.male)} или '
            '${Personas.sado.defaultNameFor(ReplyGender.female)}?'
        : '$name — он или она?';
    final hint = builtin
        ? 'Так зовут главного помощника, и так он говорит о себе. '
            'Поменять можно в «Помощниках».'
        : 'От этого зависит, как помощник говорит о себе. '
            'Поменять можно в «Помощниках».';
    String label(ReplyGender gender) {
      final pronoun = gender == ReplyGender.female ? 'она' : 'он';
      return builtin
          ? '${Personas.sado.defaultNameFor(gender)} ($pronoun)'
          : '${pronoun[0].toUpperCase()}${pronoun.substring(1)}';
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        key: const Key('sado-gender-choice'),
        decoration: BoxDecoration(
          color: AssistantColors.raised,
          border: Border.all(color: AssistantColors.borderSoft),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                question,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AssistantColors.textStrong),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: metaTextStyle,
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final gender in const <ReplyGender>[
                    ReplyGender.male,
                    ReplyGender.female,
                  ])
                    ActionChip(
                      key: ValueKey<String>('sado-gender-${gender.name}'),
                      label: Text(label(gender)),
                      onPressed: () => onChosen(gender),
                      labelStyle: const TextStyle(color: AssistantColors.text),
                      backgroundColor: AssistantColors.workspace,
                      side: const BorderSide(color: AssistantColors.sado),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка ведущего оповещений под «Что сделать?»: знак, текст и «›». Цель
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
                    style: metaTextStyle.copyWith(color: color),
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
