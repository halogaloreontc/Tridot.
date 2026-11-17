import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/passwords/secret_bytes.dart';
import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';
import '../widgets/app_dialog.dart';

/// Скрытое поле для пароля или заметки (раздел 8): без подсказок,
/// автоисправления и обучения клавиатуры, без `autofillHints` и вне
/// `AutofillGroup`. Общий composer пароль не принимает никогда (D11).
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.error,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.multiline = false,
    this.allowShow = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;
  final String? error;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  /// Заметка: несколько строк (скрытое поле многострочным быть не может,
  /// поэтому заметка открывается кнопкой «глаз» только при вводе).
  final bool multiline;

  /// Кнопка «показать вводимое» (только в редакторе, не на замке).
  final bool allowShow;

  final bool enabled;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final obscure = !_visible;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: obscure,
      obscuringCharacter: '•',
      enableSuggestions: false,
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      // null, а не пустой список: поле не участвует в автозаполнении
      // вовсе (на Android и в вебе пустой список его не выключает).
      autofillHints: null,
      keyboardType: obscure || !widget.multiline
          ? TextInputType.visiblePassword
          : TextInputType.multiline,
      textCapitalization: TextCapitalization.none,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      maxLines: obscure || !widget.multiline ? 1 : 5,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      // Пароль — моноширинным, как везде в навыке (ADR-021).
      style: monoTextStyle.copyWith(color: context.colors.textStrong),
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 5,
        errorText: widget.error,
        errorMaxLines: 3,
        suffixIcon: widget.allowShow
            ? IconButton(
                tooltip: _visible ? 'Скрыть' : 'Показать вводимое',
                icon: Icon(
                  _visible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _visible = !_visible),
              )
            : null,
      ),
    );
  }
}

/// Пароль или заметка в маске (раздел 8): обычный [Text], не
/// `SelectableText`, моноширинный, цифры и символы подкрашены. Показ —
/// пока удерживают или на [seconds] секунд по кнопке; по истечении —
/// «Пароль скрыт», строка отпущена. Семантика без значения: экранный
/// диктор слышит только «Пароль скрыт» или «Пароль показан». Озвучивания
/// нет.
///
/// Значение берётся [load] в момент показа и живёт строкой только пока
/// показано (строки Dart не затираются — сокращаем время жизни, 3.7).
class SecretRevealText extends StatefulWidget {
  const SecretRevealText({
    super.key,
    required this.load,
    required this.seconds,
    this.hide,
    this.onRevealed,
    this.kind = 'Пароль',
    this.compact = false,
  });

  /// Байты в момент показа; `null` — показ не разрешён (отменили
  /// переспрос мастер-пароля). Затираются сразу после превращения в
  /// строку.
  final Future<SecretBytes?> Function() load;

  final int seconds;

  /// Спрятать сейчас же: окно неактивно, хранилище заперто.
  final Listenable? hide;

  /// Показали впервые — в историю только факт.
  final VoidCallback? onRevealed;

  /// «Пароль» или «Заметка» — для подписи и семантики.
  final String kind;

  final bool compact;

  @override
  State<SecretRevealText> createState() => _SecretRevealTextState();
}

class _SecretRevealTextState extends State<SecretRevealText>
    with SingleTickerProviderStateMixin {
  String? _shown;
  bool _holding = false;

  /// Палец ещё на маске (удержание идёт).
  bool _pressing = false;

  /// Поколение «спрятать»: растёт при каждом сокрытии. Показ, начатый до
  /// сигнала (окно стало неактивным, пока шёл переспрос и Argon2id), свой
  /// результат отбрасывает.
  int _epoch = 0;
  bool _expired = false;
  bool _loading = false;
  bool _reported = false;
  late final AnimationController _timer = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.seconds),
  )..addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed) _conceal(expired: true);
    });

  @override
  void initState() {
    super.initState();
    widget.hide?.addListener(_onHide);
  }

  @override
  void didUpdateWidget(SecretRevealText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hide != widget.hide) {
      oldWidget.hide?.removeListener(_onHide);
      widget.hide?.addListener(_onHide);
    }
  }

  @override
  void dispose() {
    widget.hide?.removeListener(_onHide);
    _timer.dispose();
    _shown = null;
    super.dispose();
  }

  void _onHide() => _conceal();

  void _conceal({bool expired = false}) {
    if (!mounted) return;
    _epoch++;
    _timer.stop();
    setState(() {
      _shown = null;
      _holding = false;
      _expired = expired;
    });
  }

  Future<void> _reveal({required bool hold}) async {
    if (_loading) return;
    final epoch = _epoch;
    setState(() => _loading = true);
    SecretBytes? bytes;
    try {
      bytes = await widget.load();
    } on Object {
      bytes = null;
    }
    if (!mounted) {
      bytes?.wipe();
      return;
    }
    if (epoch != _epoch) {
      // Пока грузили, пришёл сигнал «спрятать»: не показываем вовсе.
      bytes?.wipe();
      setState(() => _loading = false);
      return;
    }
    // Палец отпустили, пока шёл переспрос: удержания уже нет, поэтому
    // показ — с таймером, как по кнопке (не дольше [seconds]).
    final holding = hold && _pressing;
    String? text;
    if (bytes != null) {
      try {
        text = utf8.decode(bytes.unsafeBytes, allowMalformed: true);
      } finally {
        bytes.wipe();
      }
    }
    setState(() {
      _loading = false;
      _shown = text;
      _expired = false;
      _holding = holding && text != null;
    });
    if (text == null) return;
    if (!_reported) {
      _reported = true;
      widget.onRevealed?.call();
    }
    if (!holding) {
      _timer
        ..duration = Duration(seconds: widget.seconds)
        ..forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final status = shown != null
        ? '${widget.kind} показан${widget.kind == 'Заметка' ? 'а' : ''}'
        : '${widget.kind} скрыт${widget.kind == 'Заметка' ? 'а' : ''}';
    final value = Semantics(
      label: status,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey<String>('secret-hold'),
        // Удержание — по всей строке маски, а не только по символам.
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) {
          _pressing = true;
          unawaited(_reveal(hold: true));
        },
        onLongPressEnd: (_) {
          _pressing = false;
          if (_holding) _conceal();
        },
        onLongPressCancel: () {
          _pressing = false;
          if (_holding) _conceal();
        },
        child: Container(
          // Маска — текстом в строке, без своей рамки (ADR-027).
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.centerLeft,
          child: shown == null
              ? Text(
                  _expired ? '${widget.kind}: ••••••••  (скрыт)' : '••••••••',
                  key: const ValueKey<String>('secret-masked'),
                  style: monoTextStyle.copyWith(
                    fontSize: 16,
                    letterSpacing: 2,
                    color: context.colors.muted,
                  ),
                )
              : Text.rich(
                  _colored(shown, context.colors),
                  key: const ValueKey<String>('secret-shown'),
                ),
        ),
      ),
    );
    final controls = Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        TextButton.icon(
          key: const ValueKey<String>('secret-show'),
          onPressed: _loading
              ? null
              : shown == null
                  ? () => unawaited(_reveal(hold: false))
                  : _conceal,
          icon: Icon(
            shown == null
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            size: 16,
          ),
          label: Text(
            shown == null ? 'Показать на ${widget.seconds} с' : 'Скрыть',
          ),
        ),
        if (!widget.compact) Text('или удерживайте', style: metaStyle(context)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        value,
        if (shown != null && !_holding)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: AnimatedBuilder(
              animation: _timer,
              builder: (BuildContext context, Widget? child) =>
                  LinearProgressIndicator(
                key: const ValueKey<String>('secret-timer'),
                value: 1 - _timer.value,
                minHeight: 2,
                color: context.colors.warning,
                backgroundColor: context.colors.borderSoft,
              ),
            ),
          ),
        controls,
      ],
    );
  }

  static TextSpan _colored(String text, AppPalette colors) {
    final base = monoTextStyle.copyWith(
      fontSize: 16,
      color: colors.textStrong,
    );
    final spans = <TextSpan>[];
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isLetter = char.toLowerCase() != char.toUpperCase();
      spans.add(
        TextSpan(
          text: char,
          style: isDigit
              ? base.copyWith(color: colors.liorio)
              : isLetter
                  ? base
                  : base.copyWith(color: colors.warning),
        ),
      );
    }
    return TextSpan(children: spans);
  }
}

/// Диалог «введите мастер-пароль» (переспрос для важных, ослабление
/// настроек). Возвращает `true`, если [check] принял ввод.
Future<bool> askMaster(
  BuildContext context, {
  required String title,
  required Future<bool> Function(String master) check,
  String? text,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) =>
        _MasterDialog(title: title, check: check, text: text),
  );
  return result ?? false;
}

class _MasterDialog extends StatefulWidget {
  const _MasterDialog({required this.title, required this.check, this.text});

  final String title;
  final Future<bool> Function(String master) check;
  final String? text;

  @override
  State<_MasterDialog> createState() => _MasterDialogState();
}

class _MasterDialogState extends State<_MasterDialog> {
  final TextEditingController _master = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _master
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _master.text.isEmpty) return;
    setState(() => _busy = true);
    final text = _master.text;
    _master.clear();
    final ok = await widget.check(text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = 'Мастер-пароль не подошёл.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      contentWidth: 420,
      scrollable: true,
      title: WholeWordText(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.text != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.text!),
              ),
            SecretField(
              key: const ValueKey<String>('master-dialog-field'),
              controller: _master,
              label: 'Мастер-пароль',
              error: _error,
              autofocus: true,
              enabled: !_busy,
              onSubmitted: (_) => unawaited(_submit()),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const ActionLabel('Отмена'),
        ),
        FilledButton(
          key: const ValueKey<String>('master-dialog-ok'),
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: ActionLabel(_busy ? 'Проверяю…' : 'Подтвердить'),
        ),
      ],
    );
  }
}
