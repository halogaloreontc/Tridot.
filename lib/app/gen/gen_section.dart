import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../intent/intent_views.dart' show intentMegabytes;
import '../widgets/app_dialog.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';
import 'gen_kit.dart';

/// Раздел «Продвинутая» в настройках (ADR-046): переключатель, загрузка
/// модели (~2,5 ГБ) с ходом и «Отменой», обновление, удаление. Устройству
/// с памятью меньше 8 ГБ модель не предлагается.
final class GenSettingsSection extends StatelessWidget {
  const GenSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.gen,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final GenKit gen;

  static const String explanation = 'Большая модель на устройстве: '
      'отвечает на вопросы по таблицам («по таблице: сколько всего?»). '
      'Считает программа, модель только понимает вопрос. Ничего не '
      'отправляется — всё считается на устройстве.';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: gen,
        builder: (BuildContext context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final colors = context.colors;
    final installed = gen.installed;
    final busy = gen.isBusy;
    final lowMemory = !gen.enoughMemory;
    return InsetGroup(
      header: 'Продвинутая',
      headerKey: const Key('gen-section'),
      footer: explanation,
      children: <Widget>[
        GroupedSwitchRow(
          key: const Key('setting-gen'),
          secondary:
              IconTile(icon: Icons.auto_awesome, color: colors.tileViolet),
          title: 'Продвинутая модель',
          subtitle: _subtitle(lowMemory),
          value: settings.genEnabled,
          onChanged: lowMemory && !settings.genEnabled
              ? null
              : (bool value) => unawaited(_toggle(context, value)),
        ),
        if (busy || gen.phase == GenKitPhase.error)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: _Status(gen: gen, onRetry: () => unawaited(gen.install())),
          ),
        if (installed != null && !busy && gen.updateAvailable)
          GroupedRow(
            key: const Key('gen-update'),
            accent: true,
            title: 'Доступна новая версия — ${intentMegabytes(gen.bytes)} МБ',
            onTap: () => unawaited(_update(context)),
          ),
        if (installed != null && !busy && !gen.updateAvailable)
          GroupedRow(
            key: const Key('gen-check'),
            title: 'Проверить обновление',
            subtitle: gen.checking
                ? 'Проверяем… Сейчас: ${installed.version}'
                : gen.checkError?.message ?? 'Сейчас: ${installed.version}',
            onTap: gen.checking ? null : () => unawaited(gen.checkUpdate()),
          ),
        if (!busy && (installed != null || gen.hasPartial))
          GroupedRow(
            key: const Key('gen-delete'),
            destructive: true,
            title: installed != null
                ? 'Удалить модель (${intentMegabytes(installed.bytes)} МБ)'
                : 'Удалить недокачанную модель',
            onTap: () => unawaited(_confirmDelete(context)),
          ),
      ],
    );
  }

  String _subtitle(bool lowMemory) {
    if (gen.devModel != null) return 'Модель для разработки';
    if (lowMemory) {
      return 'Нужно от 8 ГБ памяти, на этом устройстве '
          '${((gen.ramMb ?? 0) / 1024).toStringAsFixed(1)} ГБ';
    }
    final size = '~${intentMegabytes(gen.bytes)} МБ';
    if (gen.isBusy) return '$size, скачивается';
    if (gen.installed != null) {
      return settings.genEnabled ? 'Включена' : '$size, скачана';
    }
    return '$size, скачивается по выбору';
  }

  Future<void> _toggle(BuildContext context, bool value) async {
    if (!value) {
      if (gen.isBusy) gen.cancel();
      gen.dismissError();
      onChanged(settings.copyWith(genEnabled: false));
      return;
    }
    if (gen.installed == null && gen.devModel == null) {
      if (!await _confirmDownload(context)) return;
      onChanged(settings.copyWith(genEnabled: true));
      unawaited(gen.install());
      return;
    }
    onChanged(settings.copyWith(genEnabled: true));
  }

  Future<void> _update(BuildContext context) async {
    if (!await _confirmDownload(context, update: true)) return;
    unawaited(gen.install());
  }

  Future<bool> _confirmDownload(
    BuildContext context, {
    bool update = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AppDialog(
        icon: Icons.download_outlined,
        iconColor: context.colors.tileBlue,
        scrollable: true,
        title: WholeWordText(
          update ? 'Обновить «Продвинутую»?' : 'Скачать «Продвинутую»?',
        ),
        content: Text(
          'Модель (~${intentMegabytes(gen.bytes)} МБ) скачается один раз с '
          'сайта ${GenRelease.latestUrl.host} и будет работать без '
          'интернета. Файл большой — лучше скачивать по Wi‑Fi. Фразы и '
          'таблицы никуда не отправляются.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('gen-download-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          FilledButton(
            key: const Key('gen-download-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: ActionLabel(update ? 'Обновить' : 'Скачать'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AppDialog(
        scrollable: true,
        title: const WholeWordText('Удалить «Продвинутую»?'),
        content: const Text(
          'Место освободится, вопросы к таблицам работать перестанут. '
          'Скачать модель можно снова.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('gen-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const Key('gen-delete-confirm'),
            style: TextButton.styleFrom(foregroundColor: context.colors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Удалить'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    onChanged(settings.copyWith(genEnabled: false));
    await gen.delete();
  }
}

final class _Status extends StatelessWidget {
  const _Status({required this.gen, required this.onRetry});

  final GenKit gen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (gen.phase == GenKitPhase.error) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          WholeWordText(
            gen.error?.message ?? 'Не удалось установить модель',
            key: const Key('gen-error'),
            style: TextStyle(color: colors.danger),
          ),
          if (gen.error != GenKitError.lowMemory)
            TextButton(
              key: const Key('gen-retry'),
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
    }
    final downloading = gen.phase == GenKitPhase.downloading;
    final total = gen.total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LinearProgressIndicator(
          key: const Key('gen-progress-bar'),
          value: downloading && total > 0
              ? (gen.received / total).clamp(0.0, 1.0).toDouble()
              : null,
          color: colors.accent,
          backgroundColor: colors.bubble,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: WholeWordText(
                switch (gen.phase) {
                  GenKitPhase.downloading => 'Скачивается: '
                      '${intentMegabytes(gen.received)} из '
                      '${intentMegabytes(total)} МБ',
                  GenKitPhase.verifying => 'Проверка…',
                  _ => 'Узнаём, какая версия свежая…',
                },
                key: const Key('gen-progress'),
                style: metaStyle(context),
              ),
            ),
            if (gen.phase != GenKitPhase.verifying)
              TextButton(
                key: const Key('gen-cancel'),
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                onPressed: gen.cancel,
                child: const Text('Отмена'),
              ),
          ],
        ),
      ],
    );
  }
}
