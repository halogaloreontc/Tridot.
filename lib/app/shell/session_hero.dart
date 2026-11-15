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
    // Не уместилась (крупный шрифт, маленький экран) — низ заставки
    // гаснет над быстрыми действиями, а не обрезан посреди строки; дальше
    // она прокручивается. Целиком видимую заставку маска не задевает:
    // снизу у неё поле 32.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) {
        final fade = bounds.height <= 0 ? 0.0 : 28 / bounds.height;
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: <double>[0, (1 - fade).clamp(0.0, 1.0), 1],
        ).createShader(bounds);
      },
      child: _scroll(context),
    );
  }

  Widget _scroll(BuildContext context) {
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
              child: Text(
                'Что сделать?',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium!
                    .copyWith(color: context.colors.textStrong),
              ),
            ),
            if (projectName != null) ...<Widget>[
              const SizedBox(height: 6),
              Row(
                key: const Key('hero-project'),
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: context.colors.muted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge!
                            .copyWith(color: context.colors.muted),
                        children: <InlineSpan>[
                          const TextSpan(text: 'Проект «'),
                          // Название проекта — шрифтом названия (ADR-021).
                          TextSpan(
                            text: projectName,
                            style: projectNameStyle(
                              fontSize: 17,
                              color: context.colors.muted,
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
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge!
                    .copyWith(color: context.colors.muted),
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
                color: context.colors.danger,
                semantics: '${overdueLabel(overdue)}. Открыть «Сводку»',
                onTap: onOverdue,
              ),
            if (onTraining != null)
              _HeroLine(
                key: const Key('session-hero-training'),
                persona: notifier,
                text: 'Пора потренировать пароль',
                color: context.colors.text,
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

    // Карточка заливкой без рамки, выбор — двумя тональными кнопками
    // (ADR-027).
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: DecoratedBox(
        key: const Key('sado-gender-choice'),
        decoration: BoxDecoration(
          color: context.colors.raised,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                question,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium!
                    .copyWith(color: context.colors.textStrong),
              ),
              const SizedBox(height: 4),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium!
                    .copyWith(color: context.colors.muted),
              ),
              const SizedBox(height: 12),
              // Две кнопки в одну строку, если подписи помещаются целиком;
              // иначе — короткие подписи («Связной» / «Связная»), а при
              // совсем крупном шрифте — стопкой во всю ширину. Стопка
              // узких кнопок уходила под быстрые действия.
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  final style = Theme.of(context).textTheme.labelLarge!;
                  final scaler = MediaQuery.textScalerOf(context);
                  const pad = 16.0;
                  final half = (box.maxWidth - 8) / 2;
                  bool fits(String Function(ReplyGender) text) => <ReplyGender>[
                        ReplyGender.male,
                        ReplyGender.female,
                      ].every((ReplyGender g) {
                        final painter = TextPainter(
                          text: TextSpan(text: text(g), style: style),
                          textDirection: TextDirection.ltr,
                          textScaler: scaler,
                          maxLines: 1,
                        )..layout();
                        final w = painter.width;
                        painter.dispose();
                        return w + pad <= half;
                      });
                  String short(ReplyGender g) =>
                      builtin ? Personas.sado.defaultNameFor(g) : label(g);
                  final String Function(ReplyGender)? inRow = fits(label)
                      ? label
                      : fits(short)
                          ? short
                          : null;
                  Widget button(ReplyGender gender, String text) =>
                      FilledButton.tonal(
                        key: ValueKey<String>('sado-gender-${gender.name}'),
                        onPressed: () => onChosen(gender),
                        style: FilledButton.styleFrom(
                          backgroundColor: context.colors.bubble,
                          foregroundColor: context.colors.accent,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: pad / 2,
                            vertical: 10,
                          ),
                        ),
                        child: Text(text, textAlign: TextAlign.center),
                      );
                  const genders = <ReplyGender>[
                    ReplyGender.male,
                    ReplyGender.female,
                  ];
                  if (inRow != null) {
                    return Row(
                      children: <Widget>[
                        Expanded(child: button(genders[0], inRow(genders[0]))),
                        const SizedBox(width: 8),
                        Expanded(child: button(genders[1], inRow(genders[1]))),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      button(genders[0], label(genders[0])),
                      const SizedBox(height: 8),
                      button(genders[1], label(genders[1])),
                    ],
                  );
                },
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
          constraints: const BoxConstraints(minHeight: 48),
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
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium!
                        .copyWith(color: color),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
