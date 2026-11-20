import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/intent/intent_memory.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/app_dialog.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';
import 'intent_kit.dart';
import 'intent_views.dart';
import 'unclear_export_screen.dart';
import 'unclear_share.dart';

/// Что стало с фразой: «Не понял», «Исправлено догадкой: …».
String unclearStatus(IntentKit intent, UnclearPhrase phrase) {
  final description = intent.describe(phrase.label);
  return switch (phrase.kind) {
    UnclearKind.unknown => 'Не понял',
    UnclearKind.accepted => description == null
        ? 'Исправлено догадкой'
        : 'Исправлено догадкой: $description',
    UnclearKind.rejected => description == null
        ? 'Догадка отвергнута'
        : 'Догадка отвергнута: $description',
  };
}

/// «Настройки → Понимание фраз → Непонятые фразы» (ADR-045, п. 8): журнал
/// на устройстве, новые первыми. Удалить одну, очистить всё, поделиться —
/// только после просмотра файла ([UnclearExportScreen]).
final class UnclearPhrasesScreen extends StatelessWidget {
  const UnclearPhrasesScreen({
    super.key,
    required this.intent,
    this.sharer = const IoUnclearSharer(),
    this.now = DateTime.now,
  });

  final IntentKit intent;
  final UnclearSharer sharer;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: const WholeWordText('Непонятые фразы'),
      ),
      body: ListenableBuilder(
        listenable: intent,
        builder: (BuildContext context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.colors;
    final phrases = intent.memory.unclear;
    final today = now();
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: AppSpace.m, bottom: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (phrases.isEmpty)
                InsetGroup(
                  footer: intent.memory.logging
                      ? null
                      : 'Сбор выключен в настройках — новые фразы не '
                          'записываются',
                  children: const <Widget>[
                    GroupedRow(
                      key: Key('unclear-empty'),
                      title: 'Пока пусто',
                      subtitle: 'Сюда попадают фразы, которые Связной не '
                          'понял, и исправленные догадкой',
                    ),
                  ],
                )
              else
                InsetGroup(
                  header: 'Новые первыми',
                  footer: intent.memory.logging
                      ? 'Хранятся только здесь: последние 200, не старше '
                          '90 дней'
                      : 'Сбор выключен в настройках — новые фразы не '
                          'записываются',
                  children: <Widget>[
                    for (final (index, phrase) in phrases.indexed)
                      GroupedRow(
                        key: Key('unclear-$index'),
                        title: phrase.text,
                        subtitle: '${unclearStatus(intent, phrase)} · '
                            '${intentDay(phrase.at, today)}',
                        trailing: IconButton(
                          key: Key('unclear-remove-$index'),
                          tooltip: 'Удалить фразу',
                          icon: Icon(Icons.close, color: colors.muted),
                          onPressed: () =>
                              unawaited(intent.removeUnclear(phrase)),
                        ),
                      ),
                  ],
                ),
              InsetGroup(
                footer: 'Само ничего не отправляется. Сначала вы увидите '
                    'файл целиком и уберёте лишнее. По нему разработчик '
                    'напишет похожие примеры — ваши фразы модель не учат.',
                children: <Widget>[
                  GroupedRow(
                    key: const Key('unclear-share'),
                    icon: Icons.ios_share,
                    tile: colors.tileBlue,
                    title: 'Поделиться для улучшения',
                    chevron: true,
                    onTap: phrases.isEmpty
                        ? null
                        : () => unawaited(
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (BuildContext context) =>
                                      UnclearExportScreen(
                                    intent: intent,
                                    sharer: sharer,
                                    now: now,
                                  ),
                                ),
                              ),
                            ),
                  ),
                  GroupedRow(
                    key: const Key('unclear-clear'),
                    destructive: phrases.isNotEmpty,
                    title: 'Очистить всё',
                    onTap: phrases.isEmpty
                        ? null
                        : () => unawaited(_confirmClear(context)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AppDialog(
        scrollable: true,
        title: const WholeWordText('Очистить непонятые фразы?'),
        content: const Text(
          'Журнал на этом устройстве будет удалён. Выученное и модель '
          'останутся.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('unclear-clear-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const Key('unclear-clear-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Очистить'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await intent.clearUnclear();
  }
}
