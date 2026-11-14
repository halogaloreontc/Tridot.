import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../assistant_theme.dart';

/// Одна команда пользователя в хронике разговора.
final class HistoryEntry {
  const HistoryEntry({
    required this.command,
    required this.timestamp,
    this.result,
  });

  final String command;
  final String timestamp;

  /// Ответ помощника на эту команду, если он уже есть.
  final String? result;
}

/// Хроника команд: строка коротких вертикальных полос поверх ленты сверху
/// по центру, под шапкой ([HistoryRailPill]). Ширину колонки чата и поля
/// ввода она не занимает.
///
/// Полосы «живые»: старые короче и тусклее, свежие длиннее и светлее,
/// последняя — цвета успешного кубика.
///
/// - Узко ([compact], телефон и планшет — пальцем): полосы слишком мелкие
///   для пальца, поэтому вся строка — одна кнопка не уже [minTarget],
///   которая открывает список команд («Хроника команд»).
/// - Широко (компьютер, мышь): наведение на полосу показывает карточку с
///   командой и ответом, нажатие ведёт к сообщению. Рядом — кнопка списка
///   [minTarget]×[minTarget] (`history-rail-list`): весь список, в том
///   числе команды, которым не хватило места, и цель нажатия для пальца на
///   сенсорном экране.
///
/// Команд больше, чем помещается, — видны последние, а слева от них
/// подпись «+N» (сколько не показано); нажатие на неё тоже открывает
/// список. Прокрутки нет: строка не спорит с жестом открытия меню.
final class HistoryRail extends StatelessWidget {
  const HistoryRail({
    super.key,
    required this.entries,
    required this.onSelect,
    this.activeIndex,
    this.compact = false,
    this.inPill = false,
  });

  final List<HistoryEntry> entries;
  final ValueChanged<int> onSelect;
  final int? activeIndex;

  /// Узкий экран: вся строка — одна кнопка, открывающая список команд.
  final bool compact;

  /// На подложке ([HistoryRailPill]): по центру стоит сама подложка, поэтому
  /// пустое место слева под симметрию с кнопкой списка не нужно.
  final bool inPill;

  /// Высота строки — она же высота цели нажатия.
  static const double height = 44;

  /// Отступ подложки хроники от шапки.
  static const double overlayTop = 6;

  /// Промежуток между подложкой и первым сообщением.
  static const double overlayGap = 6;

  /// Отступ ленты и документа сверху, пока хроника видна: под ней ничего
  /// не прячется.
  static const double overlayInset = overlayTop + height + overlayGap;

  /// Наименьшая ширина и высота цели нажатия пальцем.
  static const double minTarget = 44;

  /// Наибольшая ширина строки: на телефоне и на компьютере (вместе с
  /// кнопкой списка).
  static double maxWidth({required bool compact}) => compact ? 240 : 360;

  /// Шаг полос: ширина полосы и промежуток.
  static double step({required bool compact}) => compact ? 9 : 11;

  /// Ширина подписи «+N».
  static const double _moreWidth = 36;

  String get _label => 'Хроника команд: ${entries.length}. Открыть список';

  @override
  Widget build(BuildContext context) {
    final marks = SizedBox(
      height: height,
      child: entries.isEmpty
          ? const SizedBox.shrink()
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final step = HistoryRail.step(compact: compact);
                // Место под «+N» — только если все полосы не входят.
                final all = (constraints.maxWidth / step).floor();
                final fit = entries.length <= all
                    ? entries.length
                    : ((constraints.maxWidth - _moreWidth) / step)
                        .floor()
                        .clamp(1, entries.length);
                final first = entries.length - fit;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (first > 0) _more(context, first),
                    for (var index = first; index < entries.length; index++)
                      _Mark(
                        key: Key('history-$index'),
                        entry: entries[index],
                        age: entries.length - 1 - index,
                        active: index == activeIndex,
                        compact: compact,
                        width: step,
                        onTap: compact
                            ? () => _openList(context)
                            : () => onSelect(index),
                      ),
                  ],
                );
              },
            ),
    );
    if (entries.isEmpty) {
      return ConstrainedBox(
        key: const Key('history-rail'),
        constraints: BoxConstraints(maxWidth: maxWidth(compact: compact)),
        child: marks,
      );
    }
    if (!compact) {
      return ConstrainedBox(
        key: const Key('history-rail'),
        constraints: BoxConstraints(maxWidth: maxWidth(compact: false)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Пустое место слева той же ширины, что и кнопка справа: полосы
            // остаются по центру. На подложке — только небольшой отступ.
            SizedBox(width: inPill ? 12 : minTarget),
            Flexible(child: marks),
            Tooltip(
              message: 'Хроника команд',
              child: Semantics(
                button: true,
                label: _label,
                child: InkWell(
                  key: const Key('history-rail-list'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openList(context),
                  child: const ExcludeSemantics(
                    child: SizedBox(
                      width: minTarget,
                      height: minTarget,
                      child: Icon(
                        Icons.format_list_bulleted,
                        size: 16,
                        color: AssistantColors.faint,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Semantics(
      button: true,
      label: _label,
      child: GestureDetector(
        key: const Key('history-rail-open'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _openList(context),
        child: ExcludeSemantics(
          child: ConstrainedBox(
            // Одна-две полосы — всё равно цель не уже пальца.
            constraints: const BoxConstraints(minWidth: minTarget + 4),
            child: Padding(
              // Цель нажатия шире самих полос.
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ConstrainedBox(
                key: const Key('history-rail'),
                constraints: BoxConstraints(maxWidth: maxWidth(compact: true)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[Flexible(child: marks)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Подпись «+N»: сколько старых команд не поместилось. На компьютере —
  /// кнопка списка; на телефоне нажатие и так открывает список.
  Widget _more(BuildContext context, int hidden) {
    final text = SizedBox(
      width: _moreWidth,
      height: height,
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          '+$hidden',
          key: const Key('history-more'),
          maxLines: 1,
          overflow: TextOverflow.clip,
          textAlign: TextAlign.right,
          textScaler: TextScaler.noScaling,
          style: metaTextStyle.copyWith(
            fontSize: 11,
            color: AssistantColors.faint,
          ),
        ),
      ),
    );
    if (compact) return text;
    return Semantics(
      button: true,
      label: 'Ещё $hidden команд. Открыть «Хроника команд»',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const Key('history-more-open'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _openList(context),
          child: ExcludeSemantics(child: text),
        ),
      ),
    );
  }

  Future<void> _openList(BuildContext context) async {
    final index = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AssistantColors.panel,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Хроника команд', style: TextStyle(fontSize: 16)),
            ),
            for (var i = entries.length - 1; i >= 0; i--)
              ListTile(
                key: Key('history-item-$i'),
                title: Text(entries[i].command),
                subtitle: entries[i].result == null
                    ? null
                    : Text(
                        entries[i].result!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                leading: Text(entries[i].timestamp, style: metaTextStyle),
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (index != null) onSelect(index);
  }
}

/// [HistoryRail] на полупрозрачной подложке-«таблетке» с мягкой рамкой:
/// так она читается поверх сообщений. Высота — [HistoryRail.height], цели
/// нажатия не меньше [HistoryRail.minTarget].
///
/// Подложка лежит над лентой (или документом) и забирает себе касания в
/// своём прямоугольнике. Чтобы над ней не было «мёртвой» зоны, колесо
/// мыши, жест тачпада и вертикальное перетаскивание пальцем передаются в
/// [scrollController] — ленту под ней, с той же инерцией, что у самой
/// ленты. Нажатия по полосам и кнопке списка остаются у хроники.
final class HistoryRailPill extends StatefulWidget {
  const HistoryRailPill({
    super.key,
    required this.entries,
    required this.onSelect,
    this.activeIndex,
    this.compact = false,
    this.scrollController,
  });

  final List<HistoryEntry> entries;
  final ValueChanged<int> onSelect;
  final int? activeIndex;
  final bool compact;

  /// Прокрутка того, что под подложкой; `null` — ничего не передаётся.
  final ScrollController? scrollController;

  @override
  State<HistoryRailPill> createState() => _HistoryRailPillState();
}

final class _HistoryRailPillState extends State<HistoryRailPill> {
  Drag? _drag;

  ScrollPosition? get _position {
    final controller = widget.scrollController;
    if (controller == null || controller.positions.length != 1) return null;
    return controller.position;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final position = _position;
    if (position == null) return;
    // Тот же разбор, что у Scrollable: колесо достаётся одному получателю.
    GestureBinding.instance.pointerSignalResolver.register(event,
        (PointerSignalEvent event) {
      final current = _position;
      if (current == null || event is! PointerScrollEvent) return;
      var delta = event.scrollDelta.dy;
      if (axisDirectionIsReversed(current.axisDirection)) delta = -delta;
      if (delta != 0) current.pointerScroll(delta);
    });
  }

  void _onDragStart(DragStartDetails details) {
    final position = _position;
    if (position == null) return;
    _drag = position.drag(details, () => _drag = null);
  }

  void _onDragUpdate(DragUpdateDetails details) => _drag?.update(details);

  void _onDragEnd(DragEndDetails details) {
    _drag?.end(details);
    _drag = null;
  }

  void _onDragCancel() {
    _drag?.cancel();
    _drag = null;
  }

  @override
  void didUpdateWidget(HistoryRailPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      _onDragCancel();
    }
  }

  @override
  void dispose() {
    _onDragCancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pill = DecoratedBox(
      key: const Key('history-rail-pill'),
      decoration: BoxDecoration(
        color: AssistantColors.railPill,
        border: Border.all(color: AssistantColors.borderSoft),
        borderRadius: BorderRadius.circular(HistoryRail.height / 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: HistoryRail.height,
          child: HistoryRail(
            entries: widget.entries,
            onSelect: widget.onSelect,
            activeIndex: widget.activeIndex,
            compact: widget.compact,
            inPill: true,
          ),
        ),
      ),
    );
    if (widget.scrollController == null) return pill;
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        // Перетаскивают тем же, чем саму ленту (палец, перо, тачпад; мышью
        // ленту не тянут).
        supportedDevices: ScrollConfiguration.of(context).dragDevices,
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        onVerticalDragCancel: _onDragCancel,
        child: pill,
      ),
    );
  }
}

final class _Mark extends StatefulWidget {
  const _Mark({
    super.key,
    required this.entry,
    required this.age,
    required this.active,
    required this.compact,
    required this.width,
    required this.onTap,
  });

  final HistoryEntry entry;

  /// 0 — последняя команда, дальше — старше.
  final int age;
  final bool active;
  final bool compact;

  /// Ширина ячейки полосы (полоса и промежуток).
  final double width;
  final VoidCallback onTap;

  @override
  State<_Mark> createState() => _MarkState();
}

/// Наибольшая ширина карточки при наведении: длинная команда переносится,
/// а не растягивает карточку на весь экран.
const double _cardWidth = 340;

/// Обрезает длинный текст для карточки: она — напоминание, а не сообщение.
String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1).trimRight()}…';

final class _MarkState extends State<_Mark> {
  bool _hover = false;

  /// Высота и цвет полосы по свежести команды.
  (double, Color) get _look {
    final scale = widget.compact ? .8 : 1.0;
    if (widget.active || _hover) {
      return (18 * scale, AssistantColors.textStrong);
    }
    return switch (widget.age) {
      0 => (16 * scale, AssistantColors.success),
      1 => (14 * scale, AssistantColors.muted),
      2 || 3 => (12 * scale, AssistantColors.faint),
      _ => (8 * scale, AssistantColors.border),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (height, color) = _look;
    final mark = SizedBox(
      width: widget.width,
      height: HistoryRail.height,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 3,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
    if (widget.compact) return mark;
    return Tooltip(
      key: Key('history-tip-${widget.entry.timestamp}-${widget.age}'),
      // Карточка — под хроникой, над сообщениями; поля не пускают её за
      // края окна.
      preferBelow: true,
      verticalOffset: HistoryRail.height / 2 + 4,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      constraints: const BoxConstraints(maxWidth: _cardWidth),
      waitDuration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: AssistantColors.raised,
        border: Border.all(color: AssistantColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      richMessage: TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '${widget.entry.timestamp} · команда\n',
            style: metaTextStyle,
          ),
          TextSpan(
            text: _clip(widget.entry.command, 120),
            style: const TextStyle(
              fontSize: 14,
              color: AssistantColors.textStrong,
            ),
          ),
          if (widget.entry.result != null)
            TextSpan(
              text: '\n${_clip(widget.entry.result!, 160)}',
              style: const TextStyle(fontSize: 13, color: AssistantColors.text),
            ),
          const TextSpan(
            text: '\nНажмите, чтобы перейти к сообщению',
            style: metaTextStyle,
          ),
        ],
      ),
      child: Semantics(
        button: true,
        label: 'Перейти к команде: ${widget.entry.command}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: mark,
          ),
        ),
      ),
    );
  }
}
