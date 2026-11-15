import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/password_audit.dart';
import '../../core/passwords/password_training.dart';
import '../../core/passwords/vault_format.dart';
import '../assistant_theme.dart';
import 'entry_screens.dart';
import 'passwords_kit.dart';
import 'passwords_screen.dart';
import 'secret_widgets.dart';
import 'vault_confirm.dart';
import '../widgets/whole_word_text.dart';

/// Ответ «Проверить себя» словами (5.2). Только эти ответы — ни длины,
/// ни «насколько близко».
String recallText(RecallVerdict verdict) => switch (verdict) {
      RecallVerdict.correct => 'Верно.',
      RecallVerdict.almostLayout =>
        'Почти: похоже, набрано в другой раскладке.',
      RecallVerdict.almostCase =>
        'Почти: похоже, был включён Caps Lock или другой регистр.',
      RecallVerdict.oldOne => 'Это прежний пароль — его уже меняли.',
      RecallVerdict.wrong => 'Не совпадает.',
      RecallVerdict.limited => 'Слишком много попыток подряд. Попробуйте '
          'через 10 минут — или нажмите «Показать».',
    };

/// Скрытое поле «Проверить себя»: ввод сразу очищается, ответ — один из
/// [RecallVerdict].
class RecallField extends StatefulWidget {
  const RecallField({
    super.key,
    required this.kit,
    required this.entryId,
    required this.onVerdict,
    this.label = 'Введите пароль по памяти',
  });

  final PasswordsKit kit;
  final String entryId;
  final ValueChanged<RecallVerdict> onVerdict;
  final String label;

  @override
  State<RecallField> createState() => _RecallFieldState();
}

class _RecallFieldState extends State<RecallField> {
  final TextEditingController _input = TextEditingController();
  bool _busy = false;
  RecallVerdict? _verdict;

  @override
  void dispose() {
    _input
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final text = _input.text;
    _input.clear();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final verdict = await widget.kit.recall(widget.entryId, text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _verdict = verdict;
    });
    widget.onVerdict(verdict);
  }

  @override
  Widget build(BuildContext context) {
    final verdict = _verdict;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SecretField(
          key: const ValueKey<String>('recall-input'),
          controller: _input,
          label: widget.label,
          enabled: !_busy,
          onSubmitted: (_) => unawaited(_check()),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            FilledButton.tonal(
              key: const ValueKey<String>('recall-check'),
              onPressed: _busy ? null : () => unawaited(_check()),
              child: const Text('Проверить'),
            ),
            const SizedBox(width: 10),
            if (verdict != null)
              Expanded(
                child: Text(
                  recallText(verdict),
                  key: const ValueKey<String>('recall-verdict'),
                  style: TextStyle(
                    color: verdict == RecallVerdict.correct
                        ? context.colors.success
                        : context.colors.text,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Лестница «вспомнить, не показывая» (D27): своя подсказка → «Проверить
/// себя» → «Подсказка посильнее» (длина и классы) → «Первый символ» на
/// 15 с → «Показать». Каждая ступень — отдельной кнопкой; ответ ступени
/// не зависит от ввода. В историю — только номер ступени ([onStep]).
class HintLadder extends StatefulWidget {
  const HintLadder({
    super.key,
    required this.kit,
    required this.entry,
    required this.onStep,
    required this.reveal,
    this.copyButton,
  });

  final PasswordsKit kit;
  final VaultEntry entry;

  /// Использована ступень 2 или 3 (4 — это «пароль был показан»).
  final ValueChanged<int> onStep;

  /// Виджет показа пароля (ступень 4).
  final Widget reveal;
  final Widget? copyButton;

  @override
  State<HintLadder> createState() => _HintLadderState();
}

class _HintLadderState extends State<HintLadder> {
  PasswordsKit get kit => widget.kit;
  VaultEntry get entry => widget.entry;

  bool _checking = false;
  String? _stronger;
  bool _first = false;
  bool _revealed = false;
  bool _closed = false;
  RecallVerdict? _verdict;

  Future<void> _strongerHint() async {
    try {
      final (shape, layout) = await kit.shape(entry.id);
      if (!mounted) return;
      setState(() {
        _stronger =
            '${shape.describe()}${layout ? '. Похоже на русское слово в английской раскладке' : ''}.';
      });
      widget.onStep(2);
    } on Object {
      // Хранилище заперли — карточка сама покажет «Заперто».
    }
  }

  void _firstChar() {
    setState(() => _first = true);
    widget.onStep(3);
  }

  void _changed() => unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                EntryEditorScreen(kit: kit, id: entry.id, passwordOnly: true),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_closed) {
      return Text(
        'Готово.',
        style: TextStyle(color: context.colors.text),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          entry.hint.isEmpty ? 'Своей подсказки нет.' : entry.hint,
          key: const ValueKey<String>('secure-card-hint-text'),
          style: TextStyle(
            fontSize: 17,
            color: entry.hint.isEmpty
                ? context.colors.muted
                : context.colors.textStrong,
          ),
        ),
        if (_stronger != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'Подсказка посильнее: $_stronger',
            key: const ValueKey<String>('hint-stronger-text'),
            style: TextStyle(color: context.colors.text),
          ),
        ],
        if (_first) ...<Widget>[
          const SizedBox(height: 6),
          SecretRevealText(
            key: ValueKey<String>('hint-first-${entry.id}'),
            kind: 'Первый символ',
            compact: true,
            load: () async {
              final bytes = await loadPassword(context, kit, entry.id);
              if (bytes == null) return null;
              bytes.wipe();
              return kit.firstChar(entry.id);
            },
            seconds: 15,
            hide: kit.hideTicks,
          ),
        ],
        if (_checking) ...<Widget>[
          const SizedBox(height: 8),
          RecallField(
            kit: kit,
            entryId: entry.id,
            onVerdict: (RecallVerdict v) => setState(() => _verdict = v),
          ),
        ],
        if (_verdict == RecallVerdict.correct ||
            _verdict == RecallVerdict.wrong ||
            _verdict == RecallVerdict.oldOne)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey<String>('hint-changed'),
              onPressed: _changed,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text(
                _verdict == RecallVerdict.correct
                    ? 'Верно, но сайт не пускает — я менял пароль'
                    : 'Точно помню — я менял пароль, обновить запись',
              ),
            ),
          ),
        if (_revealed) ...<Widget>[
          const SizedBox(height: 8),
          widget.reveal,
        ],
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: <Widget>[
            TextButton.icon(
              key: const ValueKey<String>('secure-card-remembered'),
              onPressed: () => setState(() => _closed = true),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Вспомнил'),
            ),
            if (!_checking)
              TextButton.icon(
                key: const ValueKey<String>('hint-check-self'),
                onPressed: () => setState(() => _checking = true),
                icon: const Icon(Icons.quiz_outlined, size: 16),
                label: const Text('Проверить себя'),
              ),
            if (_stronger == null)
              TextButton.icon(
                key: const ValueKey<String>('hint-stronger'),
                onPressed: () => unawaited(_strongerHint()),
                icon: const Icon(Icons.lightbulb_outline, size: 16),
                label: const Text('Подсказка посильнее'),
              ),
            if (_stronger != null && !_first)
              TextButton.icon(
                key: const ValueKey<String>('hint-first'),
                onPressed: _firstChar,
                icon: const Icon(Icons.text_fields, size: 16),
                label: const Text('Первый символ'),
              ),
            if (!_revealed)
              TextButton.icon(
                key: const ValueKey<String>('secure-card-reveal'),
                onPressed: () => setState(() => _revealed = true),
                icon: const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('Показать пароль'),
              ),
            if (widget.copyButton != null) widget.copyButton!,
          ],
        ),
      ],
    );
  }
}

/// Тренировка памяти (5.8): скрытое поле, «Проверить», «Подсказка»,
/// «Сдаюсь — показать», «Не сейчас», «Больше не спрашивать». Расписание
/// меняется только у важных записей; [onOutcome] — в историю итог без
/// пароля и подсказки.
class TrainingView extends StatefulWidget {
  const TrainingView({
    super.key,
    required this.kit,
    required this.entry,
    required this.onOutcome,
    required this.reveal,
  });

  final PasswordsKit kit;
  final VaultEntry entry;
  final ValueChanged<TrainingOutcome> onOutcome;

  /// Показ пароля («Сдаюсь — показать»).
  final Widget reveal;

  @override
  State<TrainingView> createState() => _TrainingViewState();
}

class _TrainingViewState extends State<TrainingView> {
  PasswordsKit get kit => widget.kit;
  VaultEntry get entry => widget.entry;

  bool _hint = false;
  String? _stronger;
  TrainingOutcome? _done;
  String? _result;

  Future<void> _finish(TrainingOutcome outcome) async {
    if (_done != null) return;
    setState(() => _done = outcome);
    try {
      await kit.train(entry.id, outcome);
    } on Object {
      // Заперли посреди — карточка покажет «Заперто».
      return;
    }
    if (!mounted) return;
    final info = kit.facade.training(entry.id, kit.vault.clock.now());
    setState(() {
      _result = switch (outcome) {
        TrainingOutcome.correct =>
          'Верно ✓ Серия ${info?.$1 ?? 1}. Следующий раз — через '
              '${info?.$2 ?? 1} дн.',
        TrainingOutcome.helped =>
          'Верно, с подсказкой. Следующий раз — через ${info?.$2 ?? 1} дн.',
        TrainingOutcome.wrong => 'Ничего страшного — спрошу завтра.',
        TrainingOutcome.skipped => 'Хорошо, спрошу завтра.',
        TrainingOutcome.stopped => 'Больше не спрашиваю про эту запись.',
      };
    });
    widget.onOutcome(outcome);
  }

  void _onVerdict(RecallVerdict verdict) {
    if (verdict == RecallVerdict.correct) {
      unawaited(
        _finish(
          _stronger != null ? TrainingOutcome.helped : TrainingOutcome.correct,
        ),
      );
    }
  }

  Future<void> _stronger2() async {
    try {
      final (shape, _) = await kit.shape(entry.id);
      if (mounted) setState(() => _stronger = '${shape.describe()}.');
    } on Object {
      // Заперто.
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;
    return Column(
      key: const ValueKey<String>('training'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Вспомните пароль от «${entry.service}»',
          style: TextStyle(
            color: context.colors.textStrong,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (done == null) ...<Widget>[
          RecallField(
            kit: kit,
            entryId: entry.id,
            label: 'Пароль по памяти',
            onVerdict: _onVerdict,
          ),
          if (_hint)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                entry.hint.isEmpty ? 'Своей подсказки нет.' : entry.hint,
                key: const ValueKey<String>('training-hint-text'),
                style: TextStyle(color: context.colors.text),
              ),
            ),
          if (_stronger != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Подсказка посильнее: $_stronger',
                style: TextStyle(color: context.colors.text),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              if (!_hint)
                TextButton(
                  key: const ValueKey<String>('training-hint'),
                  onPressed: () => setState(() => _hint = true),
                  child: const Text('Подсказка'),
                ),
              if (_hint && _stronger == null)
                TextButton(
                  key: const ValueKey<String>('training-stronger'),
                  onPressed: () => unawaited(_stronger2()),
                  child: const Text('Подсказка посильнее'),
                ),
              TextButton(
                key: const ValueKey<String>('training-give-up'),
                onPressed: () => unawaited(_finish(TrainingOutcome.wrong)),
                child: const Text('Сдаюсь — показать'),
              ),
              TextButton(
                key: const ValueKey<String>('training-skip'),
                onPressed: () => unawaited(_finish(TrainingOutcome.skipped)),
                child: const Text('Не сейчас'),
              ),
              TextButton(
                key: const ValueKey<String>('training-stop'),
                onPressed: () => unawaited(_finish(TrainingOutcome.stopped)),
                child: const Text('Больше не спрашивать'),
              ),
            ],
          ),
        ] else ...<Widget>[
          if (_result != null)
            Text(
              _result!,
              key: const ValueKey<String>('training-result'),
              style: TextStyle(color: context.colors.text),
            ),
          if (done == TrainingOutcome.wrong) ...<Widget>[
            const SizedBox(height: 8),
            widget.reveal,
          ],
        ],
      ],
    );
  }
}

/// Группы проверки (5.5): названия только здесь, во временной карточке и
/// на экране «Проверка» — в историю идут числа (D16).
class CheckView extends StatelessWidget {
  const CheckView({super.key, required this.kit, required this.groups});

  final PasswordsKit kit;
  final CheckGroups groups;

  @override
  Widget build(BuildContext context) {
    final vault = kit.vault;
    List<VaultEntry> pick(Iterable<String> ids) => <VaultEntry>[
          for (final id in ids)
            if (vault.entry(id) case final VaultEntry e) e,
        ];
    final sections = <(String, String, List<List<VaultEntry>>)>[
      (
        'check-weak',
        'Слабые — легко подобрать',
        <List<VaultEntry>>[pick(groups.weak)],
      ),
      (
        'check-reused',
        'Один пароль в нескольких местах',
        <List<VaultEntry>>[for (final g in groups.reused) pick(g)],
      ),
      (
        'check-similar',
        'Почти одинаковые (отличаются цифрами в конце)',
        <List<VaultEntry>>[for (final g in groups.similar) pick(g)],
      ),
      (
        'check-old',
        'Давно не меняли',
        <List<VaultEntry>>[pick(groups.old)],
      ),
      (
        'check-hint',
        'Подсказка раскрывает пароль',
        <List<VaultEntry>>[pick(groups.hintLeaks)],
      ),
      (
        'check-returned',
        'Вернулись к прежнему паролю',
        <List<VaultEntry>>[pick(groups.returnedOld)],
      ),
      (
        'check-info',
        'В пароле название или логин',
        <List<VaultEntry>>[pick(groups.containsInfo)],
      ),
      (
        'check-unknown',
        'Дата смены неизвестна',
        <List<VaultEntry>>[pick(groups.unknownDate)],
      ),
    ];
    final visible = sections
        .where(
          ((String, String, List<List<VaultEntry>>) s) =>
              s.$3.any((List<VaultEntry> g) => g.isNotEmpty),
        )
        .toList();
    return Column(
      key: const ValueKey<String>('check-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Проверено записей: ${groups.total}. Утечки по базам не '
          'проверяются — только надёжность, повторы и возраст.',
          style: metaStyle(context),
        ),
        if (groups.unchecked.isNotEmpty)
          Text(
            'Ещё не оценены: ${groups.unchecked.length}.',
            style: metaStyle(context),
          ),
        // Важные записи без свежего мастер-пароля (15.2): их надёжность и
        // «название в пароле» не пересчитываются и не показываются.
        if (groups.pending.isNotEmpty)
          Text(
            'Важные записи (${groups.pending.length}) — проверка после '
            'мастер-пароля.',
            key: const ValueKey<String>('check-pending'),
            style: metaStyle(context),
          ),
        if (visible.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Замечаний нет.',
              key: ValueKey<String>('check-all-good'),
              style: TextStyle(color: context.colors.success),
            ),
          ),
        for (final (key, title, lists) in visible) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            title,
            key: ValueKey<String>(key),
            style: TextStyle(
              color: context.colors.textStrong,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final (index, list) in lists.indexed)
            if (list.isNotEmpty) ...<Widget>[
              if (lists.length > 1)
                Text('Группа ${index + 1}', style: metaStyle(context)),
              for (final entry in list)
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    void change() => unawaited(
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (BuildContext context) =>
                                  EntryEditorScreen(
                                kit: kit,
                                id: entry.id,
                                passwordOnly: true,
                              ),
                            ),
                          ),
                        );
                    final key = ValueKey<String>('check-change-${entry.id}');
                    // Узко и крупный шрифт: «Сменить» словом отняло бы
                    // место у названия записи — тогда кнопка значком.
                    final roomy =
                        lineWidth(context, 'Сменить') + 24 <= box.maxWidth * .3;
                    return EntryTile(
                      entry: entry,
                      trailing: roomy
                          ? TextButton(
                              key: key,
                              onPressed: change,
                              child: const Text('Сменить'),
                            )
                          : IconButton(
                              key: key,
                              tooltip: 'Сменить',
                              onPressed: change,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                    );
                  },
                ),
            ],
        ],
      ],
    );
  }
}

/// Экран «Проверка» из меню: полная проверка с расшифровкой по одной
/// записи.
class CheckScreen extends StatefulWidget {
  const CheckScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  CheckGroups? _groups;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.kit.addListener(_onKit);
    unawaited(_run());
  }

  @override
  void dispose() {
    widget.kit.removeListener(_onKit);
    super.dispose();
  }

  void _onKit() {
    if (!mounted) return;
    if (!widget.kit.isUnlocked) {
      closeVaultRoute(context);
      return;
    }
    setState(() => _groups = widget.kit.groups());
  }

  Future<void> _run() async {
    try {
      final groups = await widget.kit.audit();
      if (mounted) setState(() => _groups = groups);
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Мастер-пароль — и полная проверка уже с важными записями (15.2).
  Future<void> _confirm() async {
    final ok = await askVaultConfirm(
      context,
      kit: widget.kit,
      title: 'Проверить важные записи',
      text: 'Надёжность важных записей проверяется после подтверждения.',
      check: widget.kit.confirmProof,
    );
    if (ok && mounted) await _run();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      backgroundColor: context.colors.workspace,
      appBar: AppBar(
        backgroundColor: context.colors.workspace,
        title: const Text('Проверка паролей'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              if (_failed)
                const Text('Не получилось проверить. Данные не пострадали.')
              else if (groups == null)
                Text(
                  'Проверяю…',
                  style: TextStyle(color: context.colors.muted),
                )
              else ...<Widget>[
                CheckView(kit: widget.kit, groups: groups),
                if (groups.pending.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey<String>('check-confirm'),
                      onPressed: () => unawaited(_confirm()),
                      child: const Text('Проверить и важные'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Экран «Тренировка» из меню: важные записи по очереди.
class TrainingScreen extends StatefulWidget {
  const TrainingScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  String? _current;
  int _round = 0;

  @override
  void initState() {
    super.initState();
    widget.kit.addListener(_onKit);
  }

  @override
  void dispose() {
    widget.kit.removeListener(_onKit);
    super.dispose();
  }

  void _onKit() {
    if (!mounted) return;
    if (!widget.kit.isUnlocked) {
      closeVaultRoute(context);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    final now = kit.vault.clock.now();
    final queue = kit.facade.trainingQueue(now);
    final current = _current == null ? null : kit.vault.entry(_current!);
    return Scaffold(
      backgroundColor: context.colors.workspace,
      appBar: AppBar(
        backgroundColor: context.colors.workspace,
        title: const Text('Тренировка памяти'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              if (current != null) ...<Widget>[
                TrainingView(
                  key: ValueKey<String>('training-$_round'),
                  kit: kit,
                  entry: current,
                  onOutcome: (_) {},
                  reveal: SecretRevealText(
                    load: () => loadPassword(context, kit, current.id),
                    seconds: kit.revealSeconds,
                    hide: kit.hideTicks,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _current = null),
                  child: const Text('К списку'),
                ),
              ] else if (queue.isEmpty)
                Text(
                  'Тренировать пока нечего. Отметьте важные записи — почту, '
                  'банк, Госуслуги — переключателем «Важный» в редакторе.',
                  key: ValueKey<String>('training-empty'),
                  style: TextStyle(color: context.colors.text),
                )
              else ...<Widget>[
                Text(
                  'Интервалы: 1 → 3 → 7 → 14 → 30 → 60 → 120 дней. Ошибка — '
                  'снова через день.',
                  style: metaStyle(context),
                ),
                for (final ref in queue)
                  if (kit.vault.entry(ref.id) case final VaultEntry entry)
                    EntryTile(
                      entry: entry,
                      trailing: Text(
                        TrainingSchedule.isDue(entry.train, now)
                            ? 'пора'
                            : 'через '
                                '${TrainingSchedule.daysUntil(entry.train, now)} '
                                'дн.',
                        style: metaStyle(context),
                      ),
                      onTap: () => setState(() {
                        _current = entry.id;
                        _round++;
                      }),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
