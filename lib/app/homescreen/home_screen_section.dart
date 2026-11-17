import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../widgets/grouped.dart';
import 'home_screen_channel.dart';

/// Группа «Виджеты» в настройках (ADR-034): показывать ли на рабочем
/// столе текст задач и добавление виджетов. Только на Android; состояние
/// читается заново, когда приложение возвращается на экран (лаунчер
/// спрашивает о добавлении сам, в своём окне).
final class HomeScreenSection extends StatefulWidget {
  const HomeScreenSection({
    super.key,
    required this.platform,
    required this.settings,
    required this.onChanged,
    this.voice = true,
  });

  final HomeScreenPlatform platform;
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  /// Голосовой ввод на устройстве есть: у виджета ввода — микрофон.
  final bool voice;

  @override
  State<HomeScreenSection> createState() => _HomeScreenSectionState();
}

final class _HomeScreenSectionState extends State<HomeScreenSection>
    with WidgetsBindingObserver {
  HomeScreenState? _state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_read());
  }

  Future<void> _read() async {
    final state = await widget.platform.state();
    if (!mounted) return;
    setState(() => _state = state);
  }

  Future<void> _pin(HomeScreenKind kind) async {
    final accepted = await widget.platform.pin(kind);
    if (!mounted || accepted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Не получилось. Добавьте виджет с рабочего стола.'),
      ),
    );
  }

  String _title(HomeScreenKind kind) => switch (kind) {
        HomeScreenKind.today => 'Сегодня',
        HomeScreenKind.quick => 'Быстрый ввод',
        HomeScreenKind.combo => 'Сегодня и ввод',
      };

  String _subtitle(HomeScreenKind kind) => switch (kind) {
        HomeScreenKind.today => 'Ближайшие и просроченные задачи',
        HomeScreenKind.quick => widget.voice ? 'Поле и микрофон' : 'Поле ввода',
        HomeScreenKind.combo =>
          widget.voice ? 'Задачи, поле и микрофон' : 'Задачи и поле ввода',
      };

  @override
  Widget build(BuildContext context) {
    final state = _state;
    // Пока не ответила система — ничего: строки не прыгают дважды.
    if (state == null || !state.supported) return const SizedBox.shrink();
    final colors = context.colors;
    final settings = widget.settings;
    // Вход по отпечатку закрывает задачи от чужих глаз — виджет на
    // рабочем столе не должен их показывать, что бы ни стояло здесь.
    final locked = settings.appLock;
    final tiles = <HomeScreenKind, (IconData, Color)>{
      HomeScreenKind.today: (Icons.today_outlined, colors.tileBlue),
      HomeScreenKind.quick: (Icons.keyboard_outlined, colors.tileViolet),
      HomeScreenKind.combo: (Icons.view_agenda_outlined, colors.tileGreen),
    };
    const where = 'долгое нажатие на свободном месте → «Виджеты» → '
        '${AppInfo.name}.';
    return InsetGroup(
      header: 'Виджеты',
      footer: state.canPin
          ? 'Или с рабочего стола: $where'
          : 'Добавляются с рабочего стола: $where',
      children: <Widget>[
        GroupedSwitchRow(
          key: const ValueKey<String>('homescreen-show-text'),
          secondary: IconTile(icon: Icons.notes, color: colors.tileGray),
          title: 'Показывать текст задач',
          subtitle: locked
              ? 'Включён вход по отпечатку — на виджете только число дел.'
              : 'Названия и последняя запись. Выключено — только число дел.',
          value: settings.homeScreenText,
          onChanged: locked
              ? null
              : (bool value) => widget.onChanged(
                    settings.copyWith(homeScreenShowText: value),
                  ),
        ),
        if (state.canPin)
          for (final kind in HomeScreenKind.values)
            GroupedRow(
              key: ValueKey<String>('homescreen-pin-${kind.name}'),
              icon: tiles[kind]!.$1,
              tile: tiles[kind]!.$2,
              title: _title(kind),
              subtitle: _subtitle(kind),
              // Значок, а не слово справа: подпись слева остаётся в одну
              // строку и при крупном шрифте.
              trailing: state.has(kind)
                  ? Icon(
                      Icons.check,
                      key: ValueKey<String>('homescreen-on-${kind.name}'),
                      size: 22,
                      color: colors.muted,
                      semanticLabel: 'На экране',
                    )
                  : Icon(
                      Icons.add,
                      key: ValueKey<String>('homescreen-add-${kind.name}'),
                      size: 22,
                      color: colors.accent,
                      semanticLabel: 'Добавить',
                    ),
              onTap: () => unawaited(_pin(kind)),
            ),
      ],
    );
  }
}
