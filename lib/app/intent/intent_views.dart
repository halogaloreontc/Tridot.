import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/whole_word_text.dart';
import 'intent_kit.dart';

/// Мегабайты для подписей модели понимания: «~32 МБ» (десятичные, как в
/// выпуске модели).
String intentMegabytes(int bytes) => (bytes / 1e6).round().toString();

/// «~32 МБ» для уровня [tier].
String intentTierSize(IntentKit intent, IntentTier tier) =>
    '~${intentMegabytes(intent.bytesOf(tier))} МБ';

/// Что даёт уровень.
String intentTierHint(IntentTier tier) => switch (tier) {
      IntentTier.off => 'Только правила',
      IntentTier.accurate => 'понимает больше',
    };

/// Объяснение под разделом «Понимание фраз».
const String intentExplanation =
    'Когда Связной не понял фразу, модель на устройстве предложит догадку '
    '«Похоже, вы хотите…?». Ничего не отправляется — всё считается на '
    'телефоне.';

/// Откуда скачивается модель (для подписей).
String get intentHost => IntentRelease.latestUrl.host;

/// Перед загрузкой уровня [tier]: размер, источник, совет про Wi‑Fi для
/// большого файла. `true` — «Скачать».
Future<bool> confirmIntentDownload(
  BuildContext context,
  IntentKit intent,
  IntentTier tier, {
  bool update = false,
}) async {
  final bytes = intent.bytesOf(tier);
  final size = intentTierSize(intent, tier);
  final wifi = bytes > IntentKit.wifiHintBytes
      ? ' Файл большой — лучше скачивать по Wi‑Fi.'
      : '';
  final download = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AppDialog(
      icon: Icons.download_outlined,
      iconColor: context.colors.tileBlue,
      scrollable: true,
      title: WholeWordText(
        update
            ? 'Обновить модель понимания?'
            : 'Скачать модель «${tier.title}»?',
      ),
      content: Text(
        'Модель ($size) скачается один раз с сайта $intentHost и будет '
        'работать без интернета. Фразы никуда не отправляются.$wifi',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('intent-download-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const ActionLabel('Отмена'),
        ),
        FilledButton(
          key: const Key('intent-download-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: ActionLabel(update ? 'Обновить' : 'Скачать'),
        ),
      ],
    ),
  );
  return download ?? false;
}

/// Однократное предложение включить нейромодуль после первого «не понял».
/// `true` — «Включить».
Future<bool> showIntentOffer(BuildContext context, IntentKit intent) async {
  final bytes = intent.bytesOf(IntentTier.accurate);
  final size = intentTierSize(intent, IntentTier.accurate);
  final wifi = bytes > IntentKit.wifiHintBytes
      ? ' Файл большой — лучше скачивать по Wi‑Fi.'
      : '';
  final download = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AppDialog(
      icon: Icons.lightbulb_outline,
      iconColor: context.colors.tileViolet,
      scrollable: true,
      title: const WholeWordText('Включить нейромодуль?'),
      content: Text(
        'Когда Связной не понял фразу, нейромодуль на устройстве может '
        'предложить догадку «Похоже, вы хотите…?». Модель ($size) скачается '
        'один раз с сайта $intentHost. Ничего не отправляется — всё '
        'считается на телефоне.$wifi Включить позже можно в «Настройки → '
        'Понимание фраз».',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('intent-offer-later'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const ActionLabel('Не сейчас'),
        ),
        FilledButton(
          key: const Key('intent-offer-download'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const ActionLabel('Включить'),
        ),
      ],
    ),
  );
  return download ?? false;
}

/// Ход установки: полоса с «Отменой», проверка, распаковка или ошибка с
/// «Повторить». Пусто, если ничего не идёт.
final class IntentInstallStatus extends StatelessWidget {
  const IntentInstallStatus({
    super.key,
    required this.intent,
    required this.onCancel,
    required this.onRetry,
  });

  final IntentKit intent;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget bar(double? value) => LinearProgressIndicator(
          key: const Key('intent-progress-bar'),
          value: value,
          color: colors.accent,
          backgroundColor: colors.bubble,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        );
    final title = intent.busyTier?.title ?? '';
    switch (intent.phase) {
      case IntentKitPhase.checking:
      case IntentKitPhase.downloading:
        final total = intent.total;
        final downloading = intent.phase == IntentKitPhase.downloading;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            bar(
              downloading && total > 0
                  ? (intent.received / total).clamp(0.0, 1.0).toDouble()
                  : null,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: WholeWordText(
                    downloading
                        ? '«$title» скачивается: '
                            '${intentMegabytes(intent.received)} из '
                            '${intentMegabytes(total)} МБ'
                        : 'Узнаём, какая версия свежая…',
                    key: const Key('intent-progress'),
                    style: metaStyle(context),
                  ),
                ),
                TextButton(
                  key: const Key('intent-cancel'),
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  onPressed: onCancel,
                  child: const Text('Отмена'),
                ),
              ],
            ),
          ],
        );
      case IntentKitPhase.verifying:
      case IntentKitPhase.installing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            bar(null),
            const SizedBox(height: 8),
            Text(
              intent.phase == IntentKitPhase.verifying
                  ? 'Проверка…'
                  : 'Распаковка…',
              key: const Key('intent-progress'),
              style: metaStyle(context),
            ),
          ],
        );
      case IntentKitPhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            WholeWordText(
              intent.error?.message ?? 'Не удалось установить модель',
              key: const Key('intent-error'),
              style: TextStyle(color: colors.danger),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('intent-retry'),
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
      case IntentKitPhase.idle:
        return const SizedBox.shrink();
    }
  }
}

/// День для подписей: «20 нояб. 2026» — год, если не текущий.
String intentDay(DateTime at, DateTime now) {
  const months = <String>[
    'янв.',
    'февр.',
    'мар.',
    'апр.',
    'мая',
    'июн.',
    'июл.',
    'авг.',
    'сент.',
    'окт.',
    'нояб.',
    'дек.',
  ];
  final local = at.toLocal();
  final day = '${local.day} ${months[local.month - 1]}';
  return local.year == now.year ? day : '$day ${local.year}';
}
