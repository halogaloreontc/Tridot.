import 'package:flutter/material.dart';

import '../../core/extensions/role.dart';
import '../assistant_theme.dart';
import '../widgets/quick_dock.dart';

/// Быстрое действие: подпись (она же ключ `quick-<подпись>`), иконка и
/// что делать; `null` — недоступно (идёт отправка).
typedef QuickAction = (String label, IconData icon, VoidCallback? onTap);

/// Быстрые действия над полем ввода (макет «Д»).
///
/// - [big] — пустая (новая) сессия: круглые кнопки 52 px «Задача»,
///   «Напомнить» и, если включён навык «Пароли», «Пароль». Только здесь:
///   когда в сессии уже есть сообщения, этих трёх кнопок нет — поле ввода
///   и «+» их заменяют.
/// - Ниже — кнопки включённых ролей и действия выбранной задачи
///   («Перенести», «Заверши её»): переносом по строкам ('quick-rows').
///   Нет ни того, ни другого — виджет пустой, без отступов.
/// - Тесно (узкий экран и крупный шрифт, [QuickDock.isTight]) — всё одной
///   строкой с горизонтальной прокруткой ('quick-strip').
final class QuickActions extends StatefulWidget {
  const QuickActions({
    super.key,
    required this.big,
    required this.sending,
    required this.onSend,
    required this.onTemplate,
    this.onPassword,
    this.hasSelection = false,
    this.roleChips = const <RoleChip>[],
  });

  final bool big;
  final bool sending;
  final Future<void> Function([String? preset]) onSend;
  final ValueChanged<String> onTemplate;

  /// «Пароль»: `null` — навык «Пароли» выключен, кнопки нет.
  final VoidCallback? onPassword;

  /// В сессии выбрана активная задача («её»).
  final bool hasSelection;

  /// Кнопки включённых ролей: отправить сразу или вставить шаблон.
  final List<RoleChip> roleChips;

  /// Шаблоны «Задачи» и «Напомнить»: «|» — место курсора.
  static const String taskTemplate = 'Добавь задачу «|»';
  static const String remindTemplate = 'Напомни |';

  @override
  State<QuickActions> createState() => _QuickActionsState();
}

final class _QuickActionsState extends State<QuickActions> {
  final ScrollController _rows = ScrollController();
  final ScrollController _strip = ScrollController();

  @override
  void dispose() {
    _rows.dispose();
    _strip.dispose();
    super.dispose();
  }

  static IconData _icon(String name) => switch (name) {
        'search' => Icons.search,
        'inbox' => Icons.move_to_inbox_outlined,
        'photo' => Icons.no_photography_outlined,
        'key' => Icons.key_outlined,
        'lock' => Icons.lock_outline,
        'password' => Icons.password,
        'shield' => Icons.shield_outlined,
        _ => Icons.chat_bubble_outline,
      };

  List<QuickAction> get _main => <QuickAction>[
        (
          'Задача',
          Icons.add_task,
          () => widget.onTemplate(QuickActions.taskTemplate),
        ),
        (
          'Напомнить',
          Icons.notifications_none,
          () => widget.onTemplate(QuickActions.remindTemplate),
        ),
        if (widget.onPassword case final VoidCallback onPassword)
          ('Пароль', Icons.key_outlined, onPassword),
      ];

  List<QuickAction> get _extra {
    final sending = widget.sending;
    return <QuickAction>[
      if (widget.hasSelection) ...<QuickAction>[
        (
          'Перенести',
          Icons.update,
          () => widget.onTemplate('Перенеси её на завтра в |'),
        ),
        (
          'Заверши её',
          Icons.check,
          sending ? null : () => widget.onSend('Заверши её'),
        ),
      ],
      for (final chip in widget.roleChips)
        (
          chip.label,
          _icon(chip.icon),
          switch (chip.action) {
            RoleChipAction.send =>
              sending ? null : () => widget.onSend(chip.text),
            RoleChipAction.insert => () => widget.onTemplate(chip.text),
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Три основные кнопки — только в новой сессии.
        final main = widget.big ? _main : const <QuickAction>[];
        final extra = _extra;
        if (main.isEmpty && extra.isEmpty) return const SizedBox.shrink();
        if (QuickDock.isTight(constraints)) {
          // Узкий экран и крупный шрифт: строк не уместить. Одна строка с
          // горизонтальной прокруткой и видимой полосой; кнопки ролей —
          // первыми, они нужнее всего тому, кто роль включил.
          final items = <QuickAction>[
            ...extra.where((QuickAction a) => !_isSelection(a)),
            ...main,
            ...extra.where(_isSelection),
          ];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Scrollbar(
              controller: _strip,
              thumbVisibility: true,
              child: SingleChildScrollView(
                key: const Key('quick-strip'),
                controller: _strip,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: <Widget>[
                    for (final (index, item) in items.indexed)
                      Padding(
                        padding: EdgeInsets.only(left: index == 0 ? 0 : 8),
                        child: _Pill(item: item, strip: true),
                      ),
                  ],
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Scrollbar(
            controller: _rows,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _rows,
              child: Column(
                key: const Key('quick-actions'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (main.isNotEmpty)
                    Semantics(
                      container: true,
                      label: 'Быстрые действия',
                      child: _BigRow(items: main),
                    ),
                  if (extra.isNotEmpty) ...<Widget>[
                    if (main.isNotEmpty) const SizedBox(height: 8),
                    Wrap(
                      key: const Key('quick-rows'),
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final item in extra)
                          _Pill(item: item, small: true),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static bool _isSelection(QuickAction action) =>
      action.$1 == 'Перенести' || action.$1 == 'Заверши её';
}

/// Круглые кнопки с подписями для пустой сессии.
final class _BigRow extends StatelessWidget {
  const _BigRow({required this.items});

  final List<QuickAction> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 28,
        runSpacing: 12,
        children: <Widget>[
          for (final (label, icon, onTap) in items)
            Semantics(
              button: true,
              enabled: onTap != null,
              label: label,
              onTap: onTap,
              excludeSemantics: true,
              child: InkWell(
                key: Key('quick-$label'),
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 76,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AssistantColors.raised,
                          shape: BoxShape.circle,
                          border: Border.all(color: AssistantColors.border),
                        ),
                        child: Icon(
                          icon,
                          size: 22,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: AssistantColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// «Пилюля» 44 px: в строках ролей ([small]) — по тексту.
final class _Pill extends StatelessWidget {
  const _Pill({
    required this.item,
    this.small = false,
    this.strip = false,
  });

  final QuickAction item;
  final bool small;

  /// В строке с горизонтальной прокруткой: ширина по тексту, без сжатия.
  final bool strip;

  @override
  Widget build(BuildContext context) {
    final (label, icon, onTap) = item;
    final color = onTap == null ? AssistantColors.faint : AssistantColors.text;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: TextStyle(fontSize: small ? 12 : 13, color: color),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: Key('quick-$label'),
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          height: 44,
          padding: EdgeInsets.symmetric(
            // Своей ширины на широкой колонке — с полями 16, как в
            // D-Desk; в доле строки и в прокручиваемой строке — 8.
            horizontal: small
                ? 14
                : strip
                    ? 8
                    : 16,
          ),
          decoration: BoxDecoration(
            color: small ? null : AssistantColors.raised,
            border: Border.all(color: AssistantColors.border),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              if (strip) text else Flexible(child: text),
            ],
          ),
        ),
      ),
    );
  }
}
