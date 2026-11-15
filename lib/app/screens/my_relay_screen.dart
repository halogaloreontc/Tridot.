import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../shell/relay_drawer.dart';
import '../shell/session_files_panel.dart' show metaLines;

/// Вкладки «Мой Связной».
enum MyRelayTab { summary, assistants, settings }

extension MyRelayTabInfo on MyRelayTab {
  String get title => switch (this) {
        MyRelayTab.summary => 'Сводка',
        MyRelayTab.assistants => 'Помощники',
        MyRelayTab.settings => 'Настройки',
      };
}

/// Строка статистики: числа ярче подписей, как в макете.
TextSpan statsSpan(String stats, AppPalette colors) {
  final children = <TextSpan>[];
  var last = 0;
  for (final match in RegExp(r'\d+').allMatches(stats)) {
    if (match.start > last) {
      children.add(TextSpan(text: stats.substring(last, match.start)));
    }
    children.add(
      TextSpan(
        text: match.group(0),
        style: TextStyle(color: colors.textStrong),
      ),
    );
    last = match.end;
  }
  if (last < stats.length) children.add(TextSpan(text: stats.substring(last)));
  return TextSpan(children: children);
}

/// «Мой Связной» (макет «Д»): шапка со знаками помощников, вкладки
/// «Сводка» (с активностью и выполненными), «Помощники», «Настройки». Раздел внутри
/// оболочки, а не отдельный маршрут: на широком экране рядом остаётся
/// меню.
final class MyRelayScreen extends StatefulWidget {
  const MyRelayScreen({
    super.key,
    required this.tab,
    required this.onTabChanged,
    required this.summary,
    required this.assistants,
    required this.settings,
    this.onBack,
    this.stats,
    this.assistantsShown,
  });

  /// Активные помощники для знаков в шапке; `null` — по текущему составу.
  final List<Persona>? assistantsShown;

  final MyRelayTab tab;
  final ValueChanged<MyRelayTab> onTabChanged;
  final Widget summary;
  final Widget assistants;
  final Widget settings;

  /// «Назад» к сессии (телефон); `null` — без кнопки.
  final VoidCallback? onBack;

  /// Строка статистики под названием; `null` — без неё.
  final String? stats;

  @override
  State<MyRelayScreen> createState() => _MyRelayScreenState();
}

final class _MyRelayScreenState extends State<MyRelayScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: MyRelayTab.values.length,
    vsync: this,
    initialIndex: widget.tab.index,
  )..addListener(_onTab);

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    final tab = MyRelayTab.values[_tabs.index];
    if (tab != widget.tab) widget.onTabChanged(tab);
  }

  @override
  void didUpdateWidget(MyRelayScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab.index != _tabs.index) _tabs.index = widget.tab.index;
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Телефон: строка статистики — своими строками парами в начале
    // «Сводки» (D-Phone-Summary, ADR-027); широкий экран — рядом с
    // названием (D-Desk-Summary).
    final phone = MediaQuery.sizeOf(context).width < 600;
    final stats = widget.stats == null
        ? null
        : RelayStatsLine(
            key: const Key('my-relay-stats'),
            stats: widget.stats!,
            pairs: phone,
          );
    return Material(
      key: const Key('my-relay'),
      // Сгруппированный экран — на фоне, панели — листом (ADR-027).
      color: context.colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 16, 8),
            child: Row(
              children: <Widget>[
                if (widget.onBack != null)
                  IconButton(
                    key: const Key('my-relay-back'),
                    tooltip: 'Назад к сессии',
                    onPressed: widget.onBack,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                    ),
                    icon: const Icon(Icons.chevron_left, size: 22),
                  )
                else
                  const SizedBox(width: 10),
                const SizedBox(width: 4),
                RelayAvatars(
                  personas: widget.assistantsShown,
                  size: 36,
                  ring: context.colors.background,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Semantics(
                        header: true,
                        child: Text.rich(
                          TextSpan(
                            text: AppInfo.hubName,
                            style: TextStyle(
                              // Крупный шрифт на телефоне — мельче, чтобы
                              // «Связной» не рвался.
                              fontSize: phone
                                  ? (MediaQuery.textScalerOf(context).scale(1) >
                                          1.3
                                      ? 18
                                      : 26)
                                  : 30,
                              height: 1.2,
                              letterSpacing: -0.4,
                              fontWeight: FontWeight.w700,
                              color: context.colors.textStrong,
                            ),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          // Заголовок и так крупный: на телефоне растёт не
                          // больше чем в 1,6 раза, и «Связной» при шрифте
                          // ×2 на 320 помещается целиком, без «…».
                          textScaler: phone
                              ? MediaQuery.textScalerOf(context)
                                  .clamp(maxScaleFactor: 1.6)
                              : null,
                        ),
                      ),
                      if (stats != null && !phone) ...<Widget>[
                        const SizedBox(height: 4),
                        stats,
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          _Segments(
            selected: widget.tab,
            phone: phone,
            onSelected: (MyRelayTab tab) => _tabs.animateTo(tab.index),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              // Телефон: вкладки переключают сегменты, а свайп вправо с
              // любой вкладки открывает меню (как в сессии) — а не
              // листает на предыдущую.
              physics: phone ? const NeverScrollableScrollPhysics() : null,
              children: <Widget>[
                // Телефон: статистика — только в «Сводке», над её
                // содержимым, а не закреплена над всеми вкладками: там
                // она лишь отнимала высоту у списков.
                if (stats != null && phone)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: stats,
                      ),
                      Expanded(child: widget.summary),
                    ],
                  )
                else
                  widget.summary,
                widget.assistants,
                widget.settings,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка статистики «Мой Связной»: числа ярче подписей. [pairs] —
/// телефон: по две фразы в строке, фраза и пара не разрываются, пока
/// помещаются; иначе фразы переносятся целиком, как в D-Desk-Summary.
/// Диктор читает фразы через запятую.
final class RelayStatsLine extends StatelessWidget {
  const RelayStatsLine({super.key, required this.stats, this.pairs = false});

  /// «Вместе 28 дней · сессий 180 · задач закрыто 64 · серия 5 дней».
  final String stats;
  final bool pairs;

  static const String separator = ' · ';

  /// Части строки: пары фраз ([pairs]) или фразы с «·» на конце.
  static List<String> chunks(String stats, {required bool pairs}) {
    final phrases = stats.split(separator);
    if (!pairs) {
      return <String>[
        for (final (i, phrase) in phrases.indexed)
          i < phrases.length - 1 ? '$phrase ·' : phrase,
      ];
    }
    return <String>[
      for (var i = 0; i < phrases.length; i += 2)
        phrases.skip(i).take(2).join(separator),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Внутри фразы — неразрывные пробелы: строка переносится между
    // фразами, а не посреди «задач закрыто».
    String glue(String chunk) => chunk.replaceAll(' ', '\u00A0').replaceAll(
          '\u00A0·\u00A0',
          '\u00A0· ',
        );
    final style = TextStyle(
      fontSize: 15,
      height: 1.45,
      color: context.colors.muted,
    );
    Widget line(String chunk) => Text.rich(
          statsSpan(glue(chunk), context.colors),
          style: style,
        );
    // Пара не входит (узкий экран, крупный шрифт) — фразы на своих
    // строках и без «·»: строка не кончается голой точкой (metaLines).
    Widget pair(String chunk) => LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) => Text.rich(
            statsSpan(
              metaLines(
                glue(chunk),
                DefaultTextStyle.of(context).style.merge(style),
                MediaQuery.textScalerOf(context),
                box.maxWidth,
              ),
              context.colors,
            ),
            style: style,
          ),
        );
    final parts = chunks(stats, pairs: pairs);
    return Semantics(
      label: stats.replaceAll(separator, ', '),
      excludeSemantics: true,
      child: pairs
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[for (final chunk in parts) pair(chunk)],
            )
          : Wrap(
              spacing: 6,
              children: <Widget>[for (final chunk in parts) line(chunk)],
            ),
    );
  }
}

/// Вкладки «Мой Связной» — сегменты в капсуле (макет «Д»): дорожка
/// `raised` в тёмной теме и `bubble` в светлой, выбранный сегмент — на
/// уровень светлее поверх неё (`bubble` / `workspace`), высота 44.
/// Помещаются — делят ширину строки между собой, и ни одна вкладка не
/// уходит за край. Не помещаются (узкий экран, крупный шрифт) —
/// прокручиваются с отступом 16 по краям.
final class _Segments extends StatelessWidget {
  const _Segments({
    required this.selected,
    required this.phone,
    required this.onSelected,
  });

  final MyRelayTab selected;
  final bool phone;
  final ValueChanged<MyRelayTab> onSelected;

  static const EdgeInsets _outer = EdgeInsets.fromLTRB(16, 6, 16, 2);

  /// Отступ подписи внутри сегмента, когда вкладки прокручиваются.
  double get _pad => phone ? 10 : 18;

  /// Наименьший отступ, с которым вкладки ещё делят ширину строки: на
  /// телефоне 390 все три так помещаются целиком и с крупным шрифтом.
  double get _minPad => phone ? 10 : 18;

  TextStyle _style(BuildContext context, {required bool active}) => TextStyle(
        fontSize: 15,
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        color: active ? context.colors.textStrong : context.colors.text,
      );

  /// Ширины подписей, если бы каждая была выбрана (полужирная — самая
  /// широкая): выбор вкладки не сдвигает соседей.
  List<double> _widths(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    return <double>[
      for (final tab in MyRelayTab.values)
        () {
          final painter = TextPainter(
            text: TextSpan(
              text: tab.title,
              style: base.merge(_style(context, active: true)),
            ),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Сегменты заливкой без рамки: дорожка — пузырь, выбранный — лист.
    final track = BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? context.colors.raised
          : context.colors.bubble,
      borderRadius: BorderRadius.circular(AppRadius.field),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final widths = _widths(context);
        final need = widths.fold<double>(0, (double a, double b) => a + b) +
            2 * _minPad * widths.length;
        final room = constraints.maxWidth - _outer.horizontal - 4;
        if (need <= room) {
          // Помещаются: лишнее место — поровну каждому сегменту.
          final extra = (room - need) / widths.length;
          return Padding(
            key: const Key('my-relay-tabs'),
            padding: _outer,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: track,
              child: Row(
                children: <Widget>[
                  for (final (i, tab) in MyRelayTab.values.indexed)
                    SizedBox(
                      width: widths[i] + 2 * _minPad + extra,
                      child: _segment(
                        context,
                        tab,
                        active: tab == selected,
                        pad: _minPad,
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        // Прокрутка: края полосы гаснут на ширине поля (16), поэтому
        // сегмент у края не обрезан ножом, а уходит в фон; в начале и в
        // конце прокрутки поле пустое и гаснуть нечему.
        return ShaderMask(
          shaderCallback: (Rect bounds) {
            final edge = bounds.width <= 0 ? 0.0 : _outer.left / bounds.width;
            return LinearGradient(
              // Маска, а не цвет: важна только непрозрачность.
              colors: const <Color>[
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: <double>[0, edge, 1 - edge, 1],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: _scrolling(context, track),
        );
      },
    );
  }

  Widget _scrolling(BuildContext context, BoxDecoration track) =>
      SingleChildScrollView(
        key: const Key('my-relay-tabs'),
        scrollDirection: Axis.horizontal,
        padding: _outer,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: track,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final tab in MyRelayTab.values)
                _segment(
                  context,
                  tab,
                  active: tab == selected,
                  pad: _pad,
                  reveal: true,
                ),
            ],
          ),
        ),
      );

  Widget _segment(
    BuildContext context,
    MyRelayTab tab, {
    required bool active,
    required double pad,
    bool reveal = false,
  }) {
    // Прокрутка ([reveal]): выбранный сегмент выезжает к середине полосы,
    // а у краёв прокрутка упирается в поле 16 — сегмент не остаётся
    // наполовину за краем.
    return Builder(
      builder: (BuildContext segment) =>
          _segmentBody(segment, tab, active: active, pad: pad, reveal: reveal),
    );
  }

  Widget _segmentBody(
    BuildContext context,
    MyRelayTab tab, {
    required bool active,
    required double pad,
    required bool reveal,
  }) {
    void select() => onSelected(tab);

    final body = Semantics(
      button: true,
      selected: active,
      label: tab.title,
      onTap: select,
      excludeSemantics: true,
      child: InkWell(
        key: Key('my-relay-tab-${tab.name}'),
        onTap: select,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: pad),
          decoration: BoxDecoration(
            // Выбранный — на уровень светлее дорожки в обеих темах.
            color: active
                ? (Theme.of(context).brightness == Brightness.dark
                    ? context.colors.bubble
                    : context.colors.workspace)
                : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            tab.title,
            maxLines: 1,
            softWrap: false,
            style: _style(context, active: active),
          ),
        ),
      ),
    );
    return reveal ? _RevealWhenActive(active: active, child: body) : body;
  }
}

/// Сегмент прокручиваемой полосы: стал выбранным — касанием или из кода
/// («Настройки → Помощники и роли» открывает «Помощники») — и выезжает к
/// середине полосы, а не остаётся под краем.
final class _RevealWhenActive extends StatefulWidget {
  const _RevealWhenActive({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_RevealWhenActive> createState() => _RevealWhenActiveState();
}

final class _RevealWhenActiveState extends State<_RevealWhenActive> {
  @override
  void initState() {
    super.initState();
    if (widget.active) _reveal(animate: false);
  }

  @override
  void didUpdateWidget(_RevealWhenActive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reveal(animate: true);
  }

  void _reveal({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: animate ? const Duration(milliseconds: 200) : Duration.zero,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
