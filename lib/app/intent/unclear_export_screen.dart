import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/formatting/plural.dart';
import '../../core/intent/unclear_export.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';
import 'intent_kit.dart';
import 'unclear_share.dart';

/// «Поделиться для улучшения»: ровно те строки, что уйдут в файл (JSONL,
/// [UnclearExport]). Любую строку можно убрать; отправляет только кнопка —
/// системное «Поделиться» или «Сохранить файл».
final class UnclearExportScreen extends StatefulWidget {
  const UnclearExportScreen({
    super.key,
    required this.intent,
    this.sharer = const IoUnclearSharer(),
    this.now = DateTime.now,
  });

  final IntentKit intent;
  final UnclearSharer sharer;
  final DateTime Function() now;

  @override
  State<UnclearExportScreen> createState() => _UnclearExportScreenState();
}

final class _UnclearExportScreenState extends State<UnclearExportScreen> {
  /// Снимок журнала на момент открытия: новые фразы сюда не добавляются.
  late final List<String> _lines = UnclearExport.lines(
    widget.intent.memory.unclear,
    blocks: widget.intent.memory.blocks,
  );
  bool _sharing = false;

  /// Текст файла — ровно то, что видно на экране.
  String get text => UnclearExport.text(_lines);

  void _remove(int index) => setState(() => _lines.removeAt(index));

  Future<void> _share() async {
    if (_lines.isEmpty || _sharing) return;
    setState(() => _sharing = true);
    final outcome = await widget.sharer.share(
      fileName: UnclearExport.fileName(widget.now()),
      text: text,
    );
    if (!mounted) return;
    setState(() => _sharing = false);
    final notice = switch (outcome) {
      UnclearShareOutcome.done => null,
      UnclearShareOutcome.cancelled => null,
      UnclearShareOutcome.failed => 'Не удалось отдать файл. Можно '
          'скопировать текст',
    };
    if (notice != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(notice)));
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Текст скопирован')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final count = _lines.length;
    final lines = ruPlural(count, 'строка', 'строки', 'строк');
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: const WholeWordText('Что будет отправлено'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(top: AppSpace.m, bottom: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                InsetGroup(
                  header: 'Файл: $count $lines',
                  headerKey: const Key('export-count'),
                  footer: count == 0
                      ? 'Все строки убраны — делиться нечем'
                      : 'Это весь файл: фраза, что с ней стало, '
                          'предложенная команда и день. Уберите всё, чем '
                          'не хотите делиться.',
                  children: <Widget>[
                    for (final (index, line) in _lines.indexed)
                      _LineRow(
                        key: Key('export-line-$index'),
                        line: line,
                        removeKey: Key('export-remove-$index'),
                        onRemove: () => _remove(index),
                      ),
                    if (count == 0)
                      const GroupedRow(
                        key: Key('export-empty'),
                        title: 'Пусто',
                      ),
                  ],
                ),
                InsetGroup(
                  footer: 'Отправляете вы сами — кому и как, решаете в '
                      'следующем окне. Само приложение ничего не отправляет.',
                  children: <Widget>[
                    GroupedRow(
                      key: const Key('export-share'),
                      icon: Icons.ios_share,
                      tile: colors.tileBlue,
                      title: widget.sharer.actionTitle,
                      onTap: count == 0 || _sharing
                          ? null
                          : () => unawaited(_share()),
                    ),
                    GroupedRow(
                      key: const Key('export-copy'),
                      icon: Icons.copy_outlined,
                      tile: colors.tileGray,
                      title: 'Скопировать текст',
                      onTap: count == 0 ? null : () => unawaited(_copy()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Строка файла как есть и «убрать».
final class _LineRow extends StatelessWidget {
  const _LineRow({
    super.key,
    required this.line,
    required this.removeKey,
    required this.onRemove,
  });

  final String line;
  final Key removeKey;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.rowH, 4, 4, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              line,
              // Моноширинный шрифт — только пароли и коды (ADR-027).
              style: metaTextStyle.copyWith(color: colors.text),
            ),
          ),
          IconButton(
            key: removeKey,
            tooltip: 'Убрать строку',
            icon: Icon(Icons.close, color: colors.muted),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
