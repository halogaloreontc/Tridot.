import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault_codes.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/whole_word_text.dart';
import 'passwords_kit.dart';
import 'pin_pad.dart';

/// После «Новый код восстановления» без смены ключа сейфа — честно.
const String recoveryNotRotatedNote =
    'Ключ сейфа остался прежним: старая копия файла вместе с прежним кодом '
    'ещё откроет сейф. Чтобы сменить и ключ, подтвердите ПИН-кодом.';

/// Код восстановления сейфа — один раз (ADR-025): при создании сейфа, при
/// переходе с мастер-пароля, после «Новый код восстановления».
///
/// Пропустить нельзя: «Я сохранил» требует ввести последнюю группу кода
/// (так проверяется, что код записан, а не просто пролистан). Снимки
/// экрана на это время запрещены (Android). «Скопировать» — только там,
/// где буфер не уходит на другие устройства; буфер очищается через минуту.
/// Код живёт только в этом экране и в голове или на бумаге человека.
class RecoveryCodeView extends StatefulWidget {
  const RecoveryCodeView({
    super.key,
    required this.kit,
    required this.code,
    required this.onDone,
  });

  final PasswordsKit kit;

  /// Код в виде для показа (`XXXXX-XXXXX-…`).
  final String code;

  /// Код подтверждён («Я сохранил» и верная последняя группа).
  final VoidCallback onDone;

  @override
  State<RecoveryCodeView> createState() => _RecoveryCodeViewState();
}

class _RecoveryCodeViewState extends State<RecoveryCodeView> {
  final TextEditingController _group = TextEditingController();
  bool _checking = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _group
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final bytes = SecretBytes.fromText(widget.code);
    try {
      await widget.kit.clipboard.copySecret(bytes, const Duration(seconds: 60));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Код скопирован. Буфер очистится через минуту.'),
        ),
      );
    } on Object {
      bytes.wipe();
    }
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final typed = _group.text.trim().toUpperCase().replaceAll('O', '0');
    final expected = RecoveryCode.lastGroup(widget.code);
    if (typed != expected) {
      setState(
        () => _error = 'Не совпало. Посмотрите на записанный код ещё раз.',
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await widget.kit.confirmRecovery();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _group.clear();
      widget.onDone();
    } else {
      setState(() => _error = 'Не удалось записать отметку. Попробуйте ещё.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.code.split('-');
    return SecureWindowScope(
      auth: widget.kit.auth,
      child: PopScope(
        canPop: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              key: const ValueKey<String>('recovery-code-view'),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: <Widget>[
                WholeWordText(
                  'Код восстановления',
                  style: TextStyle(
                    fontSize: 18,
                    color: context.colors.textStrong,
                  ),
                ),
                const SizedBox(height: 10),
                WholeWordText(
                  'Сохраните его: без него при смене телефона или сбросе '
                  'блокировки экрана пароли не восстановить.',
                  style: TextStyle(color: context.colors.textStrong),
                ),
                const SizedBox(height: 8),
                WholeWordText(
                  'Код показывается один раз — запишите на бумаге. Нужна ещё '
                  'резервная копия сейфа: на новом телефоне пароли вернёт '
                  'копия вместе с этим кодом.',
                  style: TextStyle(color: context.colors.text),
                ),
                const SizedBox(height: 16),
                // Пока проверяем запись, кода на экране нет: иначе
                // последнюю группу просто списали бы с экрана.
                if (!_checking)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    // Заливкой без рамки: видна и на фоне экрана, и на
                    // листе диалога (ADR-027).
                    decoration: BoxDecoration(
                      color: context.colors.bubble,
                      borderRadius: BorderRadius.circular(AppRadius.group),
                    ),
                    child: Semantics(
                      label: 'Код восстановления: ${groups.join(', ')}',
                      excludeSemantics: true,
                      child: _CodeRows(
                        key: const ValueKey<String>('recovery-code'),
                        groups: groups,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (widget.kit.canCopySecrets && !_checking)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey<String>('recovery-code-copy'),
                      onPressed: () => unawaited(_copy()),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Скопировать'),
                    ),
                  ),
                const SizedBox(height: 8),
                if (!_checking)
                  FilledButton(
                    key: const ValueKey<String>('recovery-code-saved'),
                    onPressed: () => setState(() {
                      _checking = true;
                      _error = null;
                    }),
                    child: const Text('Я сохранил'),
                  )
                else ...<Widget>[
                  WholeWordText(
                    'Проверим запись: введите последнюю группу кода — пять '
                    'знаков после последнего дефиса.',
                    style: TextStyle(color: context.colors.text),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey<String>('recovery-code-check'),
                    controller: _group,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    maxLength: RecoveryCode.groupLength,
                    style: monoTextStyle.copyWith(fontSize: 18),
                    onSubmitted: (_) => unawaited(_confirm()),
                    decoration: InputDecoration(
                      labelText: 'Последняя группа',
                      errorText: _error,
                      errorMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton(
                        key: const ValueKey<String>('recovery-code-confirm'),
                        onPressed: _busy ? null : () => unawaited(_confirm()),
                        child: const Text('Подтвердить'),
                      ),
                      TextButton(
                        key: const ValueKey<String>('recovery-code-again'),
                        onPressed: () => setState(() {
                          _checking = false;
                          _group.clear();
                          _error = null;
                        }),
                        child: const Text('Показать ещё раз'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Код через дефисы, как его вводят: ровными строками (все пять групп
/// или 3 + 2), а не «4 + 1», как вышло бы у Wrap. Дефис стоит
/// в конце строки, перенос только после него.
class _CodeRows extends StatelessWidget {
  const _CodeRows({super.key, required this.groups});

  final List<String> groups;

  static TextStyle _styleOf(AppPalette colors) => monoTextStyle.copyWith(
        fontSize: 20,
        letterSpacing: 2,
        color: colors.textStrong,
      );

  @override
  Widget build(BuildContext context) {
    final style = _styleOf(context.colors);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final chunk = lineWidth(context, 'XXXXX-', style: style);
        final fit = constraints.maxWidth.isFinite
            ? (constraints.maxWidth / chunk).floor()
            : groups.length;
        // Все пять групп в строку или 3 + 2; не входят и три — строка
        // уменьшается целиком (FittedBox), но остаётся ровной.
        final perRow = fit >= groups.length ? groups.length : 3;
        final rows = <String>[];
        for (var i = 0; i < groups.length; i += perRow) {
          final end = i + perRow > groups.length ? groups.length : i + perRow;
          final last = end == groups.length;
          rows.add(groups.sublist(i, end).join('-') + (last ? '' : '-'));
        }
        return Column(
          children: <Widget>[
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(row, style: style, maxLines: 1, softWrap: false),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Код восстановления отдельным экраном (из настроек и копий). Закрывается
/// только после подтверждения.
Future<void> showRecoveryCode(
  BuildContext context,
  PasswordsKit kit,
  String code,
) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          backgroundColor: context.colors.workspace,
          appBar: AppBar(
            backgroundColor: context.colors.workspace,
            automaticallyImplyLeading: false,
            title: const Text('Сейф'),
          ),
          body: SafeArea(
            child: RecoveryCodeView(
              kit: kit,
              code: code,
              onDone: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
