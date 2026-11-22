import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/assistant_theme.dart';
import '../app/layout.dart';
import '../app/widgets/grouped.dart';
import '../core/intent/intent_memory.dart';
import '../core/intent/unclear_export.dart';
import 'widget_intent.dart';
import 'widget_session.dart';

/// Строка «Понимание фраз» в меню: что с моделью склада.
String intentStatus(WidgetIntent? intent) => switch (intent?.state) {
      WidgetIntentState.ready => 'модель ${intent!.version}',
      WidgetIntentState.loading => 'загружается',
      WidgetIntentState.off => 'выключено',
      WidgetIntentState.failed => 'не загрузилась',
      WidgetIntentState.none => 'без модели',
      _ => '',
    };

/// «Понимание фраз» веб-помощника (ADR-045, шаг 4): есть ли модель на
/// складе и какая, «Подсказывать команды», «Учиться на моих ответах»,
/// «Собирать непонятые фразы», «Забыть выученное» и журнал «Непонятые
/// фразы» — скопировать или скачать для улучшения. Всё — в этом браузере.
final class WidgetIntentScreen extends StatelessWidget {
  const WidgetIntentScreen({super.key, required this.session});

  final WidgetSession session;

  @override
  Widget build(BuildContext context) {
    final intent = session.intent;
    if (intent == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: intent,
      builder: (BuildContext context, _) => _body(context, intent),
    );
  }

  Widget _body(BuildContext context, WidgetIntent intent) {
    final memory = intent.memory;
    final unclear = memory.unclear;
    final version = intent.version;
    final learned = memory.learnedCount;
    return ListView(
      key: const Key('intent-screen'),
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      children: <Widget>[
        const LargeTitle('Понимание фраз'),
        InsetGroup(
          footer: 'Когда я не понимаю фразу, модель в этом браузере '
              'предлагает: «Похоже, вы хотите …?». «Да» — команда '
              'выполняется как обычно, с подтверждением записи; «Нет» — '
              'больше так не предлагаю. Фразы никуда не отправляются.',
          children: <Widget>[
            GroupedRow(
              key: const Key('intent-model'),
              icon: Icons.psychology_outlined,
              title: 'Модель склада',
              subtitle: _modelText(intent),
              trailing: intent.state == WidgetIntentState.failed
                  ? TextButton(
                      key: const Key('intent-retry'),
                      onPressed: () => unawaited(intent.load()),
                      child: const Text('Повторить'),
                    )
                  : null,
            ),
            if (version != null)
              GroupedSwitchRow(
                key: const Key('intent-enabled'),
                title: 'Подсказывать команды',
                value: intent.enabled,
                onChanged: (bool on) => unawaited(intent.setEnabled(on)),
              ),
          ],
        ),
        InsetGroup(
          footer: 'Выученное и журнал хранятся только в этом браузере, у '
              'каждого сотрудника свои, и стираются при выходе из склада. '
              'Пароли, PIN и коды сюда не попадают никогда.',
          children: <Widget>[
            GroupedSwitchRow(
              key: const Key('intent-learning'),
              title: 'Учиться на моих ответах',
              subtitle: '«Да» и «Нет» на подсказки запоминаются',
              value: memory.learning,
              onChanged: (bool on) => unawaited(intent.setLearning(on)),
            ),
            GroupedSwitchRow(
              key: const Key('intent-logging'),
              title: 'Собирать непонятые фразы',
              subtitle: 'Не больше 200, старше 90 дней удаляются',
              value: memory.logging,
              onChanged: (bool on) => unawaited(intent.setLogging(on)),
            ),
            GroupedRow(
              key: const Key('intent-forget'),
              icon: Icons.restart_alt,
              title: 'Забыть выученное',
              value: learned == 0 ? 'пусто' : '$learned',
              destructive: learned > 0,
              onTap: learned == 0
                  ? null
                  : () => unawaited(_forget(context, intent, learned)),
            ),
          ],
        ),
        InsetGroup(
          header: 'Непонятые фразы',
          footer: unclear.isEmpty
              ? 'Пока пусто.'
              : 'Чтобы помочь улучшить понимание, скопируйте или скачайте '
                  'список и передайте разработчику: по нему пишут похожие '
                  'примеры, ваши фразы модель не учат.',
          children: <Widget>[
            for (final (index, phrase) in unclear.take(50).indexed)
              GroupedRow(
                key: ValueKey<String>('intent-unclear-$index'),
                title: phrase.text,
                subtitle: '${_kind(intent, phrase)} · ${_day(phrase.at)}',
                trailing: IconButton(
                  tooltip: 'Удалить',
                  icon: const Icon(Icons.close),
                  onPressed: () => unawaited(intent.removeUnclear(phrase)),
                ),
              ),
            if (unclear.length > 50)
              GroupedRow(title: 'И ещё ${unclear.length - 50}'),
          ],
        ),
        if (unclear.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.pageH),
            child: Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: <Widget>[
                FilledButton.icon(
                  key: const Key('intent-copy'),
                  onPressed: () => unawaited(_copy(context, unclear)),
                  icon: const Icon(Icons.copy),
                  label: const Text('Скопировать'),
                ),
                if (session.saveFile case final save?)
                  OutlinedButton.icon(
                    key: const Key('intent-download'),
                    onPressed: () => save(
                      UnclearExport.fileName(DateTime.now()),
                      UnclearExport.text(UnclearExport.lines(unclear)),
                    ),
                    icon: const Icon(Icons.download),
                    label: const Text('Скачать файл'),
                  ),
                TextButton(
                  key: const Key('intent-clear'),
                  onPressed: () => unawaited(intent.clearUnclear()),
                  child: const Text('Очистить всё'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _modelText(WidgetIntent intent) => switch (intent.state) {
        WidgetIntentState.ready =>
          'Версия ${intent.version} — работает в этом браузере',
        WidgetIntentState.loading =>
          'Версия ${intent.version} загружается и проверяется',
        WidgetIntentState.off =>
          'Версия ${intent.version} — подсказки выключены',
        WidgetIntentState.failed =>
          'Не загрузилась: ${intent.problem.isEmpty ? 'ошибка' : intent.problem}',
        WidgetIntentState.none =>
          'Склад её не поставил. Ставит администратор: Управление → '
              'Инструменты → Помощник → «Модель понимания фраз»',
        WidgetIntentState.unknown => 'Проверяем склад…',
      };

  static String _kind(WidgetIntent intent, UnclearPhrase phrase) {
    final label = phrase.label;
    final description = label == null
        ? null
        : intent.fallback.model?.index.labels.byId(label)?.description;
    final what =
        description == null || description.isEmpty ? '' : ': $description';
    return switch (phrase.kind) {
      UnclearKind.unknown => 'Не понял',
      UnclearKind.accepted => 'Исправлено догадкой$what',
      UnclearKind.rejected => 'Догадка отвергнута$what',
    };
  }

  static String _day(DateTime at) {
    final local = at.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.${local.year}';
  }

  static Future<void> _copy(
    BuildContext context,
    List<UnclearPhrase> unclear,
  ) async {
    final text = UnclearExport.text(UnclearExport.lines(unclear));
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(
      const SnackBar(content: Text('Список скопирован')),
    );
  }

  static Future<void> _forget(
    BuildContext context,
    WidgetIntent intent,
    int count,
  ) async {
    final colors = context.colors;
    final yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Забыть выученное?'),
        content: Text(
          'Ответы на подсказки ($count) забудутся, модель будет предлагать '
          'как в начале.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const Key('intent-forget-yes'),
            style: TextButton.styleFrom(foregroundColor: colors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Забыть'),
          ),
        ],
      ),
    );
    if (yes ?? false) await intent.forgetLearned();
  }
}
