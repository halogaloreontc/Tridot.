import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/formatting/plural.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';
import 'intent_kit.dart';
import 'intent_views.dart';
import 'unclear_phrases_screen.dart';

/// Раздел «Понимание фраз» в настройках (ADR-045, шаг 3): уровень модели
/// («Выключено», «Точная») с загрузкой, обновлением и удалением;
/// «Учиться на моих ответах» и «Собирать непонятые фразы». Устроен как
/// «Голос»: выбор строками с галочкой, ход загрузки под ними.
final class IntentSettingsSection extends StatelessWidget {
  const IntentSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.intent,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final IntentKit intent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: intent,
        builder: (BuildContext context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final colors = context.colors;
    final installed = intent.installed;
    final busy = intent.isBusy;
    final showStatus = busy || intent.phase == IntentKitPhase.error;
    final learned = intent.memory.learnedCount;
    final unclear = intent.memory.unclear.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InsetGroup(
          header: 'Понимание фраз',
          headerKey: const Key('intent-section'),
          footer: intentExplanation,
          children: <Widget>[
            for (final tier in IntentTier.values) _tierRow(context, tier),
            if (showStatus)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: IntentInstallStatus(
                  intent: intent,
                  onCancel: () {
                    intent.cancel();
                    onChanged(
                      settings.copyWith(
                        intentTier: intent.installed?.tier ?? IntentTier.off,
                      ),
                    );
                  },
                  onRetry: () => unawaited(
                    intent.install(intent.busyTier ?? settings.intentTier),
                  ),
                ),
              ),
            if (installed != null && !busy && intent.updateAvailable)
              GroupedRow(
                key: const Key('intent-update'),
                accent: true,
                title: 'Доступна новая версия модели понимания — '
                    '${intentMegabytes(intent.bytesOf(installed.tier))}'
                    ' МБ',
                onTap: () => unawaited(_update(context, installed.tier)),
              ),
            if (installed != null && !busy && !intent.updateAvailable)
              GroupedRow(
                key: const Key('intent-check'),
                title: 'Проверить обновление',
                subtitle: _checkSubtitle(installed),
                onTap: intent.checking
                    ? null
                    : () => unawaited(intent.checkUpdate()),
              ),
            if (!busy && (installed != null || intent.hasPartial))
              GroupedRow(
                key: const Key('intent-delete'),
                destructive: true,
                title: installed != null
                    ? 'Удалить модель (${intentMegabytes(installed.bytes)}'
                        ' МБ)'
                    : 'Удалить недокачанную модель',
                onTap: () => unawaited(_confirmDelete(context)),
              ),
          ],
        ),
        InsetGroup(
          header: 'Учёба на ответах',
          footer: 'Всё это хранится только на этом устройстве. Фразы о '
              'паролях, PIN и кодах не запоминаются и не попадают в журнал.',
          children: <Widget>[
            GroupedSwitchRow(
              key: const Key('setting-intent-learning'),
              secondary: IconTile(
                icon: Icons.school_outlined,
                color: colors.tileGreen,
              ),
              title: 'Учиться на моих ответах',
              subtitle: '«Да» и «Нет» на догадку запоминаются: похожие фразы '
                  'будут поняты сразу, отвергнутая догадка не повторится',
              value: settings.intentLearning,
              onChanged: (bool value) =>
                  onChanged(settings.copyWith(intentLearning: value)),
            ),
            GroupedRow(
              key: const Key('intent-forget'),
              icon: Icons.delete_sweep_outlined,
              tile: colors.tileGray,
              title: 'Забыть выученное',
              subtitle: learned > 0
                  ? 'Запомнено ответов: $learned'
                  : 'Пока ничего не выучено',
              onTap: learned > 0
                  ? () => unawaited(_confirmForget(context, learned))
                  : null,
            ),
            GroupedSwitchRow(
              key: const Key('setting-intent-logging'),
              secondary: IconTile(
                icon: Icons.history,
                color: colors.tileGray,
              ),
              title: 'Собирать непонятые фразы',
              subtitle: 'Последние 200 за 90 дней. Само ничего не '
                  'отправляется — поделиться можно вручную',
              value: settings.intentLogging,
              onChanged: (bool value) =>
                  onChanged(settings.copyWith(intentLogging: value)),
            ),
            GroupedRow(
              key: const Key('intent-unclear'),
              icon: Icons.help_outline,
              tile: colors.tileViolet,
              title: 'Непонятые фразы',
              value: '$unclear',
              chevron: true,
              onTap: () => unawaited(
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) =>
                        UnclearPhrasesScreen(intent: intent),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _checkSubtitle(IntentInstalled installed) {
    final current = '«${installed.tier.title}» ${installed.version}';
    if (intent.checking) return 'Проверяем… Сейчас: $current';
    final error = intent.checkError;
    if (error != null) return error.message;
    if (intent.checked) return 'У вас последняя версия: $current';
    return 'Сейчас: $current';
  }

  /// Подпись уровня: размер и что с ним сейчас.
  String _tierSubtitle(IntentTier tier) {
    if (tier == IntentTier.off) {
      return intentTierHint(tier);
    }
    final parts = <String>[
      '${intentTierSize(intent, tier)}, ${intentTierHint(tier)}',
    ];
    final installed = intent.installed;
    if (intent.isBusy && intent.busyTier == tier) {
      parts.add('скачивается');
    } else if (installed?.tier == tier) {
      if (intent.loadFailed) {
        parts.add('не запустилась на этом устройстве');
      } else if (settings.intentTier == IntentTier.off) {
        parts.add('скачана');
      } else if (settings.intentTier == tier) {
        parts.add(intent.running ? 'работает' : 'скачана');
      } else {
        parts.add('работает, пока не скачается другая');
      }
    } else if (intent.hasPartial &&
        intent.busyTier == tier &&
        intent.phase == IntentKitPhase.error) {
      parts.add('скачана не до конца');
    }
    return parts.join(' · ');
  }

  Widget _tierRow(BuildContext context, IntentTier tier) {
    final selected = settings.intentTier == tier;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: GroupedRow(
        key: Key('intent-tier-${tier.id}'),
        title: tier.title,
        subtitle: _tierSubtitle(tier),
        onTap: () => unawaited(_choose(context, tier)),
        trailing: SizedBox(
          width: 24,
          child: selected
              ? Icon(Icons.check, size: 22, color: context.colors.accent)
              : null,
        ),
      ),
    );
  }

  Future<void> _choose(BuildContext context, IntentTier tier) async {
    final installed = intent.installed;
    if (tier == settings.intentTier &&
        (tier == IntentTier.off ||
            installed?.tier == tier ||
            intent.isBusy && intent.busyTier == tier)) {
      return;
    }
    if (tier == IntentTier.off) {
      if (intent.isBusy) intent.cancel();
      intent.dismissError();
      onChanged(settings.copyWith(intentTier: IntentTier.off));
      return;
    }
    if (installed?.tier == tier) {
      if (intent.isBusy) intent.cancel();
      intent.dismissError();
      onChanged(settings.copyWith(intentTier: tier));
      return;
    }
    if (!await confirmIntentDownload(context, intent, tier)) return;
    if (intent.isBusy) {
      intent.cancel();
      await intent.whenIdle;
    }
    onChanged(settings.copyWith(intentTier: tier));
    unawaited(intent.install(tier));
  }

  Future<void> _update(BuildContext context, IntentTier tier) async {
    if (!await confirmIntentDownload(context, intent, tier, update: true)) {
      return;
    }
    unawaited(intent.install(tier));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AppDialog(
        scrollable: true,
        title: const WholeWordText('Удалить модель понимания?'),
        content: const Text(
          'Место освободится, догадки «Похоже, вы хотите…?» пропадут. '
          'Выученное и непонятые фразы останутся.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('intent-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const Key('intent-delete-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Удалить'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    onChanged(settings.copyWith(intentTier: IntentTier.off));
    await intent.delete();
  }

  Future<void> _confirmForget(BuildContext context, int count) async {
    final answers = ruPlural(count, 'ответ', 'ответа', 'ответов');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AppDialog(
        scrollable: true,
        title: const WholeWordText('Забыть выученное?'),
        content: Text(
          'Связной забудет $count $answers «Да» и «Нет» на догадки. '
          'Модель и непонятые фразы останутся.',
          key: const Key('intent-forget-text'),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('intent-forget-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const Key('intent-forget-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Забыть'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await intent.forgetLearned();
  }
}
