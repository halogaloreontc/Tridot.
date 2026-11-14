import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chats/chat_models.dart';
import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';

/// Действие с сессией из меню долгого нажатия.
enum SessionAction {
  /// «Переименовать».
  rename,

  /// «Закрепить» / «Открепить».
  pin,

  /// «В проект…»: перенести в проект-папку или вынести из неё (ADR-018).
  move,

  /// «Удалить».
  delete,
}

/// Меню действий с сессией (макет «Ж2»): нажатая строка чуть
/// приподнимается и подсвечивается, под ней справа — короткое меню
/// «Переименовать», «Закрепить», «В проект…» ([canMove]), черта,
/// «Удалить»; остальное слегка затемнено. Нажатие мимо, «Назад» и Esc закрывают меню без действия.
///
/// [rowRect] — строка в глобальных координатах, [liftedRow] — её
/// содержимое без жестов. Возвращает выбранное действие или `null`.
Future<SessionAction?> showSessionHoldMenu(
  BuildContext context, {
  required Rect rowRect,
  required String title,
  required Widget liftedRow,
  bool pinned = false,
  bool canRename = true,
  bool canMove = false,
  bool reduceMotion = false,
}) {
  return Navigator.of(context).push<SessionAction>(
    _HoldMenuRoute(
      rowRect: rowRect,
      title: title,
      liftedRow: liftedRow,
      pinned: pinned,
      canRename: canRename,
      canMove: canMove,
      still:
          reduceMotion || MediaQuery.maybeDisableAnimationsOf(context) == true,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context).context,
      ),
    ),
  );
}

final class _HoldMenuRoute extends PopupRoute<SessionAction> {
  _HoldMenuRoute({
    required this.rowRect,
    required this.title,
    required this.liftedRow,
    required this.pinned,
    required this.canRename,
    required this.canMove,
    required this.still,
    required this.capturedThemes,
  });

  final Rect rowRect;
  final String title;
  final Widget liftedRow;
  final bool pinned;
  final bool canRename;
  final bool canMove;
  final bool still;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Закрыть меню действий';

  @override
  Duration get transitionDuration =>
      still ? Duration.zero : const Duration(milliseconds: 160);

  @override
  Duration get reverseTransitionDuration =>
      still ? Duration.zero : const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return capturedThemes.wrap(
      _HoldMenuLayer(
        route: this,
        animation: still ? kAlwaysCompleteAnimation : animation,
      ),
    );
  }
}

final class _HoldMenuLayer extends StatelessWidget {
  const _HoldMenuLayer({required this.route, required this.animation});

  final _HoldMenuRoute route;
  final Animation<double> animation;

  /// Ширина меню (макет — 236).
  static const double menuWidth = 236;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final padding = MediaQuery.paddingOf(context);
    final row = route.rowRect;
    final scaler = MediaQuery.textScalerOf(context);
    final scale = scaler.scale(1);
    // Ширина: обычно 236 (не шире строки без полей); крупному шрифту — сколько
    // нужно самой длинной подписи, но не шире экрана: подписи не обрезаются,
    // меню растёт влево.
    final room = math.max(160.0, screen.width - 16);
    final base = math.min(menuWidth, math.max(160.0, row.width - 24));
    double needed({required bool icons}) => _HoldMenu.neededWidth(
          scaler,
          pinned: route.pinned,
          canMove: route.canMove,
          icons: icons,
          // Как у текста внутри Material меню: шрифт темы.
          base: Theme.of(context).textTheme.bodyMedium,
        );
    // Совсем крупный шрифт на узком экране: значки уступают место словам.
    final icons = needed(icons: true) <= room;
    final width = math.min(room, math.max(base, needed(icons: icons)));
    final items = 2 + (route.canRename ? 1 : 0) + (route.canMove ? 1 : 0);
    // Высота меню: пункты по 52 (крупный шрифт — выше), черта, поля.
    final menuHeight = 12 + items * math.max(52.0, 30 + 16 * scale) + 9;
    final bottomLimit = screen.height - insets.bottom - padding.bottom - 8;
    final below = row.bottom + 6;
    final top = below + menuHeight <= bottomLimit
        ? below
        : math.max(padding.top + 8, row.top - 6 - menuHeight);
    // По правому краю строки; широкое меню сдвигается, но не за левый край.
    final right = math.max(
      0.0,
      math.min(
        math.max(8.0, screen.width - row.right),
        screen.width - width - 8,
      ),
    );
    void choose(SessionAction action) => Navigator.of(context).pop(action);
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Stack(
        children: <Widget>[
          // Лёгкое затемнение; нажатия проходят к барьеру маршрута.
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: fade,
                child: const ColoredBox(
                  key: Key('session-menu-dim'),
                  color: AssistantColors.scrimLight,
                ),
              ),
            ),
          ),
          // Нажатая строка — приподнята над затемнением.
          Positioned(
            // Без высоты: рамка добавляет по пикселю, содержимое не
            // сжимается.
            left: row.left - 1,
            top: row.top - 1,
            width: row.width + 2,
            // Копия строки — только картинка: диктор её не читает (меню само
            // называет сессию), иначе строка звучала бы второй раз.
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: fade,
                  builder: (BuildContext context, Widget? child) =>
                      Transform.translate(
                    offset: Offset(0, -2 * fade.value),
                    child: child,
                  ),
                  child: Container(
                    key: const Key('session-menu-lifted'),
                    decoration: BoxDecoration(
                      color: AssistantColors.bubble,
                      border: Border.all(color: AssistantColors.border),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: AssistantColors.shadow,
                          blurRadius: 28,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: route.liftedRow,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: right,
            top: top,
            width: width,
            child: FadeTransition(
              opacity: fade,
              child: _HoldMenu(
                icons: icons,
                title: route.title,
                pinned: route.pinned,
                canRename: route.canRename,
                canMove: route.canMove,
                onChoose: choose,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _HoldMenu extends StatelessWidget {
  const _HoldMenu({
    required this.icons,
    required this.title,
    required this.pinned,
    required this.canRename,
    required this.canMove,
    required this.onChoose,
  });

  /// Значки у пунктов (без них — при очень крупном шрифте).
  final bool icons;
  final String title;
  final bool pinned;
  final bool canRename;
  final bool canMove;
  final ValueChanged<SessionAction> onChoose;

  /// Пункт переноса в проект-папку.
  static const String moveLabel = 'В проект…';

  /// Подпись пункта: 16 px, как в макете «Ж2».
  static const TextStyle labelStyle = TextStyle(fontSize: 16, height: 1.3);

  /// Ширина меню, при которой самая длинная подпись помещается целиком с
  /// шрифтом [scaler]: поля меню 6 + 6, рамка 1 + 1, поля пункта 16 + 16,
  /// значок 20 и отступ 14 (если [icons]).
  static double neededWidth(
    TextScaler scaler, {
    required bool pinned,
    bool canMove = false,
    bool icons = true,
    TextStyle? base,
  }) {
    final style = base?.merge(labelStyle) ?? labelStyle;
    var widest = 0.0;
    for (final label in <String>[
      'Переименовать',
      if (pinned) 'Открепить' else 'Закрепить',
      if (canMove) moveLabel,
      'Удалить',
    ]) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return (12 + 2 + 32 + (icons ? 34 : 0) + widest + 2).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Действия с сессией «$title»',
      child: Container(
        key: const Key('session-menu'),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AssistantColors.raised,
          border: Border.all(color: AssistantColors.border),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: AssistantColors.shadow,
              blurRadius: 40,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (canRename)
                  _MenuItem(
                    key: const Key('session-menu-rename'),
                    showIcon: icons,
                    icon: Icons.edit_outlined,
                    label: 'Переименовать',
                    autofocus: true,
                    onTap: () => onChoose(SessionAction.rename),
                  ),
                _MenuItem(
                  key: const Key('session-menu-pin'),
                  showIcon: icons,
                  icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  label: pinned ? 'Открепить' : 'Закрепить',
                  autofocus: !canRename,
                  onTap: () => onChoose(SessionAction.pin),
                ),
                if (canMove)
                  _MenuItem(
                    key: const Key('session-menu-move'),
                    showIcon: icons,
                    icon: Icons.drive_file_move_outline,
                    label: moveLabel,
                    onTap: () => onChoose(SessionAction.move),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    color: AssistantColors.borderSoft,
                  ),
                ),
                _MenuItem(
                  key: const Key('session-menu-delete'),
                  showIcon: icons,
                  icon: Icons.delete_outline,
                  label: 'Удалить',
                  danger: true,
                  onTap: () => onChoose(SessionAction.delete),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _MenuItem extends StatelessWidget {
  const _MenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.showIcon = true,
    this.danger = false,
    this.autofocus = false,
  });

  final bool showIcon;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AssistantColors.danger : AssistantColors.text;
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                if (showIcon) ...<Widget>[
                  Icon(
                    icon,
                    size: 20,
                    color:
                        danger ? AssistantColors.danger : AssistantColors.icon,
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  // Меню шире под крупный шрифт; если и экрана мало —
                  // перенос на вторую строку, а не обрезка.
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _HoldMenu.labelStyle.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «Переименовать»: поле с нынешним названием. Возвращает новое название
/// (без пробелов по краям, 1–[ChatThread.customTitleLimit] знаков) или
/// `null` — «Отмена».
Future<String?> showRenameSessionDialog(
  BuildContext context, {
  required String current,
  String title = 'Переименовать сессию',
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) =>
        _RenameDialog(current: current, title: title),
  );
}

final class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current, required this.title});

  final String current;
  final String title;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

final class _RenameDialogState extends State<_RenameDialog> {
  // Длина — в видимых знаках, как у maxLength поля: длинное название
  // обрезается по знакам, а не посреди эмодзи.
  late final String _initial = ChatThread.titleLength(widget.current) >
          ChatThread.customTitleLimit
      ? widget.current.characters.take(ChatThread.customTitleLimit).toString()
      : widget.current;
  late final TextEditingController _text = TextEditingController(
    text: _initial,
  )..selection = TextSelection(baseOffset: 0, extentOffset: _initial.length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => _text.text.replaceAll(RegExp(r'\s+'), ' ').trim();

  void _save() {
    if (_value.isEmpty) return;
    Navigator.of(context).pop(_value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AssistantColors.raised,
      // Крупный шрифт и открытая клавиатура (поле с autofocus) на узком
      // телефоне: окно прокручивается, а не вылезает за край.
      scrollable: true,
      title: WholeWordText(widget.title),
      content: TextField(
        key: const Key('rename-field'),
        controller: _text,
        autofocus: true,
        maxLength: ChatThread.customTitleLimit,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.deny(RegExp('[\n\r]')),
        ],
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _save(),
        decoration: const InputDecoration(labelText: 'Название'),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('rename-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('rename-save'),
          onPressed: _value.isEmpty ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// «Удалить сессию «…»? Это нельзя отменить.» У чата задачи —
/// с припиской, что задача останется. `true` — удалить.
Future<bool> showDeleteSessionDialog(
  BuildContext context, {
  required String title,
  bool task = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      backgroundColor: AssistantColors.raised,
      title: const WholeWordText('Удалить сессию?'),
      content: Text(
        'Удалить сессию «$title»? Это нельзя отменить.'
        '${task ? ' Задача останется.' : ''}',
        key: const Key('delete-text'),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('delete-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          key: const Key('delete-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: AssistantColors.danger,
          ),
          child: const Text('Удалить'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
