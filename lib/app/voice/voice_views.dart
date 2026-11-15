import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../../core/voice/voice_recognizer.dart';
import '../assistant_theme.dart';
import '../widgets/grouped.dart';
import 'voice_kit.dart';
import '../widgets/whole_word_text.dart';

/// Мегабайты для подписей: «12 из 44 МБ».
String voiceMegabytes(int bytes) => (bytes / (1024 * 1024)).round().toString();

/// «Скачано N из M МБ» при загрузке модели.
String voiceProgressText(VoiceKit voice) =>
    '${voiceMegabytes(voice.received)} из ${voiceMegabytes(voice.total)} МБ';

/// Размер архива модели для подписей: «~44 МБ» — из закреплённого
/// размера, а не отдельной цифрой в тексте.
String voiceModelSize(VoiceKit voice) =>
    '~${voiceMegabytes(voice.spec.bytes)} МБ';

/// Предложение включить голосовой ввод: первый раз модель скачивается с
/// сайта Vosk. `true` — «Скачать».
Future<bool> showVoiceOffer(BuildContext context, VoiceKit voice) async {
  final host = voice.spec.uri.host;
  final download = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      scrollable: true,
      title: const WholeWordText('Включить голосовой ввод?'),
      content: Text(
        'Один раз скачается модель распознавания (${voiceModelSize(voice)}) '
        'с сайта $host. Распознавание работает без интернета: звук не '
        'записывается в файл и никуда не отправляется.',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('voice-offer-later'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Не сейчас'),
        ),
        FilledButton(
          key: const Key('voice-offer-download'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Скачать'),
        ),
      ],
    ),
  );
  return download ?? false;
}

/// Зачем микрофон — перед первым системным запросом доступа. `true` —
/// «Продолжить».
Future<bool> showVoiceRationale(BuildContext context) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      scrollable: true,
      title: const WholeWordText('Доступ к микрофону'),
      content: const Text(
        'Микрофон нужен, чтобы распознать речь прямо на телефоне. Звук не '
        'записывается в файл и никуда не отправляется.',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('voice-rationale-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('voice-rationale-continue'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const WholeWordText('Продолжить'),
        ),
      ],
    ),
  );
  return go ?? false;
}

/// Чем кончился лист загрузки модели.
enum VoiceInstallOutcome {
  installed,
  cancelled,
  closed,

  /// Лист скрыт, загрузка продолжается.
  hidden,
}

/// Лист с ходом загрузки модели: закрывается сам, когда модель готова.
/// «Отмена» прерывает загрузку (скачанное остаётся для продолжения).
Future<VoiceInstallOutcome> showVoiceInstallSheet(
  BuildContext context,
  VoiceKit voice,
) async {
  final outcome = await showModalBottomSheet<VoiceInstallOutcome>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (BuildContext context) => _VoiceInstallSheet(voice: voice),
  );
  return outcome ?? VoiceInstallOutcome.closed;
}

final class _VoiceInstallSheet extends StatefulWidget {
  const _VoiceInstallSheet({required this.voice});

  final VoiceKit voice;

  @override
  State<_VoiceInstallSheet> createState() => _VoiceInstallSheetState();
}

final class _VoiceInstallSheetState extends State<_VoiceInstallSheet> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.voice.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChanged());
  }

  @override
  void dispose() {
    widget.voice.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted || _done) return;
    if (widget.voice.isInstalled) {
      _close(VoiceInstallOutcome.installed);
    } else {
      setState(() {});
    }
  }

  void _close(VoiceInstallOutcome outcome) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('voice-install-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Модель голосового ввода',
              style: TextStyle(
                color: context.colors.textStrong,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            VoiceInstallStatus(
              voice: widget.voice,
              onCancel: () {
                widget.voice.cancel();
                _close(VoiceInstallOutcome.cancelled);
              },
              onRetry: () => unawaited(widget.voice.install()),
            ),
            if (widget.voice.phase == VoiceKitPhase.error)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('voice-sheet-close'),
                  onPressed: () => _close(VoiceInstallOutcome.closed),
                  child: const Text('Закрыть'),
                ),
              )
            else if (widget.voice.isBusy)
              // Загрузка может идти минуты: лист можно убрать, она
              // продолжится, а о готовности скажет поле ввода.
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('voice-sheet-hide'),
                  onPressed: () => _close(VoiceInstallOutcome.hidden),
                  child: const Text('Скрыть'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ход установки модели: полоса загрузки с «Отменой», проверка,
/// распаковка или ошибка с «Повторить». Пусто, если ничего не идёт.
final class VoiceInstallStatus extends StatelessWidget {
  const VoiceInstallStatus({
    super.key,
    required this.voice,
    required this.onCancel,
    required this.onRetry,
  });

  final VoiceKit voice;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    switch (voice.phase) {
      case VoiceKitPhase.downloading:
        final total = voice.total;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LinearProgressIndicator(
              key: const Key('voice-progress-bar'),
              value: total > 0
                  ? (voice.received / total).clamp(0.0, 1.0).toDouble()
                  : null,
              color: context.colors.accent,
              backgroundColor: context.colors.bubble,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: WholeWordText(
                    'Скачивается: ${voiceProgressText(voice)}',
                    key: const Key('voice-progress'),
                    style: metaStyle(context),
                  ),
                ),
                TextButton(
                  key: const Key('voice-cancel'),
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  onPressed: onCancel,
                  child: const Text('Отмена'),
                ),
              ],
            ),
          ],
        );
      case VoiceKitPhase.verifying:
      case VoiceKitPhase.installing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LinearProgressIndicator(
              key: const Key('voice-progress-bar'),
              color: context.colors.accent,
              backgroundColor: context.colors.bubble,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 8),
            Text(
              voice.phase == VoiceKitPhase.verifying
                  ? 'Проверка…'
                  : 'Распаковка…',
              key: const Key('voice-progress'),
              style: metaStyle(context),
            ),
          ],
        );
      case VoiceKitPhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              voice.error?.message ?? 'Не удалось установить модель',
              key: const Key('voice-error'),
              style: TextStyle(color: context.colors.danger),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('voice-retry'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              onPressed: onRetry,
              child: const Text('Повторить'),
            ),
          ],
        );
      case VoiceKitPhase.notInstalled:
      case VoiceKitPhase.installed:
        return const SizedBox.shrink();
    }
  }
}

/// Раздел «Голосовой ввод» в настройках (ADR-023).
final class VoiceSettingsSection extends StatelessWidget {
  const VoiceSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.voice,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  /// `null` или без движка — на этой платформе голосового ввода нет.
  final VoiceKit? voice;

  @override
  Widget build(BuildContext context) {
    final voice = this.voice;
    if (voice == null || voice.support == VoiceSupport.unsupported) {
      return InsetGroup(
        header: 'Голос',
        children: <Widget>[
          GroupedRow(
            key: const Key('voice-unsupported'),
            icon: Icons.mic_none,
            tile: context.colors.tileGray,
            title: 'Голосовой ввод',
            subtitle:
                'На этой платформе пока недоступен — сейчас только Android',
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: voice,
      builder: (BuildContext context, _) => _build(context, voice),
    );
  }

  Widget _build(BuildContext context, VoiceKit voice) {
    final installed = voice.isInstalled;
    final enabled = settings.voiceInput;
    final showStatus = voice.isBusy || voice.phase == VoiceKitPhase.error;
    return InsetGroup(
      header: 'Голос',
      children: <Widget>[
        GroupedSwitchRow(
          key: const Key('setting-voice'),
          secondary: IconTile(
            icon: Icons.mic_none,
            color: context.colors.tileBlue,
          ),
          title: 'Голосовой ввод',
          subtitle: installed
              ? 'Модель скачана. Звук не сохраняется и никуда не '
                  'отправляется'
              : 'Модель ${voiceModelSize(voice)} скачается один раз с сайта '
                  '${voice.spec.uri.host}. Звук не сохраняется и никуда не '
                  'отправляется',
          value: enabled,
          onChanged: (bool value) =>
              unawaited(_toggle(context, voice, value: value)),
        ),
        if (showStatus)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: VoiceInstallStatus(
              voice: voice,
              onCancel: () {
                voice.cancel();
                onChanged(settings.copyWith(voiceInput: false));
              },
              onRetry: () => unawaited(voice.install()),
            ),
          ),
        if (enabled && voice.phase == VoiceKitPhase.notInstalled)
          GroupedRow(
            key: const Key('voice-download'),
            accent: true,
            title: voice.hasPartial
                ? 'Продолжить загрузку модели'
                : 'Скачать модель (${voiceModelSize(voice)})',
            onTap: () => unawaited(voice.install()),
          ),
        GroupedSwitchRow(
          key: const Key('setting-voice-send-now'),
          title: 'Отправлять сразу',
          subtitle: 'Без правки в поле ввода. Похожее на пароль не '
              'отправляется автоматически',
          value: settings.voiceSendImmediately,
          onChanged: enabled && installed
              ? (bool value) =>
                  onChanged(settings.copyWith(voiceSendImmediately: value))
              : null,
        ),
        if (installed || (voice.hasPartial && !voice.isBusy))
          GroupedRow(
            key: const Key('voice-delete'),
            destructive: true,
            title: installed
                ? 'Удалить модель (${voiceMegabytes(voice.installedBytes)} МБ)'
                : 'Удалить недокачанную модель',
            onTap: () => unawaited(_confirmDelete(context, voice)),
          ),
      ],
    );
  }

  /// Переключатель «Голосовой ввод». Включение без модели — то же
  /// предложение со словами о размере и источнике, что и у микрофона:
  /// загрузка не начинается без явного «Скачать».
  Future<void> _toggle(
    BuildContext context,
    VoiceKit voice, {
    required bool value,
  }) async {
    if (!value) {
      onChanged(settings.copyWith(voiceInput: false));
      // Выключили во время загрузки: скачанное остаётся.
      if (voice.isBusy) voice.cancel();
      return;
    }
    if (voice.isInstalled || voice.isBusy) {
      onChanged(settings.copyWith(voiceInput: true));
      return;
    }
    if (!await showVoiceOffer(context, voice)) return;
    onChanged(settings.copyWith(voiceInput: true));
    unawaited(voice.install());
  }

  Future<void> _confirmDelete(BuildContext context, VoiceKit voice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        scrollable: true,
        title: const WholeWordText('Удалить модель распознавания?'),
        content: const Text(
          'Место освободится, голосовой ввод выключится. Чтобы снова '
          'говорить, модель придётся скачать заново.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('voice-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const Key('voice-delete-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    onChanged(
      settings.copyWith(voiceInput: false, voiceSendImmediately: false),
    );
    await voice.delete();
  }
}
