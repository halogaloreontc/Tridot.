import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../shell/relay_drawer.dart';
import '../widgets/app_name_text.dart';

/// Вкладки «Мой Tridot».
enum MyRelayTab { summary, activity, assistants, settings }

extension MyRelayTabInfo on MyRelayTab {
  String get title => switch (this) {
        MyRelayTab.summary => 'Сводка',
        MyRelayTab.activity => 'Активность',
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

/// «Мой Tridot» (макет «Д»): шапка со знаками помощников, вкладки
/// «Сводка», «Активность», «Помощники», «Настройки». Раздел внутри
/// оболочки, а не отдельный маршрут: на широком экране рядом остаётся
/// меню.
final class MyRelayScreen extends StatefulWidget {
  const MyRelayScreen({
    super.key,
    required this.tab,
    required this.onTabChanged,
    required this.summary,
    required this.activity,
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
  final Widget activity;
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
                          appNameSpan(
                            AppInfo.hubName,
                            TextStyle(
                              // Крупный шрифт на телефоне — мельче, чтобы «Tridot» не рвался.
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
                widget.activity,
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

/// Строка статистики «Мой Tridot»: числа ярче подписей. [pairs] —
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
    Widget line(String chunk) => Text.rich(
          statsSpan(glue(chunk), context.colors),
          style: TextStyle(
            fontSize: 15,
            height: 1.45,
            color: context.colors.muted,
          ),
        );
    final parts = chunks(stats, pairs: pairs);
    return Semantics(
      label: stats.replaceAll(separator, ', '),
      excludeSemantics: true,
      child: pairs
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[for (final chunk in parts) line(chunk)],
            )
          : Wrap(
              spacing: 6,
              children: <Widget>[for (final chunk in parts) line(chunk)],
            ),
    );
  }
}

/// Вкладки «Мой Tridot» — сегменты в капсуле (макет «Д»): дорожка
/// `raised` в тёмной теме и `bubble` в светлой, выбранный сегмент — на
/// уровень светлее поверх неё (`bubble` / `workspace`), высота 44.
/// Не помещаются (узкий экран, крупный шрифт) — прокручиваются с отступом
/// 16 по краям.
final class _Segments extends StatelessWidget {
  const _Segments({
    required this.selected,
    required this.phone,
    required this.onSelected,
  });

  final MyRelayTab selected;
  final bool phone;
  final ValueChanged<MyRelayTab> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('my-relay-tabs'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Container(
        padding: const EdgeInsets.all(2),
        // Сегменты заливкой без рамки: дорожка — пузырь, выбранный — лист.
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? context.colors.raised
              : context.colors.bubble,
          borderRadius: BorderRadius.circular(AppRadius.field),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final tab in MyRelayTab.values)
              _segment(context, tab, active: tab == selected),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    MyRelayTab tab, {
    required bool active,
  }) {
    return Semantics(
      button: true,
      selected: active,
      label: tab.title,
      onTap: () => onSelected(tab),
      excludeSemantics: true,
      child: InkWell(
        key: Key('my-relay-tab-${tab.name}'),
        onTap: () => onSelected(tab),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: phone ? 10 : 18),
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
            style: TextStyle(
              fontSize: 15,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? context.colors.textStrong : context.colors.text,
            ),
          ),
        ),
      ),
    );
  }
}
