import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../widgets/persona_mark.dart';
import 'session_hold_menu.dart';

/// Шапка сессии (макет «Д»): слева меню или «назад», в центре название
/// сессии со стрелкой ▾ и под ним — кто в ней отвечает, или заголовок
/// ([title]: чат задачи, раздел), справа — необязательная кнопка
/// ([trailing]: «⋯» с «История команд» и на компьютере — «Показать
/// «Сегодня»», когда колонка свёрнута). Всегда одна строка 56.
///
/// Нажатие на название открывает то же меню сессии, что долгое нажатие на
/// её строку в боковой панели: «Переименовать», «Закрепить», «Удалить»
/// ([onSessionAction]). В настройки помощников шапка не ведёт — они в
/// разделе помощников (`AppInfo.hubName`).
///
/// Своего состояния нет: всё приходит параметрами и колбэками.
final class SessionHeader extends StatelessWidget {
  const SessionHeader({
    super.key,
    this.leading,
    this.trailing,
    this.title,
    this.sessionTitle,
    this.persona,
    this.onSessionAction,
    this.pinned = false,
    this.canRename = true,
    this.canMove = false,
    this.projectName,
    this.reduceMotion = false,
    this.wide = false,
    this.sessionMenuBeside = false,
    this.cube,
  });

  /// Кубик состояния помощника справа от подписи — только пока он работает
  /// или показывает итог (ADR-027); в ленте кубика нет.
  final Widget? cube;

  /// Заголовок [title] не заменяет меню сессии, а стоит рядом с ним
  /// (задача в фокусе, «Задача» и её название): справа — кнопка меню сессии
  /// (ключ `session-title`), меню то же, что у названия.
  final bool sessionMenuBeside;

  /// В меню есть «В проект…» (ADR-018).
  final bool canMove;

  /// Проект-папка открытой сессии: в подписи под названием — значок папки
  /// и его название; `null` — вне проектов.
  final String? projectName;

  /// Кнопка слева: меню, «назад»; `null` — пусто (на широком экране меню
  /// всегда открыто).
  final Widget? leading;

  /// Заголовок в центре вместо названия сессии (чат задачи, разделы).
  final Widget? title;

  /// Название открытой сессии: «Новая сессия» или первая команда.
  final String? sessionTitle;

  /// Кто отвечает в этой сессии: подпись под названием (знак и имя).
  final Persona? persona;

  /// Выбрано действие из меню сессии; `null` — меню нет (пустая сессия:
  /// переименовывать и удалять ещё нечего).
  final ValueChanged<SessionAction>? onSessionAction;

  /// Сессия закреплена: в меню — «Открепить».
  final bool pinned;

  /// В меню есть «Переименовать».
  final bool canRename;
  final bool reduceMotion;

  /// Широкий экран: название слева, без сетки 1fr / auto / 1fr.
  final bool wide;

  /// Кнопка справа; `null` — пусто.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    final onSessionAction = this.onSessionAction;
    if (title != null &&
        sessionMenuBeside &&
        sessionTitle != null &&
        onSessionAction != null) {
      return _withCenter(
        _SessionMenuBeside(
          title: sessionTitle!,
          persona: persona,
          onAction: onSessionAction,
          pinned: pinned,
          canRename: canRename,
          canMove: canMove,
          projectName: projectName,
          reduceMotion: reduceMotion,
          child: title,
        ),
        stretch: true,
      );
    }
    final center = title ??
        (sessionTitle == null
            ? const SizedBox.shrink()
            : _SessionTitle(
                title: sessionTitle!,
                persona: persona,
                cube: cube,
                onAction: onSessionAction,
                pinned: pinned,
                canRename: canRename,
                canMove: canMove,
                projectName: projectName,
                reduceMotion: reduceMotion,
                wide: wide,
              ));
    return _withCenter(center, stretch: title != null);
  }

  Widget _withCenter(Widget center, {required bool stretch}) {
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
              // Название — по своей ширине слева, кнопка — у правого края
              // колонки (D-Desk).
              Expanded(
                child: stretch
                    ? center
                    : Align(alignment: Alignment.centerLeft, child: center),
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
    // Телефон: сетка 1fr / auto / 1fr — название ровно посередине, края
    // своего размера.
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
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

/// Заголовок задачи в фокусе ([child]) и рядом — кнопка меню сессии: то же
/// меню, что у названия; поднимается название сессии на месте заголовка.
final class _SessionMenuBeside extends StatefulWidget {
  const _SessionMenuBeside({
    required this.title,
    required this.persona,
    required this.onAction,
    required this.pinned,
    required this.canRename,
    required this.canMove,
    required this.projectName,
    required this.reduceMotion,
    required this.child,
  });

  final String title;
  final Persona? persona;
  final ValueChanged<SessionAction> onAction;
  final bool pinned;
  final bool canRename;
  final bool canMove;
  final String? projectName;
  final bool reduceMotion;
  final Widget child;

  @override
  State<_SessionMenuBeside> createState() => _SessionMenuBesideState();
}

final class _SessionMenuBesideState extends State<_SessionMenuBeside> {
  final GlobalKey _row = GlobalKey();

  Future<void> _openMenu() async {
    final box = _row.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    unawaited(HapticFeedback.selectionClick());
    final action = await showSessionHoldMenu(
      context,
      rowRect: rect,
      title: widget.title,
      pinned: widget.pinned,
      canRename: widget.canRename,
      canMove: widget.canMove,
      reduceMotion: widget.reduceMotion,
      liftedRow: SizedBox(
        height: rect.height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: _TitleBody(
            title: widget.title,
            persona: widget.persona,
            projectName: widget.projectName,
            arrow: true,
            center: false,
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action != null) widget.onAction(action);
  }

  @override
  Widget build(BuildContext context) => Row(
        key: _row,
        children: <Widget>[
          Expanded(child: widget.child),
          IconButton(
            key: const Key('session-title'),
            tooltip: 'Меню сессии «${widget.title}»',
            onPressed: _openMenu,
            style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
            icon:
                Icon(Icons.more_horiz, size: 22, color: context.colors.accent),
          ),
        ],
      );
}

/// Название сессии в шапке: «Название ▾» и под ним знак и имя того, кто
/// отвечает. Нажатие — меню сессии; нажатое название приподнимается, как
/// строка в боковой панели.
final class _SessionTitle extends StatefulWidget {
  const _SessionTitle({
    required this.title,
    required this.persona,
    this.cube,
    required this.onAction,
    required this.pinned,
    required this.canRename,
    required this.canMove,
    required this.projectName,
    required this.reduceMotion,
    required this.wide,
  });

  final String title;
  final Persona? persona;
  final Widget? cube;
  final ValueChanged<SessionAction>? onAction;
  final bool pinned;
  final bool canRename;
  final bool canMove;
  final String? projectName;
  final bool reduceMotion;
  final bool wide;

  @override
  State<_SessionTitle> createState() => _SessionTitleState();
}

final class _SessionTitleState extends State<_SessionTitle> {
  bool _held = false;

  Future<void> _openMenu() async {
    final onAction = widget.onAction;
    if (onAction == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _held = true);
    final action = await showSessionHoldMenu(
      context,
      rowRect: rect,
      title: widget.title,
      pinned: widget.pinned,
      canRename: widget.canRename,
      canMove: widget.canMove,
      reduceMotion: widget.reduceMotion,
      liftedRow: SizedBox(
        height: rect.height,
        child: _TitleBody(
          title: widget.title,
          persona: widget.persona,
          projectName: widget.projectName,
          arrow: true,
          center: !widget.wide,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _held = false);
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final acts = widget.onAction != null;
    final name = widget.persona?.russianName;
    return Semantics(
      button: acts,
      header: true,
      label: acts
          ? 'Сессия «${widget.title}»'
              '${widget.projectName == null ? '' : ', проект «${widget.projectName}»'}'
              '. Меню сессии'
          : 'Сессия «${widget.title}»'
              '${widget.projectName == null ? '' : ', проект «${widget.projectName}»'}'
              '${name == null ? '' : ', отвечает $name'}',
      onTap: acts ? _openMenu : null,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('session-title'),
        onTap: acts ? _openMenu : null,
        borderRadius: BorderRadius.circular(12),
        child: Opacity(
          // Название «поднято» в меню: на месте — пусто.
          opacity: _held ? 0 : 1,
          child: _TitleBody(
            title: widget.title,
            persona: widget.persona,
            projectName: widget.projectName,
            arrow: acts,
            center: !widget.wide,
            cube: widget.cube,
          ),
        ),
      ),
    );
  }
}

final class _TitleBody extends StatelessWidget {
  const _TitleBody({
    required this.title,
    required this.persona,
    required this.arrow,
    required this.center,
    this.projectName,
    this.cube,
  });

  final Widget? cube;
  final String title;
  final Persona? persona;
  final String? projectName;
  final bool arrow;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final persona = this.persona;
    final align = center ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    // Две строки в шапке высотой 56: крупный шрифт растёт до 1,3 — дальше
    // название обрезается многоточием, а не вылезает из шапки.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: align,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    // Одно слово («Планирование») при нехватке места
                    // уменьшается целиком, несколько — режутся многоточием.
                    child: _fitIfOneWord(
                      Text(
                        title,
                        key: const Key('session-title-text'),
                        maxLines: 1,
                        softWrap: !title.trim().contains(' ') ? false : null,
                        overflow: title.trim().contains(' ')
                            ? TextOverflow.ellipsis
                            : null,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: context.colors.textStrong,
                        ),
                      ),
                    ),
                  ),
                  if (arrow) ...<Widget>[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: context.colors.textStrong,
                    ),
                  ],
                ],
              ),
              if (persona != null || projectName != null || cube != null)
                Row(
                  key: const Key('session-persona'),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (projectName != null) ...<Widget>[
                      Icon(
                        Icons.folder_outlined,
                        key: Key('session-project'),
                        size: 13,
                        color: context.colors.muted,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          projectName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            color: context.colors.muted,
                          ),
                        ),
                      ),
                      if (persona != null) const SizedBox(width: 8),
                    ],
                    if (persona != null) ...<Widget>[
                      PersonaDot(persona: persona),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          persona.russianName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            color: context.colors.muted,
                          ),
                        ),
                      ),
                    ],
                    if (cube case final Widget cube) ...<Widget>[
                      const SizedBox(width: 8),
                      cube,
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [text] одного слова — в FittedBox (уменьшается целиком), иначе как есть.
Widget _fitIfOneWord(Text text) => (text.data ?? '').trim().contains(' ')
    ? text
    : FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: text,
      );
