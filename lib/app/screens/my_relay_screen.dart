import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../shell/relay_drawer.dart';

/// Вкладки «Мой Связной».
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
TextSpan statsSpan(String stats) {
  final children = <TextSpan>[];
  var last = 0;
  for (final match in RegExp(r'\d+').allMatches(stats)) {
    if (match.start > last) {
      children.add(TextSpan(text: stats.substring(last, match.start)));
    }
    children.add(
      TextSpan(
        text: match.group(0),
        style: const TextStyle(color: AssistantColors.textStrong),
      ),
    );
    last = match.end;
  }
  if (last < stats.length) children.add(TextSpan(text: stats.substring(last)));
  return TextSpan(children: children);
}

/// «Мой Связной» (макет «Д»): шапка со знаками помощников, вкладки
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
  });

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
    // Телефон: строка статистики — своими строками под шапкой, парами
    // (D-Phone-Summary); широкий экран — рядом с названием (D-Desk-Summary).
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
      color: AssistantColors.workspace,
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
                const RelayAvatars(size: 36, ring: AssistantColors.workspace),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Semantics(
                        header: true,
                        child: Text(
                          'Мой Связной',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: phone ? 18 : 24,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: AssistantColors.textStrong,
                          ),
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
          if (stats != null && phone)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: stats,
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
    Widget line(String chunk) => Text.rich(
          statsSpan(glue(chunk)),
          style: const TextStyle(
            fontSize: 13,
            height: 1.45,
            color: AssistantColors.muted,
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

/// Вкладки «Мой Связной» — сегменты в капсуле (макет «Д»): дорожка
/// [AssistantColors.panel], выбранная — [AssistantColors.bubble], высота 44.
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
        decoration: BoxDecoration(
          color: AssistantColors.panel,
          border: Border.all(color: AssistantColors.borderSoft),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final tab in MyRelayTab.values)
              _segment(tab, active: tab == selected),
          ],
        ),
      ),
    );
  }

  Widget _segment(MyRelayTab tab, {required bool active}) {
    return Semantics(
      button: true,
      selected: active,
      label: tab.title,
      onTap: () => onSelected(tab),
      excludeSemantics: true,
      child: InkWell(
        key: Key('my-relay-tab-${tab.name}'),
        onTap: () => onSelected(tab),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: phone ? 10 : 18),
          decoration: BoxDecoration(
            color: active ? AssistantColors.bubble : null,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            tab.title,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              color:
                  active ? AssistantColors.textStrong : AssistantColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
