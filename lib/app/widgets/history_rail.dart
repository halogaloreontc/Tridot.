import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'history_drum.dart';
import 'whole_word_text.dart';

/// Одна команда пользователя в истории разговора.
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

/// «История команд» (ADR-027): шторка со списком команд сессии, от новых
/// к старым, одной сгруппированной панелью. Открывается из хроники над
/// лентой ([HistoryRailPill]) и из «⋯» в шапке.
///
/// Закрывается нажатием мимо, «Назад», свайпом вниз (как любая шторка) и
/// свайпом вверх — за шапку с ручкой, а когда списку некуда листаться, то и
/// за сам список. Свайп вверх по длинному списку листает его, а не
/// закрывает шторку.
///
/// Возвращает номер выбранной команды (по порядку в сессии) или `null`.
Future<int?> showCommandHistory(
  BuildContext context, {
  required List<HistoryEntry> entries,
  bool reduceMotion = false,
}) {
  final still = reduceMotion || MediaQuery.of(context).disableAnimations;
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    // Ручка — своя, в шапке: за неё шторку можно смахнуть и вверх.
    showDragHandle: false,
    sheetAnimationStyle: still ? AnimationStyle.noAnimation : null,
    constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
    builder: (BuildContext context) => _HistorySheet(entries: entries),
  );
}

final class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.entries});

  final List<HistoryEntry> entries;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

final class _HistorySheetState extends State<_HistorySheet> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _header = GlobalKey();

  /// Свайп вверх: сколько пройти пальцем или с какой скоростью бросить,
  /// чтобы шторка закрылась (те же пороги, что у свайпа вниз в «барабане»).
  static const double _closeDistance = 64;
  static const double _closeVelocity = 700;

  int? _pointer;
  Offset _start = Offset.zero;
  double _startOffset = 0;
  bool _eligible = false;
  VelocityTracker? _tracker;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _canScroll =>
      _scroll.hasClients && _scroll.position.maxScrollExtent > 0;

  double get _offset => _scroll.hasClients ? _scroll.offset : 0;

  bool _inHeader(Offset global) {
    final box = _header.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  // Сырые касания, а не распознаватель жестов: свайп вниз остаётся у
  // шторки, а листание — у списка; здесь только подсчёт пути вверх.
  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _start = event.position;
    _startOffset = _offset;
    _eligible = _inHeader(event.position) || !_canScroll;
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _tracker?.addPosition(event.timeStamp, event.position);
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final tracker = _tracker;
    final eligible = _eligible;
    _pointer = null;
    _tracker = null;
    if (!eligible || tracker == null) return;
    // Список сдвинулся — это было листание, а не жест закрытия.
    if ((_offset - _startOffset).abs() > .5) return;
    final delta = event.position - _start;
    if (delta.dy >= 0 || delta.dy.abs() < delta.dx.abs()) return;
    final velocity = tracker.getVelocity().pixelsPerSecond.dy;
    final far = -delta.dy > _closeDistance;
    final fast = -delta.dy > kTouchSlop && velocity < -_closeVelocity;
    if (far || fast) Navigator.of(context).maybePop();
  }

  void _cancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _tracker = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final entries = widget.entries;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Listener(
          key: const Key('history-sheet-swipe'),
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _cancel,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Шапка не листается: за неё (и за ручку) шторку смахивают вниз
              // и вверх.
              Column(
                key: _header,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _SheetHandle(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.insetH + 4,
                      0,
                      AppSpace.insetH + 4,
                      AppSpace.s,
                    ),
                    child: Semantics(
                      header: true,
                      child: WholeWordText(
                        'История команд',
                        style: text.titleMedium!.copyWith(
                          color: colors.textStrong,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Flexible(
                child: ListView(
                  key: const Key('history-sheet'),
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.insetH,
                    0,
                    AppSpace.insetH,
                    AppSpace.xl,
                  ),
                  children: <Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.group),
                      child: Material(
                        color: colors.workspace,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (var i = entries.length - 1;
                                i >= 0;
                                i--) ...<Widget>[
                              if (i != entries.length - 1)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(left: AppSpace.m),
                                  child: Divider(
                                    height: .5,
                                    thickness: .5,
                                    color: colors.divider,
                                  ),
                                ),
                              _HistoryRow(
                                key: Key('history-item-$i'),
                                entry: entries[i],
                                onTap: () => Navigator.of(context).pop(i),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.m,
                        8,
                        AppSpace.m,
                        0,
                      ),
                      child: WholeWordText(
                        'Нажмите на команду, чтобы перейти к ней в ленте',
                        style: text.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ручка шторки — как у стандартной (размер и цвет из темы, «Закрыть» для
/// диктора), но внутри шапки, чтобы свайп вверх за неё тоже закрывал.
final class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).bottomSheetTheme;
    final size = theme.dragHandleSize ?? const Size(32, 4);
    final color = WidgetStateProperty.resolveAs<Color?>(
          theme.dragHandleColor,
          const <WidgetState>{},
        ) ??
        Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: .4);
    return Semantics(
      key: const Key('history-sheet-handle'),
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      container: true,
      button: true,
      onTap: () => Navigator.of(context).maybePop(),
      child: SizedBox(
        height: kMinInteractiveDimension,
        child: Center(
          child: Container(
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(size.height / 2),
            ),
          ),
        ),
      ),
    );
  }
}

final class _HistoryRow extends StatelessWidget {
  const _HistoryRow({super.key, required this.entry, required this.onTap});

  final HistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final result = entry.result;
    return Semantics(
      button: true,
      label: 'Перейти к команде: ${entry.command}, ${entry.timestamp}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.rowMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.rowH,
              vertical: AppSpace.rowV,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      WholeWordText(
                        entry.command,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge!.copyWith(
                          color: colors.textStrong,
                        ),
                      ),
                      if (result != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: WholeWordText(
                            result,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium!.copyWith(
                              color: colors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                Text(entry.timestamp, style: metaNumStyle(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Хроника команд: строка коротких вертикальных полос своей полосой под
/// шапкой, по центру над лентой ([HistoryRailPill]). Ширину колонки чата и
/// поля ввода она не занимает; лента начинается под ней, так что ни метка
/// даты, ни сообщения при прокрутке под неё не заходят.
///
/// Полосы «живые»: старые короче и тише, свежие длиннее и контрастнее,
/// последняя — цвета успеха.
///
/// - Узко ([compact], телефон и планшет — пальцем): полосы слишком мелкие
///   для пальца, поэтому вся строка — одна кнопка не уже [minTarget].
///   Она открывает «барабан» ([showHistoryDrum]): окошко вырастает из
///   кнопки, команды листаются свайпом в стороны; из него же — «Весь
///   список» (шторка «История команд»).
/// - Широко (компьютер, мышь): наведение на полосу показывает карточку с
///   командой и ответом, нажатие ведёт к сообщению. Рядом — кнопка списка
///   (`history-rail-list`): весь список, в том числе команды, которым не
///   хватило места.
///
/// Команд больше, чем помещается, — видны последние, а слева от них
/// подпись «+N»; нажатие на неё тоже открывает список. Прокрутки нет:
/// строка не спорит с жестом открытия меню.
final class HistoryRail extends StatelessWidget {
  const HistoryRail({
    super.key,
    required this.entries,
    required this.onSelect,
    this.activeIndex,
    this.compact = false,
    this.reduceMotion = false,
  });

  final List<HistoryEntry> entries;
  final ValueChanged<int> onSelect;
  final int? activeIndex;

  /// Узкий экран: вся строка — одна кнопка, открывающая «барабан».
  final bool compact;

  /// «Меньше движения»: «барабан» появляется без анимации.
  final bool reduceMotion;

  /// Высота строки — она же высота цели нажатия.
  static const double height = AppSize.minTap;

  /// Отступ подложки хроники от шапки.
  static const double stripTop = 4;

  /// Промежуток между подложкой и лентой.
  static const double stripBottom = 4;

  /// Ниже этой высоты колонки чата полоса хроники не показывается: ей
  /// нужна высота строки, а ленте и полю ввода — остальное.
  static const double minColumnHeight = 240;

  /// Наименьшая ширина и высота цели нажатия пальцем.
  static const double minTarget = AppSize.minTap;

  /// Наибольшая ширина строки: на телефоне и на компьютере (вместе с
  /// кнопкой списка).
  static double maxWidth({required bool compact}) => compact ? 240 : 360;

  /// Шаг полос: ширина полосы и промежуток.
  static double step({required bool compact}) => compact ? 9 : 11;

  /// Ширина подписи «+N».
  static const double _moreWidth = 36;

  String get _label => 'История команд: ${entries.length}. Открыть список';

  @override
  Widget build(BuildContext context) {
    final marks = SizedBox(
      height: height,
      child: LayoutBuilder(
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
                      ? () => _openDrum(context)
                      : () => onSelect(index),
                ),
            ],
          );
        },
      ),
    );
    if (!compact) {
      return ConstrainedBox(
        key: const Key('history-rail'),
        constraints: BoxConstraints(maxWidth: maxWidth(compact: false)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(width: 12),
            Flexible(child: marks),
            Tooltip(
              message: 'История команд',
              child: Semantics(
                button: true,
                label: _label,
                child: InkWell(
                  key: const Key('history-rail-list'),
                  customBorder: const CircleBorder(),
                  onTap: () => _openList(context),
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: minTarget,
                      height: minTarget,
                      child: Icon(
                        Icons.format_list_bulleted,
                        size: 18,
                        color: context.colors.icon,
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
        onTap: () => _openDrum(context),
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
          // Подпись в строке высотой с палец: растёт не больше чем на
          // треть, чтобы «+N» не вытеснял полосы.
          textScaler: MediaQuery.textScalerOf(context).clamp(
            maxScaleFactor: 1.3,
          ),
          style: metaNumStyle(context),
        ),
      ),
    );
    if (compact) return text;
    return Semantics(
      button: true,
      label: 'Ещё $hidden команд. Открыть «История команд»',
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
    final index = await showCommandHistory(
      context,
      entries: entries,
      reduceMotion: reduceMotion,
    );
    if (index != null) onSelect(index);
  }

  /// «Барабан» из кнопки: окошко растёт из подложки-«таблетки» (или из
  /// самой строки, если подложки нет).
  Future<void> _openDrum(BuildContext context) async {
    final box = (context
            .findAncestorStateOfType<_HistoryRailPillState>()
            ?._pillKey
            .currentContext
            ?.findRenderObject() ??
        context.findRenderObject())! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    // Иначе клавиатура вернётся, когда окошко закроется (ADR-028).
    FocusManager.instance.primaryFocus?.unfocus();
    final index = await showHistoryDrum(
      context,
      entries: entries,
      anchor: anchor,
      activeIndex: activeIndex,
      reduceMotion: reduceMotion,
    );
    if (!context.mounted || index == null) return;
    if (index == historyDrumShowAll) {
      await _openList(context);
    } else {
      onSelect(index);
    }
  }
}

/// Высота и цвет полосы хроники по свежести команды: [age] 0 — последняя.
/// Общая для полос в строке и под «барабаном».
(double, Color) historyMarkLook(
  BuildContext context, {
  required int age,
  required bool active,
  double scale = 1,
}) {
  final colors = context.colors;
  if (active) return (20 * scale, colors.textStrong);
  return switch (age) {
    0 => (18 * scale, colors.success),
    1 => (15 * scale, colors.muted),
    2 || 3 => (12 * scale, colors.faint),
    _ => (9 * scale, colors.border),
  };
}

/// [HistoryRail] на подложке-«таблетке» заливкой без рамки (ADR-027).
/// Высота — [HistoryRail.height].
///
/// Подложка стоит над лентой (или документом) и забирает себе касания в
/// своём прямоугольнике. Чтобы на ней не было «мёртвой» зоны, колесо
/// мыши, жест тачпада и вертикальное перетаскивание пальцем передаются в
/// [scrollController] — ленту под ней. Нажатия по полосам и кнопке списка
/// остаются у хроники.
final class HistoryRailPill extends StatefulWidget {
  const HistoryRailPill({
    super.key,
    required this.entries,
    required this.onSelect,
    this.activeIndex,
    this.compact = false,
    this.scrollController,
    this.reduceMotion = false,
  });

  final List<HistoryEntry> entries;
  final ValueChanged<int> onSelect;
  final int? activeIndex;
  final bool compact;

  /// «Меньше движения»: «барабан» появляется без анимации.
  final bool reduceMotion;

  /// Прокрутка того, что под подложкой; `null` — ничего не передаётся.
  final ScrollController? scrollController;

  @override
  State<HistoryRailPill> createState() => _HistoryRailPillState();
}

final class _HistoryRailPillState extends State<HistoryRailPill> {
  Drag? _drag;

  /// Подложка: из неё вырастает «барабан».
  final GlobalKey _pillKey = GlobalKey();

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
        // Заливка поля ввода, без рамки (ADR-027).
        color: context.colors.raised,
        borderRadius: BorderRadius.circular(HistoryRail.height / 2),
      ),
      child: Padding(
        key: _pillKey,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: HistoryRail.height,
          child: HistoryRail(
            entries: widget.entries,
            onSelect: widget.onSelect,
            activeIndex: widget.activeIndex,
            compact: widget.compact,
            reduceMotion: widget.reduceMotion,
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
  (double, Color) _look(BuildContext context) => historyMarkLook(
        context,
        age: widget.age,
        active: widget.active || _hover,
        scale: widget.compact ? .8 : 1.0,
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (height, color) = _look(context);
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
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ),
    );
    if (widget.compact) return mark;
    final result = widget.entry.result;
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
        color: colors.workspace,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: colors.shadow,
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      richMessage: TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '${widget.entry.timestamp} · команда\n',
            style: metaStyle(context),
          ),
          TextSpan(
            text: _clip(widget.entry.command, 120),
            style: TextStyle(
              fontFamily: AppFonts.text,
              fontSize: 14,
              height: 1.35,
              color: colors.textStrong,
            ),
          ),
          if (result != null)
            TextSpan(
              text: '\n${_clip(result, 160)}',
              style: TextStyle(
                fontFamily: AppFonts.text,
                fontSize: 14,
                height: 1.35,
                color: colors.text,
              ),
            ),
          TextSpan(
            text: '\nНажмите, чтобы перейти к сообщению',
            style: metaStyle(context),
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
