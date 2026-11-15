import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'history_rail.dart';
import 'whole_word_text.dart';

/// Ответ [showHistoryDrum], когда нажали «Весь список»: вызывающий
/// открывает шторку «История команд».
const int historyDrumShowAll = -1;

/// «Барабан» хроники на телефоне: компактное окошко вырастает из кнопки
/// полос ([anchor] — её прямоугольник на экране), внутри — те же команды
/// карточками по кругу; листаются свайпом в стороны.
///
/// Нажатие на карточку по центру — переход к команде (её номер в сессии),
/// на боковую — она встаёт в центр. «Весь список» — [historyDrumShowAll].
/// Нажатие мимо, «Назад», Esc и свайп вниз закрывают окошко (`null`).
Future<int?> showHistoryDrum(
  BuildContext context, {
  required List<HistoryEntry> entries,
  required Rect anchor,
  int? activeIndex,
  bool reduceMotion = false,
}) {
  final still = reduceMotion || MediaQuery.of(context).disableAnimations;
  return Navigator.of(context).push<int>(
    _HistoryDrumRoute(
      entries: entries,
      anchor: anchor,
      activeIndex: activeIndex,
      still: still,
      scrim: context.colors.scrimLight,
    ),
  );
}

final class _HistoryDrumRoute extends PopupRoute<int> {
  _HistoryDrumRoute({
    required this.entries,
    required this.anchor,
    required this.activeIndex,
    required this.still,
    required this.scrim,
  });

  final List<HistoryEntry> entries;
  final Rect anchor;
  final int? activeIndex;

  /// Без движения: окошко просто появляется.
  final bool still;
  final Color scrim;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Закрыть историю команд';

  @override
  Color get barrierColor => scrim;

  @override
  Duration get transitionDuration =>
      still ? Duration.zero : const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration =>
      still ? Duration.zero : const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _DrumPopup(
      entries: entries,
      anchor: anchor,
      activeIndex: activeIndex,
      still: still,
      animation: animation,
    );
  }
}

/// Окошко целиком: подложка, которая растёт из кнопки, и [HistoryDrum].
final class _DrumPopup extends StatefulWidget {
  const _DrumPopup({
    required this.entries,
    required this.anchor,
    required this.activeIndex,
    required this.still,
    required this.animation,
  });

  final List<HistoryEntry> entries;
  final Rect anchor;
  final int? activeIndex;
  final bool still;
  final Animation<double> animation;

  @override
  State<_DrumPopup> createState() => _DrumPopupState();
}

final class _DrumPopupState extends State<_DrumPopup>
    with SingleTickerProviderStateMixin {
  /// Сдвиг вниз пальцем (свайп вниз закрывает окошко).
  late final AnimationController _drag = AnimationController(
    vsync: this,
    lowerBound: 0,
    upperBound: double.infinity,
    value: 0,
  );

  late final CurvedAnimation _t = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  static const double _gutter = 16;
  static const double _closeDistance = 64;
  static const double _closeVelocity = 700;

  @override
  void dispose() {
    _t.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _drag.value = math.max(0, _drag.value + details.delta.dy);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_drag.value > _closeDistance || velocity > _closeVelocity) {
      Navigator.of(context).maybePop();
      return;
    }
    if (widget.still) {
      _drag.value = 0;
    } else {
      unawaited(
        _drag.animateTo(
          0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final anchor = widget.anchor;
    final width = math.min(screen.width - 2 * _gutter, 400.0);
    final double left = (anchor.center.dx - width / 2)
        .clamp(_gutter, math.max(_gutter, screen.width - _gutter - width))
        .toDouble();
    final available = screen.height -
        anchor.top -
        media.viewPadding.bottom -
        media.viewInsets.bottom -
        _gutter;
    final layout = HistoryDrumLayout.measure(
      context,
      width: width,
      maxHeight: available,
      count: widget.entries.length,
    );
    final target = Rect.fromLTWH(left, anchor.top, width, layout.height);
    final light = colors.brightness == Brightness.light;
    final popover = light ? colors.workspace : colors.raised;
    final content = HistoryDrum(
      entries: widget.entries,
      activeIndex: widget.activeIndex,
      layout: layout,
      reduceMotion: widget.still,
      onPick: (int index) => Navigator.of(context).pop(index),
      onShowAll: () => Navigator.of(context).pop(historyDrumShowAll),
    );
    return Semantics(
      // Имя окошку даёт заголовок «История команд» (namesRoute у него).
      scopesRoute: true,
      explicitChildNodes: true,
      // Material — для стиля текста и подсказок кнопок внутри окошка.
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: <Widget>[
            AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[_t, _drag]),
              child: content,
              builder: (BuildContext context, Widget? child) {
                final t = _t.value;
                final rect = Rect.lerp(anchor, target, t)!;
                final radius = lerpDouble(
                  HistoryRail.height / 2,
                  AppRadius.sheet,
                  t,
                )!;
                final reverse =
                    widget.animation.status == AnimationStatus.reverse;
                // Открытие: содержимое не обрезается растущим краем, а
                // сжато до его ширины (иначе виден обрубок «ория команд»), и
                // проявляется во второй половине.
                final fade = reverse
                    ? const Interval(0, .6).transform(t)
                    : const Interval(.5, 1).transform(t);
                final scale = target.width <= 0
                    ? 1.0
                    : (rect.width / target.width).clamp(0.0, 1.0);
                final dy = _drag.value;
                return Positioned.fromRect(
                  rect: rect.shift(Offset(0, dy)),
                  child: Opacity(
                    opacity: (1 - dy / 160).clamp(0.0, 1.0),
                    child: GestureDetector(
                      key: const Key('history-drum-popup'),
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: _onDragUpdate,
                      onVerticalDragEnd: _onDragEnd,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color.lerp(colors.raised, popover, t),
                          borderRadius: BorderRadius.circular(radius),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: colors.shadow
                                  .withValues(alpha: colors.shadow.a * t),
                              blurRadius: 24 * t,
                              offset: Offset(0, 8 * t),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minWidth: target.width,
                            maxWidth: target.width,
                            minHeight: target.height,
                            maxHeight: target.height,
                            child: Opacity(
                              opacity: fade,
                              child: Transform.scale(
                                scale: scale,
                                alignment: Alignment.topCenter,
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Размеры окошка «барабана» при текущем шрифте и его масштабе.
final class HistoryDrumLayout {
  const HistoryDrumLayout({
    required this.cardHeight,
    this.commandLines = 2,
    required this.resultLines,
    required this.hint,
    required this.viewportFraction,
  });

  /// Высота карточки (у [PageView] она одна на всех).
  final double cardHeight;

  /// Сколько строк команды видно на карточке: 3, когда ответа не видно.
  final int commandLines;

  /// Сколько строк ответа видно на карточке (0 — ответ только для диктора).
  final int resultLines;

  /// Подпись «Нажмите, чтобы перейти» на карточке по центру.
  final bool hint;

  /// Доля ширины окошка под карточку; остальное — соседи по краям.
  final double viewportFraction;

  static const double headerHeight = 48;
  static const double stripHeight = 28;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(4, 4, 4, 12);

  /// Полная высота окошка.
  double get height =>
      padding.vertical + headerHeight + cardHeight + 8 + stripHeight;

  /// Карточка и окошко для ширины [width]; не выше [maxHeight].
  static HistoryDrumLayout measure(
    BuildContext context, {
    required double width,
    required double maxHeight,
    required int count,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final factor = scaler.scale(100) / 100;
    double line(double size, double height) => scaler.scale(size) * height;
    var resultLines = factor <= 1.3
        ? 2
        : factor <= 1.7
            ? 1
            : 0;
    var hint = true;
    var commandLines = 2;
    double card() =>
        24 + // поля 12 сверху и снизу
        line(13, 1.38) + // время и номер
        4 +
        commandLines * line(17, 1.45) + // команда
        (resultLines > 0 ? 2 + resultLines * line(15, 1.4) : 0) +
        (hint ? 6 + line(13, 1.38) : 0) +
        2; // запас на округление строк
    final room = maxHeight - padding.vertical - headerHeight - 8 - stripHeight;
    if (card() > room) hint = false;
    while (card() > room && resultLines > 0) {
      resultLines--;
    }
    // Ответа не видно — команде третья строка, если она входит: крупным
    // шрифтом «разбуди меня в пятницу в 7» тогда не обрывается.
    if (resultLines == 0) {
      commandLines = 3;
      if (card() > room) commandLines = 2;
    }
    // Уже, чем окошко: от соседей виден повёрнутый край карточки.
    final fraction = factor >= 1.5 || width < 300 ? .8 : .72;
    return HistoryDrumLayout(
      cardHeight: math.max(60, math.min(card(), room)),
      commandLines: commandLines,
      resultLines: resultLines,
      hint: hint,
      viewportFraction: fraction,
    );
  }
}

/// Содержимое окошка: заголовок со счётчиком и «Весь список», карточки
/// команд «барабаном» и под ними — полосы хроники с отмеченной текущей.
final class HistoryDrum extends StatefulWidget {
  const HistoryDrum({
    super.key,
    required this.entries,
    required this.layout,
    required this.onPick,
    required this.onShowAll,
    this.activeIndex,
    this.reduceMotion = false,
  });

  /// Команды от старой к новой; номер — порядок в сессии.
  final List<HistoryEntry> entries;
  final HistoryDrumLayout layout;

  /// Нажали на карточку по центру (или Enter).
  final ValueChanged<int> onPick;
  final VoidCallback onShowAll;

  /// С какой команды начать; `null` — с последней.
  final int? activeIndex;
  final bool reduceMotion;

  @override
  State<HistoryDrum> createState() => _HistoryDrumState();
}

final class _HistoryDrumState extends State<HistoryDrum> {
  late int _page = (widget.activeIndex ?? widget.entries.length - 1)
      .clamp(0, math.max(0, widget.entries.length - 1));
  late final PageController _controller = PageController(
    initialPage: _page,
    viewportFraction: widget.layout.viewportFraction,
  );

  int get _count => widget.entries.length;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    unawaited(HapticFeedback.selectionClick());
    setState(() => _page = page);
    final view = View.maybeOf(context);
    if (view != null) {
      unawaited(
        SemanticsService.sendAnnouncement(
          view,
          '${page + 1} из $_count',
          Directionality.of(context),
        ),
      );
    }
  }

  void _go(int page) {
    if (_count == 0) return;
    final target = page.clamp(0, _count - 1);
    if (!_controller.hasClients) return;
    if (widget.reduceMotion || MediaQuery.of(context).disableAnimations) {
      _controller.jumpToPage(target);
    } else {
      unawaited(
        _controller.animateToPage(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _tap(int index) {
    if (index == _page) {
      widget.onPick(index);
    } else {
      _go(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final layout = widget.layout;
    final header = SizedBox(
      height: HistoryDrumLayout.headerHeight,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 12),
          // Заголовок и счётчик рядом, кнопка списка — у правого края.
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  // Заголовок в строке высотой с палец: растёт не больше чем в
                  // полтора раза, чтобы уместиться целиком рядом с кнопкой.
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.5,
                    child: Semantics(
                      container: true,
                      header: true,
                      namesRoute: true,
                      child: WholeWordText(
                        'История команд',
                        maxLines: 1,
                        style: text.titleMedium!
                            .copyWith(color: colors.textStrong),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Крупным шрифтом счётчику рядом с заголовком места нет; номер
                // всё равно есть на каждой карточке.
                if (MediaQuery.textScalerOf(context).scale(100) <= 130)
                  ExcludeSemantics(
                    child: Text(
                      '${_page + 1} из $_count',
                      key: const Key('history-drum-count'),
                      maxLines: 1,
                      textScaler: MediaQuery.textScalerOf(context).clamp(
                        maxScaleFactor: 1.3,
                      ),
                      style: metaNumStyle(context),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('history-drum-all'),
            tooltip: 'Весь список',
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            onPressed: widget.onShowAll,
            icon: Icon(
              Icons.format_list_bulleted,
              size: 20,
              color: colors.icon,
            ),
          ),
        ],
      ),
    );
    final drum = SizedBox(
      height: layout.cardHeight + 8,
      child: Semantics(
        container: true,
        label: 'Команды сессии',
        value: '${_page + 1} из $_count',
        increasedValue: _page + 1 < _count ? '${_page + 2} из $_count' : null,
        decreasedValue: _page > 0 ? '$_page из $_count' : null,
        onIncrease: _page + 1 < _count ? () => _go(_page + 1) : null,
        onDecrease: _page > 0 ? () => _go(_page - 1) : null,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          // Маска прозрачности: важна только альфа, цвет не виден.
          shaderCallback: (Rect bounds) => LinearGradient(
            colors: <Color>[
              Colors.black.withValues(alpha: 0),
              Colors.black,
              Colors.black,
              Colors.black.withValues(alpha: 0),
            ],
            stops: const <double>[0, .04, .96, 1],
          ).createShader(bounds),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.mouse,
              },
            ),
            child: PageView.builder(
              key: const Key('history-drum'),
              controller: _controller,
              physics: const PageScrollPhysics(),
              onPageChanged: _onPageChanged,
              itemCount: _count,
              itemBuilder: (BuildContext context, int index) => _DrumItem(
                key: Key('history-drum-item-$index'),
                controller: _controller,
                index: index,
                initialPage: _page,
                count: _count,
                entry: widget.entries[index],
                layout: layout,
                centered: index == _page,
                onTap: () => _tap(index),
              ),
            ),
          ),
        ),
      ),
    );
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _go(_page - 1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _go(_page + 1),
          const SingleActivator(LogicalKeyboardKey.home): () => _go(0),
          const SingleActivator(LogicalKeyboardKey.end): () => _go(_count - 1),
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              widget.onPick(_page),
          const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
              widget.onPick(_page),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              widget.onPick(_page),
        },
        child: Focus(
          autofocus: true,
          child: Padding(
            padding: HistoryDrumLayout.padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                header,
                drum,
                SizedBox(
                  height: HistoryDrumLayout.stripHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: _DrumStrip(count: _count, page: _page),
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

/// Карточка на своём месте «барабана»: поворот, уменьшение и тише к краям.
final class _DrumItem extends StatelessWidget {
  const _DrumItem({
    super.key,
    required this.controller,
    required this.index,
    required this.initialPage,
    required this.count,
    required this.entry,
    required this.layout,
    required this.centered,
    required this.onTap,
  });

  final PageController controller;
  final int index;
  final int initialPage;
  final int count;
  final HistoryEntry entry;
  final HistoryDrumLayout layout;
  final bool centered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final result = entry.result;
    // Нажатие для диктора — только у карточки по центру: от соседей видна
    // лишь узкая полоска, меньше цели пальца. Листают диктором стрелками
    // «Команды сессии» (увеличить / уменьшить).
    return Semantics(
      button: centered,
      excludeSemantics: true,
      label: 'Команда ${index + 1} из $count: ${entry.command}, '
          '${entry.timestamp}${result != null ? '. $result' : ''}',
      hint: centered ? 'Перейти к сообщению' : null,
      onTap: centered ? onTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? _) {
            final page =
                controller.hasClients && controller.position.haveDimensions
                    ? controller.page ?? initialPage.toDouble()
                    : initialPage.toDouble();
            final d = (page - index).clamp(-2.0, 2.0);
            final k = 1 - .08 * d.abs();
            // Соседи чуть ближе к центру: иначе после уменьшения и
            // поворота от них остаётся лишь край под затуханием.
            final width =
                controller.hasClients && controller.position.haveDimensions
                    ? controller.position.viewportDimension *
                        controller.viewportFraction
                    : 0.0;
            final shift = d * width * .04;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, .0012)
                ..translateByDouble(shift, 0, 0, 1)
                ..rotateY(d * .62)
                ..scaleByDouble(k, k, 1, 1),
              child: Opacity(
                opacity: (1 - .3 * d.abs()).clamp(.4, 1.0),
                child: _DrumCard(
                  entry: entry,
                  index: index,
                  count: count,
                  layout: layout,
                  distance: d.abs().clamp(0.0, 1.0),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _DrumCard extends StatelessWidget {
  const _DrumCard({
    required this.entry,
    required this.index,
    required this.count,
    required this.layout,
    required this.distance,
  });

  final HistoryEntry entry;
  final int index;
  final int count;
  final HistoryDrumLayout layout;

  /// 0 — по центру, 1 — на соседнем месте и дальше.
  final double distance;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final light = colors.brightness == Brightness.light;
    final popover = light ? colors.workspace : colors.raised;
    final center = light ? colors.raised : colors.fieldOnRaised;
    // Соседи — той же заливкой, что центр (а не почти цветом окошка): видна
    // форма карточки; текст у них гаснет, чтобы не торчали обрывки слов.
    final side = light
        ? Color.lerp(center, colors.textStrong, .05)!
        : Color.lerp(center, popover, .2)!;
    final words = (1 - 2.2 * distance).clamp(0.0, 1.0);
    final newest = index == count - 1;
    final result = entry.result;
    final textColor = Color.lerp(colors.textStrong, colors.text, distance)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.lerp(center, side, distance),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: SizedBox(
          height: layout.cardHeight,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              OverflowBox(
                alignment: Alignment.topLeft,
                minHeight: 0,
                maxHeight: double.infinity,
                child: Opacity(
                  opacity: words,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            // Последняя команда — точкой цвета успеха, как её
                            // полоса в хронике (рамок у поверхностей нет, S3).
                            if (newest)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: SizedBox.square(
                                  dimension: 6,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.success,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                            Flexible(
                              child: WholeWordText(
                                '${entry.timestamp} · ${index + 1} из $count',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: metaNumStyle(context),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        _WordEllipsis(
                          entry.command,
                          maxLines: layout.commandLines,
                          style: text.bodyLarge!.copyWith(color: textColor),
                        ),
                        if (result != null && layout.resultLines > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: _WordEllipsis(
                              result,
                              maxLines: layout.resultLines,
                              style: text.bodyMedium!
                                  .copyWith(color: colors.muted),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Подсказка — у нижнего края карточки по центру; место под неё
              // уже в высоте карточки ([HistoryDrumLayout.measure]).
              if (layout.hint)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Opacity(
                    opacity: words,
                    child: WholeWordText(
                      'Нажмите, чтобы перейти',
                      maxLines: 1,
                      style: text.bodySmall!.copyWith(color: colors.muted),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Текст не длиннее [maxLines] строк; не входит — обрезан по границе слова
/// с «…» («разбуди меня в…», а не «разбуди меня в пя…»).
final class _WordEllipsis extends StatelessWidget {
  const _WordEllipsis(this.text, {required this.maxLines, required this.style});

  final String text;
  final int maxLines;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Однобуквенное слово не висит в конце строки: «в 7» — вместе.
        final glued = text.replaceAllMapped(
          RegExp(r'(^|\s)(\S) '),
          (Match m) => '${m[1]}${m[2]}\u00a0',
        );
        final shown = fitWords(
          glued,
          style: style,
          maxWidth: constraints.maxWidth,
          maxLines: maxLines,
          scaler: scaler,
          direction: direction,
        );
        return WholeWordText(
          shown,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}

/// Самое длинное начало [text] целыми словами (с «…», если обрезано),
/// которое помещается в [maxLines] строк шириной [maxWidth].
@visibleForTesting
String fitWords(
  String text, {
  required TextStyle style,
  required double maxWidth,
  required int maxLines,
  TextScaler scaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0) return text;
  bool fits(String candidate) {
    final painter = TextPainter(
      text: TextSpan(text: candidate, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);
    final ok = !painter.didExceedMaxLines;
    painter.dispose();
    return ok;
  }

  if (fits(text)) return text;
  final words = text.split(' ');
  var low = 1;
  var high = words.length - 1;
  var best = 0;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    final head =
        words.take(mid).join(' ').replaceFirst(RegExp(r'[ .,;:!?…—–-]+$'), '');
    if (fits('$head…')) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  // Даже первое слово не входит — пусть режет сам [Text].
  if (best == 0) return text;
  // «сутки.…» — без знака перед многоточием.
  final head =
      words.take(best).join(' ').replaceFirst(RegExp(r'[ .,;:!?…—–-]+$'), '');
  return '$head…';
}

/// Полосы хроники под «барабаном»: та же строка, что в кнопке, текущая
/// команда отмечена. Только украшение — без нажатий и без диктора.
final class _DrumStrip extends StatelessWidget {
  const _DrumStrip({required this.count, required this.page});

  final int count;
  final int page;

  static const double _step = 9;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final fit = math.max(1, (constraints.maxWidth / _step).floor() - 2);
          var first = 0;
          var last = count;
          if (count > fit) {
            first = (page - fit ~/ 2).clamp(0, count - fit);
            last = first + fit;
          }
          return SizedBox(
            height: 20,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var i = first; i < last; i++)
                  SizedBox(
                    width: _step,
                    child: Center(
                      child: Builder(
                        builder: (BuildContext context) {
                          final (height, color) = historyMarkLook(
                            context,
                            age: count - 1 - i,
                            active: i == page,
                          );
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 3,
                            height: height,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
