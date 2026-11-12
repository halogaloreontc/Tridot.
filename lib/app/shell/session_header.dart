import 'package:flutter/material.dart';

import '../../core/formatting/plural.dart';
import '../assistant_theme.dart';

/// Шапка сессии (макет «Д»): слева меню или «назад», в центре помощник
/// («Лиорио ▾» → «Мой Связной», вкладка «Помощники») или заголовок, справа
/// «Сегодня N».
///
/// Своего состояния нет: всё приходит параметрами и колбэками.
final class SessionHeader extends StatelessWidget {
  const SessionHeader({
    super.key,
    required this.today,
    this.leading,
    this.title,
    this.personaName,
    this.onPersona,
    this.subtitle,
    this.wide = false,
  });

  /// Кнопка слева: меню, «назад»; `null` — пусто (на широком экране меню
  /// всегда открыто).
  final Widget? leading;

  /// Заголовок в центре вместо помощника (чат задачи, разделы).
  final Widget? title;

  /// Имя помощника кириллицей: «Лиорио».
  final String? personaName;
  final VoidCallback? onPersona;

  /// Подпись справа от помощника на широком экране: «сессия «Главный»».
  final String? subtitle;

  /// Широкий экран: помощник слева, без сетки 1fr / auto / 1fr.
  final bool wide;

  /// Кнопка «Сегодня» справа.
  final Widget today;

  @override
  Widget build(BuildContext context) {
    final center = title ??
        (personaName == null
            ? const SizedBox.shrink()
            : _PersonaSwitch(name: personaName!, onTap: onPersona));
    if (wide) {
      return SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 4),
              ],
              // Помощник и подпись — по своей ширине слева, «Сегодня» —
              // у правого края колонки (D-Desk).
              Expanded(
                child: title != null
                    ? center
                    : Row(
                        children: <Widget>[
                          Flexible(child: center),
                          if (subtitle != null) ...<Widget>[
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                subtitle!,
                                key: const Key('session-subtitle'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: technicalTextStyle,
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              today,
            ],
          ),
        ),
      );
    }
    // Телефон: сетка 1fr / auto / 1fr — помощник ровно посередине, края
    // своего размера.
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: NavigationToolbar(
          leading: leading,
          middle: center,
          trailing: today,
          middleSpacing: 4,
        ),
      ),
    );
  }
}

final class _PersonaSwitch extends StatelessWidget {
  const _PersonaSwitch({required this.name, required this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      header: true,
      label: '$name — помощник. Сменить в «Мой Связной», раздел «Помощники»',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('persona-switch'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AssistantColors.textStrong,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.keyboard_arrow_down,
                  size: 18,
                  color: AssistantColors.textStrong,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «Сегодня N»: дела на сегодня и просроченные; красная точка — если
/// что-то просрочено. На узком экране и при крупном шрифте подпись
/// прячется, остаются иконка и число.
final class TodayButton extends StatelessWidget {
  const TodayButton({
    super.key,
    required this.count,
    required this.overdue,
    required this.onPressed,
    this.compact = false,
    this.expanded,
  });

  final int count;

  /// Сколько из них просрочено.
  final int overdue;
  final VoidCallback onPressed;

  /// Только иконка и число.
  final bool compact;

  /// Колонка «Сегодня» на широком экране открыта; `null` — это выдвижная
  /// панель.
  final bool? expanded;

  /// «Сегодня: 3 дела, одно просрочено».
  static String semanticLabel(int count, int overdue) {
    final base = 'Сегодня: ${deeds(count)}';
    if (overdue == 0) return base;
    if (overdue == 1) return '$base, одно просрочено';
    return '$base, просрочено $overdue';
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final hideLabel = compact || scale > 1.3;
    return Semantics(
      button: true,
      expanded: expanded,
      label: semanticLabel(count, overdue),
      onTap: onPressed,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('today-button'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          child: Center(
            widthFactor: 1,
            child: Container(
              height: 36,
              padding: EdgeInsets.fromLTRB(hideLabel ? 8 : 10, 0, 6, 0),
              decoration: BoxDecoration(
                color: expanded == true ? AssistantColors.raised : null,
                border: Border.all(color: AssistantColors.border),
                borderRadius: BorderRadius.circular(18),
              ),
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.today_outlined,
                      size: 16,
                      color: AssistantColors.textStrong,
                    ),
                    if (!hideLabel) ...<Widget>[
                      const SizedBox(width: 6),
                      const Text(
                        'Сегодня',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    _Count(count: count, overdue: overdue > 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _Count extends StatelessWidget {
  const _Count({required this.count, required this.overdue});

  final int count;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withNoTextScaling(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AssistantColors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              key: const Key('today-count'),
              style: const TextStyle(
                fontFamily: 'JetBrains Mono',
                fontFamilyFallback: <String>['monospace'],
                fontSize: 12,
                height: 1,
                fontWeight: FontWeight.w500,
                color: AssistantColors.onPrimary,
              ),
            ),
          ),
          if (overdue)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                key: const Key('today-overdue-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AssistantColors.danger,
                  border: Border.all(
                    color: AssistantColors.workspace,
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
