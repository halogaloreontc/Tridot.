import 'package:flutter/material.dart';

import '../assistant_theme.dart';

/// Шапка сессии (макет «Д»): слева меню или «назад», в центре помощник
/// («Лиорио ▾» → «Мой Связной», вкладка «Помощники») или заголовок, справа
/// — необязательная кнопка ([trailing]; на компьютере — «Показать
/// «Сегодня»», когда колонка свёрнута). Под строкой — хроника команд
/// ([below]), по центру.
///
/// Своего состояния нет: всё приходит параметрами и колбэками.
final class SessionHeader extends StatelessWidget {
  const SessionHeader({
    super.key,
    this.leading,
    this.trailing,
    this.below,
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

  /// Кнопка справа; `null` — пусто.
  final Widget? trailing;

  /// Под строкой шапки, по центру: хроника команд. `null` — шапка только
  /// в одну строку.
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final below = this.below;
    // Всегда Column: появление хроники не пересоздаёт строку шапки.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _row(),
        if (below != null) Center(child: below),
      ],
    );
  }

  Widget _row() {
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
              // Помощник и подпись — по своей ширине слева, кнопка —
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
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 8),
                trailing!,
              ],
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
          trailing: trailing,
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
