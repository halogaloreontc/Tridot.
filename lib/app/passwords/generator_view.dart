import '../shell/drawer_swipe.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/password_generator.dart';
import '../../core/passwords/secret_bytes.dart';
import '../assistant_theme.dart';
import 'entry_screens.dart';
import 'passwords_kit.dart';
import 'passwords_screen.dart';
import 'secret_widgets.dart';
import '../widgets/whole_word_text.dart';

/// Генератор паролей (5.4): режим «слова» (только английский словарь EFF
/// large, решение владельца №6) и «символы». Значение — только
/// [SecretBytes]: в маске, показ удержанием или на 15 с; живёт до
/// сохранения или [lifetime], затем затирается. В чат не попадает.
///
/// [onUse] — редактор записи: «Использовать» отдаёт копию байтов (её
/// затирает получатель). Без него (карточка в чате, экран генератора) —
/// «Сохранить для…»: редактор новой записи с этим паролем.
class GeneratorPanel extends StatefulWidget {
  const GeneratorPanel({
    super.key,
    required this.kit,
    this.initial = const GeneratorOptions(),
    this.onUse,
    this.lifetime = const Duration(seconds: 60),
  });

  final PasswordsKit kit;
  final GeneratorOptions initial;
  final void Function(SecretBytes value, GeneratorOptions options)? onUse;
  final Duration lifetime;

  @override
  State<GeneratorPanel> createState() => _GeneratorPanelState();
}

class _GeneratorPanelState extends State<GeneratorPanel> {
  PasswordsKit get kit => widget.kit;

  late GeneratorOptions _options;
  GeneratedPassword? _current;
  Timer? _expiry;
  int _generation = 0;

  /// Значения нет: вышло время или пароль ушёл в редактор («Сохранить
  /// для…»). Тогда вместо маски — пояснение и «Ещё».
  _Gone _gone = _Gone.no;

  @override
  void initState() {
    super.initState();
    _options = widget.initial;
    _generate();
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _current?.wipe();
    super.dispose();
  }

  bool get _wordsReady => kit.wordlists.hasEff;

  void _generate() {
    var options = _options.normalized();
    // Словарь не загрузился — честно на символы.
    if (options.mode == GeneratorMode.words && !_wordsReady) {
      options = options.copyWith(mode: GeneratorMode.characters);
    }
    _current?.wipe();
    _current = kit.generator.generate(options);
    _options = options;
    _generation++;
    _gone = _Gone.no;
    _expiry?.cancel();
    _expiry = Timer(widget.lifetime, _expire);
  }

  void _expire() {
    if (!mounted) return;
    setState(() {
      _current?.wipe();
      _current = null;
      _gone = _Gone.expired;
    });
  }

  void _change(GeneratorOptions options) {
    setState(() {
      _options = options;
      _generate();
    });
  }

  Future<SecretBytes?> _load() async {
    final current = _current;
    if (current == null || current.value.isWiped) return null;
    return current.value.clone();
  }

  Future<void> _use() async {
    final current = _current;
    if (current == null) return;
    final onUse = widget.onUse;
    if (onUse != null) {
      onUse(current.value.clone(), current.options);
      return;
    }
    // «Сохранить для…»: хранилище нужно только здесь.
    if (!kit.isUnlocked) {
      final opened = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (BuildContext context) =>
              PasswordsScreen(kit: kit, unlockOnly: true),
        ),
      );
      if (!mounted || !(opened ?? false) || !kit.isUnlocked) return;
    }
    final value = _current;
    if (value == null) return;
    final copy = value.value.clone();
    final options = value.options;
    setState(() {
      _current?.wipe();
      _current = null;
      _expiry?.cancel();
      _gone = _Gone.used;
    });
    if (!mounted) {
      copy.wipe();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => EntryEditorScreen(
          kit: kit,
          generated: copy,
          structureHint: options.structureHint,
        ),
      ),
    );
  }

  Future<void> _copy() async {
    final current = _current;
    if (current == null) return;
    await kit.clipboard.copySecret(
      current.value.clone(),
      Duration(seconds: kit.clipboardSeconds),
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Скопировано. Очистится через ${kit.clipboardSeconds} с.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _options;
    final words = o.mode == GeneratorMode.words;
    final bits = o.bits.floor();
    final score = StrengthScale.scoreOf(o.bits);
    return Column(
      key: const ValueKey<String>('generator'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Переключатель режима — чипами: при крупном шрифте на узком
        // экране они переносятся целиком, а не рвут слово («Символ/ы»).
        Wrap(
          key: const ValueKey<String>('generator-mode'),
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            ChoiceChip(
              key: const ValueKey<String>('generator-mode-words'),
              label: const Text('Из слов'),
              selected: words,
              onSelected: _wordsReady
                  ? (bool _) => _change(o.copyWith(mode: GeneratorMode.words))
                  : null,
            ),
            ChoiceChip(
              key: const ValueKey<String>('generator-mode-characters'),
              label: const Text('Символы'),
              selected: !words,
              onSelected: (bool _) =>
                  _change(o.copyWith(mode: GeneratorMode.characters)),
            ),
          ],
        ),
        if (!_wordsReady)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Словарь слов не загрузился — доступен пароль из символов.',
              style: metaTextStyle,
            ),
          ),
        const SizedBox(height: 10),
        if (_gone == _Gone.expired)
          const Text(
            'Время вышло — пароль стёрт. Нажмите «Ещё», чтобы получить новый.',
            key: ValueKey<String>('generator-expired'),
            style: TextStyle(color: AssistantColors.muted),
          )
        else if (_gone == _Gone.used)
          const Text(
            'Пароль передан в редактор и здесь стёрт. Если запись не '
            'сохранили — нажмите «Ещё», чтобы получить новый.',
            key: ValueKey<String>('generator-used'),
            style: TextStyle(color: AssistantColors.muted),
          )
        else
          SecretRevealText(
            key: ValueKey<String>('generator-value-$_generation'),
            load: _load,
            seconds: kit.revealSeconds,
            hide: kit.hideTicks,
          ),
        const SizedBox(height: 6),
        Text(
          '~$bits бит · надёжность ${StrengthScale.label(score)}',
          key: const ValueKey<String>('generator-bits'),
          style: const TextStyle(color: AssistantColors.text),
        ),
        Text(
          'Подсказка по структуре: ${o.structureHint}. Она не снижает '
          'стойкость: биты посчитаны так, будто устройство пароля известно. '
          'Допишите к ней своё — то, что напомнит именно вам.',
          key: const ValueKey<String>('generator-structure'),
          style: metaTextStyle,
        ),
        const SizedBox(height: 6),
        if (words) ..._wordControls(o) else ..._charControls(o),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            OutlinedButton.icon(
              key: const ValueKey<String>('generator-again'),
              onPressed: () => setState(_generate),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Ещё'),
            ),
            FilledButton.icon(
              key: const ValueKey<String>('generator-use'),
              onPressed: _current == null ? null : () => unawaited(_use()),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(
                widget.onUse == null ? 'Сохранить для…' : 'Использовать',
              ),
            ),
            if (kit.canCopySecrets && widget.onUse == null)
              TextButton.icon(
                key: const ValueKey<String>('generator-copy'),
                onPressed: _current == null ? null : () => unawaited(_copy()),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Скопировать'),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _wordControls(GeneratorOptions o) => <Widget>[
        _Stepper(
          key: const ValueKey<String>('generator-words'),
          label: 'Слов: ${o.words}',
          onMinus: o.words > GeneratorOptions.minWords
              ? () => _change(o.copyWith(words: o.words - 1))
              : null,
          onPlus: o.words < GeneratorOptions.maxWords
              ? () => _change(o.copyWith(words: o.words + 1))
              : null,
        ),
        // Подпись над списком, список — на всю ширину с многоточием: при
        // крупном шрифте на узком экране ничего не уходит за край.
        const Text('Разделитель', style: metaTextStyle),
        DropdownButton<String>(
          key: const ValueKey<String>('generator-separator'),
          isExpanded: true,
          value: o.separator,
          dropdownColor: AssistantColors.raised,
          items: <DropdownMenuItem<String>>[
            for (final sep in GeneratorOptions.separators)
              DropdownMenuItem<String>(
                value: sep,
                child: Text(
                  switch (sep) {
                    '-' => 'дефис',
                    '.' => 'точка',
                    '_' => 'подчёркивание',
                    ' ' => 'пробел',
                    _ => 'слитно',
                  },
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (String? v) =>
              v == null ? null : _change(o.copyWith(separator: v)),
        ),
        SwitchListTile(
          key: const ValueKey<String>('generator-capital'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: o.capital,
          onChanged: (bool v) => _change(o.copyWith(capital: v)),
          title: const WholeWordText('Одно слово с заглавной'),
        ),
        _Stepper(
          key: const ValueKey<String>('generator-digits'),
          label: 'Цифр в конце: ${o.digitCount}',
          onMinus: o.digitCount > 0
              ? () => _change(o.copyWith(digitCount: o.digitCount - 1))
              : null,
          onPlus: o.digitCount < 4
              ? () => _change(o.copyWith(digitCount: o.digitCount + 1))
              : null,
        ),
      ];

  List<Widget> _charControls(GeneratorOptions o) => <Widget>[
        Text('Длина: ${o.length}', style: metaTextStyle),
        // Ползунок тянут вбок: этот жест — его, а не свайп меню.
        DrawerSwipeBlocker(
          child: Slider(
            key: const ValueKey<String>('generator-length'),
            value: o.length.toDouble(),
            min: GeneratorOptions.minLength.toDouble(),
            max: GeneratorOptions.maxLength.toDouble(),
            divisions: GeneratorOptions.maxLength - GeneratorOptions.minLength,
            label: '${o.length}',
            onChanged: (double v) => _change(o.copyWith(length: v.round())),
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: <Widget>[
            _chip(
              'generator-lower',
              'строчные',
              o.lower,
              (bool v) => o.copyWith(lower: v),
            ),
            _chip(
              'generator-upper',
              'прописные',
              o.upper,
              (bool v) => o.copyWith(upper: v),
            ),
            _chip(
              'generator-digits-class',
              'цифры',
              o.digits,
              (bool v) => o.copyWith(digits: v),
            ),
            _chip(
              'generator-symbols',
              'символы',
              o.symbols,
              (bool v) => o.copyWith(symbols: v),
            ),
            _chip(
              'generator-look-alike',
              'без похожих (0O1lI)',
              o.noLookAlike,
              (bool v) => o.copyWith(noLookAlike: v),
            ),
          ],
        ),
      ];

  Widget _chip(
    String key,
    String label,
    bool value,
    GeneratorOptions Function(bool) next,
  ) =>
      FilterChip(
        key: ValueKey<String>(key),
        // Подпись в одну строку целиком: на узком экране с крупным
        // шрифтом уменьшается, а не срезается краем (ADR-021).
        label: fitSingleWord(label),
        selected: value,
        onSelected: (bool v) => _change(next(v)),
      );
}

enum _Gone { no, expired, used }

class _Stepper extends StatelessWidget {
  const _Stepper({
    super.key,
    required this.label,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: AssistantColors.text),
          ),
        ),
        IconButton(
          tooltip: 'Меньше',
          onPressed: onMinus,
          icon: const Icon(Icons.remove, size: 18),
        ),
        IconButton(
          tooltip: 'Больше',
          onPressed: onPlus,
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    );
  }
}

/// Экран «Генератор» из меню «Пароли».
class GeneratorScreen extends StatelessWidget {
  const GeneratorScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(
        backgroundColor: AssistantColors.workspace,
        title: const Text('Генератор паролей'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[GeneratorPanel(kit: kit)],
          ),
        ),
      ),
    );
  }
}

/// Генератор поверх редактора: «Использовать» подставляет пароль в поле.
Future<(SecretBytes, GeneratorOptions)?> pickGenerated(
  BuildContext context,
  PasswordsKit kit,
) {
  return showModalBottomSheet<(SecretBytes, GeneratorOptions)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AssistantColors.raised,
    builder: (BuildContext context) => SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: GeneratorPanel(
          kit: kit,
          initial: const GeneratorOptions(mode: GeneratorMode.words),
          onUse: (SecretBytes value, GeneratorOptions options) =>
              Navigator.of(context).pop((value, options)),
        ),
      ),
    ),
  );
}
