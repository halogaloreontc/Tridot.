import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/replies/reply_template.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/app_dialog.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';
import 'notify_channel.dart';

/// Чем кончился лист «Напоминания вовремя».
enum NotifyOutcome {
  /// Уведомления разрешены (точное время — как решил человек).
  granted,

  /// «Не сейчас»: сегодня лист сам больше не появляется.
  dismissed,

  /// Отказ в системном вопросе.
  denied,

  /// Лист закрыли, ничего не выбрав.
  closed,
}

/// Лист «Напоминания вовремя» (ADR-029): зачем уведомления — перед
/// системным вопросом. Шаги: объяснение → системный вопрос; выключено в
/// настройках — «Открыть настройки»; разрешено, но Android 12+ не даёт
/// точного времени — «Точно в срок». Вернулись из настроек системы —
/// состояние читается заново.
Future<NotifyOutcome> showNotifyRationale(
  BuildContext context, {
  required NotifyPlatform platform,
  required Persona notifier,
}) async {
  final outcome = await showAppSheet<NotifyOutcome>(
    context: context,
    builder: (BuildContext context) =>
        NotifySheet(platform: platform, notifier: notifier),
  );
  return outcome ?? NotifyOutcome.closed;
}

enum _Step { explain, settings, exact }

/// Содержимое листа «Напоминания вовремя».
final class NotifySheet extends StatefulWidget {
  const NotifySheet({
    super.key,
    required this.platform,
    required this.notifier,
  });

  final NotifyPlatform platform;
  final Persona notifier;

  @override
  State<NotifySheet> createState() => _NotifySheetState();
}

final class _NotifySheetState extends State<NotifySheet>
    with WidgetsBindingObserver {
  _Step _step = _Step.explain;
  bool _busy = false;
  bool _done = false;

  /// Ушли в настройки системы: на возврате состояние читается заново.
  bool _awayInSettings = false;

  NotifyPlatform get _platform => widget.platform;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_readInitial());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _readInitial() async {
    final status = await _platform.status();
    if (!mounted) return;
    if (status == NotifyPermission.permanentlyDenied) {
      setState(() => _step = _Step.settings);
    } else if (status.isGranted) {
      await _afterGranted();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awayInSettings) {
      _awayInSettings = false;
      unawaited(_reread());
    }
  }

  Future<void> _reread() async {
    if (_step == _Step.exact) {
      final exact = await _platform.exactStatus();
      if (!mounted) return;
      if (exact != ExactAlarm.denied) _close(NotifyOutcome.granted);
      return;
    }
    final status = await _platform.status();
    if (!mounted) return;
    if (status.isGranted) await _afterGranted();
  }

  /// Разрешено: если Android не даёт точного времени — второй шаг.
  Future<void> _afterGranted() async {
    final exact = await _platform.exactStatus();
    if (!mounted) return;
    if (exact == ExactAlarm.denied) {
      setState(() => _step = _Step.exact);
    } else {
      _close(NotifyOutcome.granted);
    }
  }

  Future<void> _allow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final status = await _platform.request();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (status) {
      case NotifyPermission.granted:
        await _afterGranted();
      case NotifyPermission.permanentlyDenied:
        setState(() => _step = _Step.settings);
      case NotifyPermission.denied:
      case NotifyPermission.notAsked:
      case NotifyPermission.unsupported:
        _close(NotifyOutcome.denied);
    }
  }

  Future<void> _openSettings() async {
    _awayInSettings = true;
    await _platform.openNotificationSettings();
  }

  Future<void> _openExact() async {
    _awayInSettings = true;
    await _platform.openExactAlarmSettings();
  }

  void _close(NotifyOutcome outcome) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(outcome);
  }

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  String get _body {
    final name = widget.notifier.russianName;
    final remind =
        widget.notifier.gender == ReplyGender.female ? 'напомнила' : 'напомнил';
    final lock = _android
        ? ' На заблокированном экране видно только «Напоминание из '
            '${AppInfo.name}».'
        : '';
    return 'Чтобы $name $remind о задаче, даже когда ${AppInfo.name} '
        'закрыт, нужно разрешить уведомления. Они создаются на этом '
        'устройстве и никуда не отправляются.$lock';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (String title, String body, String? hint) = switch (_step) {
      _Step.explain => ('Напоминания вовремя', _body, null),
      _Step.settings => (
          'Напоминания вовремя',
          _body,
          'Уведомления выключены в настройках '
              '${_android ? 'телефона' : 'системы'}. Включите их для '
              '${AppInfo.name} — и вернитесь сюда.',
        ),
      _Step.exact => (
          'Точно в срок',
          'Без этого Android может прислать напоминание на несколько минут '
              'позже.',
          null,
        ),
    };
    final buttons = switch (_step) {
      _Step.explain => <Widget>[
          TextButton(
            key: const Key('notify-later'),
            onPressed: () => _close(NotifyOutcome.dismissed),
            child: const ActionLabel('Не сейчас'),
          ),
          FilledButton(
            key: const Key('notify-allow'),
            onPressed: _busy ? null : () => unawaited(_allow()),
            child: const WholeWordText(
              'Разрешить',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      _Step.settings => <Widget>[
          TextButton(
            key: const Key('notify-later'),
            onPressed: () => _close(NotifyOutcome.dismissed),
            child: const ActionLabel('Не сейчас'),
          ),
          FilledButton(
            key: const Key('notify-open-settings'),
            onPressed: () => unawaited(_openSettings()),
            child: const WholeWordText(
              'Открыть настройки',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      _Step.exact => <Widget>[
          TextButton(
            key: const Key('notify-exact-skip'),
            onPressed: () => _close(NotifyOutcome.granted),
            child: const ActionLabel('Пусть так'),
          ),
          FilledButton(
            key: const Key('notify-exact-allow'),
            onPressed: () => unawaited(_openExact()),
            child: const WholeWordText(
              'Разрешить точное время',
              textAlign: TextAlign.center,
            ),
          ),
        ],
    };
    // Общая шторка разрешения ([AppSheet]): кнопки в закреплённом низу —
    // при крупном шрифте текст листается, а «Разрешить» и «Не сейчас»
    // всегда на виду.
    return AppSheet(
      key: const Key('notify-sheet'),
      icon: _step == _Step.exact
          ? Icons.alarm_on_outlined
          : Icons.notifications_active_outlined,
      iconColor: colors.tileAmber,
      title: WholeWordText(title, key: const Key('notify-title')),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(body, key: const Key('notify-body')),
          if (hint != null) ...<Widget>[
            const SizedBox(height: AppSpace.xs),
            Text(
              hint,
              key: const Key('notify-hint'),
              style: TextStyle(color: colors.muted),
            ),
          ],
        ],
      ),
      actions: buttons,
    );
  }
}

/// Группа «Разрешения» в настройках (ADR-029): уведомления, точное время,
/// задачи без времени, будильник. Только где уведомления есть (Android,
/// macOS); состояние читается заново, когда приложение возвращается из
/// настроек системы.
final class PermissionsSection extends StatefulWidget {
  const PermissionsSection({
    super.key,
    required this.platform,
    required this.settings,
    required this.onChanged,
  });

  final NotifyPlatform platform;
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<PermissionsSection> createState() => _PermissionsSectionState();
}

final class _PermissionsSectionState extends State<PermissionsSection>
    with WidgetsBindingObserver {
  NotifyPermission? _status;
  ExactAlarm _exact = ExactAlarm.notNeeded;
  bool? _clock;

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
    final platform = widget.platform;
    final status = await platform.status();
    final exact = await platform.exactStatus();
    final clock =
        platform.alarmsSupported ? await platform.canSetAlarm() : null;
    if (!mounted) return;
    setState(() {
      _status = status;
      _exact = exact;
      _clock = clock;
    });
  }

  Future<void> _onNotifications() async {
    final status = _status;
    if (status == null) return;
    if (status.isGranted) {
      await widget.platform.openNotificationSettings();
      return;
    }
    final outcome = await showNotifyRationale(
      context,
      platform: widget.platform,
      notifier: widget.settings.personas.notifier,
    );
    if (!mounted) return;
    if (!widget.settings.notifyExplained) {
      widget.onChanged(widget.settings.copyWith(notifyExplained: true));
    }
    if (outcome != NotifyOutcome.closed) await _read();
  }

  static String statusText(NotifyPermission? status) => switch (status) {
        null => '',
        NotifyPermission.granted => 'Включены',
        NotifyPermission.notAsked => 'Не запрашивались',
        NotifyPermission.denied ||
        NotifyPermission.permanentlyDenied =>
          'Выключены',
        NotifyPermission.unsupported => 'Нет на этом устройстве',
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final settings = widget.settings;
    final hour = settings.notifyDateOnlyHour;
    return InsetGroup(
      header: 'Разрешения',
      footer: 'Уведомления создаются на этом устройстве и никуда не '
          'отправляются. Будильник и таймер ставятся в «Часах» — '
          'без отдельного разрешения.',
      children: <Widget>[
        GroupedRow(
          key: const ValueKey<String>('permission-notifications'),
          icon: Icons.notifications_outlined,
          tile: colors.tileRed,
          title: 'Уведомления',
          subtitle: statusText(_status),
          chevron: true,
          onTap: _status == null ? null : () => unawaited(_onNotifications()),
        ),
        if (_exact != ExactAlarm.notNeeded)
          GroupedRow(
            key: const ValueKey<String>('permission-exact'),
            icon: Icons.alarm_on_outlined,
            tile: colors.tileAmber,
            title: 'Точное время напоминаний',
            subtitle: _exact == ExactAlarm.granted
                ? 'Разрешено'
                : 'Напоминания могут опаздывать на несколько минут',
            chevron: true,
            onTap: () => unawaited(widget.platform.openExactAlarmSettings()),
          ),
        GroupedSwitchRow(
          key: const ValueKey<String>('permission-date-only'),
          secondary:
              IconTile(icon: Icons.event_outlined, color: colors.tileBlue),
          title: 'Напоминать о задачах без времени',
          subtitle: 'В $hour:00 в день срока',
          value: settings.notifyDateOnly,
          onChanged: (bool value) =>
              widget.onChanged(settings.copyWith(notifyDateOnly: value)),
        ),
        if (_clock != null)
          GroupedRow(
            key: const ValueKey<String>('permission-alarm'),
            icon: Icons.alarm_outlined,
            tile: colors.tileViolet,
            title: 'Будильник и таймер',
            subtitle: _clock!
                ? 'Ставятся в приложении «Часы»'
                : 'Нет приложения «Часы»',
          ),
      ],
    );
  }
}
