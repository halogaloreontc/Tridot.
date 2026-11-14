import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/passwords/hint_guard.dart';
import '../../core/passwords/password_strength.dart';
import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../../core/passwords/vault_prefs.dart';
import '../assistant_theme.dart';
import 'generator_view.dart';
import 'passwords_kit.dart';
import 'secret_widgets.dart';

/// Закрывает экран, как только хранилище заперли (3.6: экраны хранилища
/// закрываются, поля очищаются).
mixin _ClosesOnLock<T extends StatefulWidget> on State<T> {
  PasswordsKit get kit;

  void startWatching() => kit.addListener(_onKit);

  void stopWatching() => kit.removeListener(_onKit);

  void _onKit() {
    if (!mounted) return;
    if (!kit.isUnlocked) {
      onLocked();
      closeVaultRoute(context);
      return;
    }
    setState(() {});
  }

  /// Очистить поля до закрытия.
  void onLocked() {}
}

/// Закрыть экран хранилища [context] при запирании (3.6) вместе со всем,
/// что открыто поверх него (диалог удаления, переспрос мастер-пароля):
/// одного `maybePop` мало — он закрыл бы только диалог, а экран с логином
/// и кнопками остался бы на виду.
void closeVaultRoute(BuildContext context) {
  final route = ModalRoute.of(context);
  final navigator = Navigator.maybeOf(context);
  if (route == null || navigator == null) return;
  // Экран уже закрывается (его закрыл экран ниже) — ничего не трогаем.
  if (!route.isActive || route.isFirst) return;
  navigator.popUntil((Route<dynamic> r) => r == route || r.isFirst);
  if (!route.isActive) return;
  if (route.isCurrent) {
    navigator.pop();
  } else {
    navigator.removeRoute(route);
  }
}

/// Свежее подтверждение для важной записи [id] при включённом переспросе:
/// мастер-пароль, если подтверждали больше минуты назад (3.6). `false` —
/// отменили или не подошёл.
Future<bool> _reprompt(
  BuildContext context,
  PasswordsKit kit,
  String id,
) async {
  if (!kit.needsReprompt(id)) return true;
  return askMaster(
    context,
    title: 'Важная запись',
    text: 'Для важных записей показ и копирование подтверждаются '
        'мастер-паролем.',
    check: kit.confirm,
  );
}

/// Удаление важной записи [id] (3.6): при включённом переспросе —
/// мастер-пароль, если подтверждали больше минуты назад. `false` —
/// отменили или не подошёл. Запас [PasswordsKit.saveMargin]: окно не
/// должно кончиться между подтверждением и удалением.
Future<bool> confirmDelete(
  BuildContext context,
  PasswordsKit kit,
  String id, {
  String title = 'Удалить важную запись',
  String text = 'Удаление важной записи подтверждается мастер-паролем.',
}) async {
  if (!kit.needsReprompt(id, margin: PasswordsKit.saveMargin)) return true;
  return askMaster(context, title: title, text: text, check: kit.confirm);
}

/// Пароль записи для показа: важная запись при включённом переспросе
/// требует мастер-пароль, если подтверждали больше минуты назад (3.6).
Future<SecretBytes?> loadPassword(
  BuildContext context,
  PasswordsKit kit,
  String id,
) async {
  if (!await _reprompt(context, kit, id)) return null;
  return kit.password(id);
}

/// Заметка записи для показа: тот же переспрос, что у пароля, — в
/// заметке важной записи обычно коды восстановления и PIN.
Future<SecretBytes?> loadNote(
  BuildContext context,
  PasswordsKit kit,
  String id,
) async {
  if (!await _reprompt(context, kit, id)) return null;
  return kit.note(id);
}

/// Прежний пароль [historyId] записи [id] для показа (ADR-015): тот же
/// переспрос мастер-пароля для важной записи, что у текущего пароля.
Future<SecretBytes?> loadHistoryPassword(
  BuildContext context,
  PasswordsKit kit,
  String id,
  String historyId,
) async {
  if (!await _reprompt(context, kit, id)) return null;
  return kit.historyPassword(id, historyId);
}

/// Скопировать пароль записи [id]: переспрос для важной, тост.
Future<bool> copyPassword(
  BuildContext context,
  PasswordsKit kit,
  String id,
) async {
  if (!kit.canCopySecrets) return false;
  if (!await _reprompt(context, kit, id)) return false;
  try {
    await kit.copyPassword(id);
  } on Object {
    return false;
  }
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Скопировано. Очистится через ${kit.clipboardSeconds} с.',
        ),
      ),
    );
  }
  return true;
}

/// Карточка записи (раздел 8).
class EntryScreen extends StatefulWidget {
  const EntryScreen({
    super.key,
    required this.kit,
    required this.id,
    this.now = DateTime.now,
  });

  final PasswordsKit kit;
  final String id;
  final DateTime Function() now;

  @override
  State<EntryScreen> createState() => _EntryScreenState();
}

class _EntryScreenState extends State<EntryScreen>
    with _ClosesOnLock<EntryScreen> {
  @override
  PasswordsKit get kit => widget.kit;

  @override
  void initState() {
    super.initState();
    startWatching();
  }

  @override
  void dispose() {
    stopWatching();
    super.dispose();
  }

  Future<void> _delete(VaultEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        backgroundColor: AssistantColors.raised,
        title: Text('Удалить «${entry.service}»?'),
        content: const Text(
          'Вернуть запись можно будет только из резервной копии.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('entry-delete-confirm'),
            style:
                TextButton.styleFrom(foregroundColor: AssistantColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    // Удаление важной записи — необратимое действие: при включённом
    // переспросе только после мастер-пароля (3.6), иначе хранилище
    // откажет.
    if (!await confirmDelete(context, kit, entry.id) || !mounted) return;
    try {
      await kit.vault.deleteEntry(entry.id);
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не получилось удалить запись.')),
      );
    }
  }

  /// Удалить из хронологии прежний пароль [meta] записи [entry] (`null` —
  /// всю хронологию записи): подтверждение, для важной записи —
  /// мастер-пароль.
  Future<void> _dropHistory(VaultEntry entry, HistoryMeta? meta) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        backgroundColor: AssistantColors.raised,
        title: Text(
          meta == null
              ? 'Очистить хронологию «${entry.service}»?'
              : 'Удалить этот пароль из хронологии?',
        ),
        content: const Text(
          'Вернуть можно только из резервной копии. В отложенных архивах '
          'сейфа (после «Заменить всё» или «Отложить сейф в архив») '
          'прежний пароль остаётся.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('entry-history-confirm'),
            style:
                TextButton.styleFrom(foregroundColor: AssistantColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(meta == null ? 'Очистить' : 'Удалить'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    // Важная запись: удаляется не она, а прежний пароль — так и
    // спрашиваем.
    if (!await confirmDelete(
          context,
          kit,
          entry.id,
          title:
              meta == null ? 'Очистить хронологию' : 'Удалить прежний пароль',
          text: 'У важной записи правка хронологии подтверждается '
              'мастер-паролем.',
        ) ||
        !mounted) {
      return;
    }
    final ok = meta == null
        ? await kit.clearHistory(entry.id)
        : await kit.deleteHistory(entry.id, meta.id);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не получилось удалить.')),
      );
    }
  }

  /// «Прежние пароли (N)» (ADR-015): только если хронология включена или
  /// в записи что-то сохранено.
  Widget _history(VaultEntry entry) {
    final items = entry.history;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: ExpansionTile(
        key: const ValueKey<String>('entry-history'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'Прежние пароли (${items.length})',
          style: metaTextStyle,
        ),
        children: <Widget>[
          if (items.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Пока пусто: прежний пароль появится здесь после смены.',
                style: TextStyle(color: AssistantColors.muted),
              ),
            ),
          if (!kit.historyEnabled && items.isNotEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Хронология выключена: при смене пароля старый больше не '
                'сохраняется.',
                style: metaTextStyle,
              ),
            ),
          for (final meta in items)
            Padding(
              key: ValueKey<String>('entry-history-${meta.id}'),
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          historyPeriodText(meta),
                          style: metaTextStyle,
                        ),
                        if (meta.looksLikeTypo)
                          const Text(
                            'Использовался меньше часа — похоже на опечатку.',
                            style: TextStyle(color: AssistantColors.warning),
                          ),
                        SecretRevealText(
                          key: ValueKey<String>('entry-history-reveal-'
                              '${meta.id}'),
                          load: () => loadHistoryPassword(
                            context,
                            kit,
                            entry.id,
                            meta.id,
                          ),
                          seconds: kit.revealSeconds,
                          hide: kit.hideTicks,
                          kind: 'Прежний пароль',
                          compact: true,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: ValueKey<String>('entry-history-delete-${meta.id}'),
                    tooltip: 'Удалить из хронологии',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => unawaited(_dropHistory(entry, meta)),
                  ),
                ],
              ),
            ),
          if (items.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey<String>('entry-history-clear'),
                style: TextButton.styleFrom(
                  foregroundColor: AssistantColors.danger,
                ),
                onPressed: () => unawaited(_dropHistory(entry, null)),
                child: const Text('Очистить хронологию'),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = kit.vault.entry(widget.id);
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(
        backgroundColor: AssistantColors.workspace,
        title: Text(entry?.service ?? 'Запись'),
      ),
      body: entry == null
          ? const Center(
              child: Text(
                'Этой записи уже нет.',
                style: TextStyle(color: AssistantColors.muted),
              ),
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: <Widget>[
                    for (final url in entry.urls)
                      _Field(
                        label: 'Адрес',
                        child: Text(
                          VaultFacade.hostOf(url),
                          style: const TextStyle(color: AssistantColors.text),
                        ),
                      ),
                    if (entry.login.isNotEmpty)
                      _Field(
                        label: 'Логин',
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                entry.login,
                                key: const ValueKey<String>('entry-login'),
                                style: const TextStyle(
                                  color: AssistantColors.textStrong,
                                ),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey<String>('entry-copy-login'),
                              tooltip: 'Скопировать логин',
                              icon: const Icon(Icons.copy_outlined, size: 18),
                              onPressed: () => fireAndForget(
                                kit.clipboard.copyText(entry.login),
                              ),
                            ),
                          ],
                        ),
                      ),
                    _Field(
                      label: 'Пароль',
                      child: SecretRevealText(
                        key: ValueKey<String>('entry-password-${entry.id}'),
                        load: () => loadPassword(context, kit, entry.id),
                        seconds: kit.revealSeconds,
                        hide: kit.hideTicks,
                      ),
                    ),
                    if (kit.canCopySecrets)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          key: const ValueKey<String>('entry-copy-password'),
                          onPressed: () => fireAndForget(
                            copyPassword(context, kit, entry.id),
                          ),
                          icon: const Icon(Icons.copy_outlined, size: 16),
                          label: Text(
                            'Скопировать — очистится через '
                            '${kit.clipboardSeconds} с',
                          ),
                        ),
                      )
                    else
                      Text(
                        kit.platform.copyNote ?? '',
                        key: const ValueKey<String>('entry-copy-note'),
                        style: metaTextStyle,
                      ),
                    if (kit.historyEnabled || entry.history.isNotEmpty)
                      _history(entry),
                    _Field(
                      label: 'Подсказка',
                      child: Text(
                        entry.hint.isEmpty ? 'Нет подсказки' : entry.hint,
                        style: TextStyle(
                          color: entry.hint.isEmpty
                              ? AssistantColors.muted
                              : AssistantColors.text,
                        ),
                      ),
                    ),
                    _Field(
                      label: 'Заметка',
                      child: SecretRevealText(
                        key: ValueKey<String>('entry-note-${entry.id}'),
                        load: () => loadNote(context, kit, entry.id),
                        seconds: kit.revealSeconds,
                        hide: kit.hideTicks,
                        kind: 'Заметка',
                        compact: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (entry.important)
                          const Chip(
                            avatar: Icon(Icons.star_outline, size: 16),
                            label: Text('Важный'),
                          ),
                        Text(
                          'Изменён ${agoText(entry.changed, widget.now())}',
                          style: metaTextStyle,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          key: const ValueKey<String>('entry-edit'),
                          onPressed: () => unawaited(
                            Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    EntryEditorScreen(kit: kit, id: entry.id),
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: const Text('Изменить'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey<String>('entry-delete'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AssistantColors.danger,
                          ),
                          onPressed: () => unawaited(_delete(entry)),
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('Удалить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Дата «12.11.2026» (местное время).
String dayText(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}';
}

/// Когда стоял прежний пароль: «с 10.11.2026 по 12.11.2026»; в один
/// день — со временем: «10.11.2026, 09:00–09:10»; дата начала неизвестна
/// (CSV без дат) — только «до 12.11.2026».
String historyPeriodText(HistoryMeta meta) {
  if (meta.src == DateSource.unknown) return 'до ${dayText(meta.to)}';
  final from = meta.from.toLocal();
  final to = meta.to.toLocal();
  if (from.year == to.year && from.month == to.month && from.day == to.day) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dayText(from)}, ${two(from.hour)}:${two(from.minute)}–'
        '${two(to.hour)}:${two(to.minute)}';
  }
  return 'с ${dayText(from)} по ${dayText(to)}';
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(label, style: metaTextStyle),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

/// Редактор записи (раздел 5.3): новая запись или правка. Пароль — только
/// в скрытом поле; значение из чата не берётся никогда.
class EntryEditorScreen extends StatefulWidget {
  const EntryEditorScreen({
    super.key,
    required this.kit,
    this.id,
    this.service,
    this.passwordOnly = false,
    this.generated,
    this.structureHint,
  });

  final PasswordsKit kit;

  /// Пароль из генератора («Сохранить для…»): редактор забирает байты и
  /// затирает их, значение живёт только в поле.
  final SecretBytes? generated;

  /// Подсказка по структуре сгенерированного пароля (5.4).
  final String? structureHint;

  /// Запись для правки; `null` — новая.
  final String? id;

  /// Название новой записи из фразы («запомни пароль от озона»).
  final String? service;

  /// «Смени пароль от почты»: сразу к полю пароля.
  final bool passwordOnly;

  @override
  State<EntryEditorScreen> createState() => _EntryEditorScreenState();
}

class _EntryEditorScreenState extends State<EntryEditorScreen>
    with _ClosesOnLock<EntryEditorScreen> {
  @override
  PasswordsKit get kit => widget.kit;

  late final TextEditingController _service;
  late final TextEditingController _urls;
  late final TextEditingController _login;
  final TextEditingController _password = TextEditingController();
  late final TextEditingController _hint;
  final TextEditingController _note = TextEditingController();
  bool _important = false;
  bool _busy = false;
  String? _serviceError;
  String? _passwordError;
  String? _hintError;
  String? _repeatWarning;
  String? _failure;

  /// Живая оценка надёжности под полем пароля.
  String? _strength;

  /// Оценка — не на каждое нажатие, а после паузы [_rateDelay]: длинный
  /// пароль разбирается заметное время.
  Timer? _rateTimer;
  static const Duration _rateDelay = Duration(milliseconds: 250);

  /// Подсказка по структуре из генератора.
  String? _structure;

  /// Подсказку с предупреждением [HintGuard] уже показывали — второй
  /// «Сохранить» сохраняет.
  String? _warnedHint;

  /// Пароль, о повторе которого уже предупредили при сохранении.
  String? _warnedRepeat;

  @override
  void initState() {
    super.initState();
    final entry = widget.id == null ? null : kit.vault.entry(widget.id!);
    _service = TextEditingController(
      text: entry?.service ?? _title(widget.service ?? ''),
    );
    _urls = TextEditingController(text: entry?.urls.join('\n') ?? '');
    _login = TextEditingController(text: entry?.login ?? '');
    _hint = TextEditingController(text: entry?.hint ?? '');
    _important = entry?.important ?? false;
    final generated = widget.generated;
    if (generated != null && !generated.isWiped) {
      _password.text = utf8.decode(generated.unsafeBytes, allowMalformed: true);
      generated.wipe();
      _structure = widget.structureHint;
      _rate(_password.text);
    }
    startWatching();
  }

  /// Оценить [_password] после паузы в наборе (пустой — сразу).
  void _rateLater(String value) {
    _rateTimer?.cancel();
    _rateTimer = null;
    if (value.isEmpty) {
      _strength = null;
      return;
    }
    _rateTimer = Timer(_rateDelay, () {
      _rateTimer = null;
      if (!mounted) return;
      setState(() => _rate(_password.text));
    });
  }

  void _rate(String value) {
    if (value.isEmpty) {
      _strength = null;
      return;
    }
    final estimate = kit.estimate(
      value,
      userInputs: <String>[_service.text, _login.text, _urls.text],
    );
    _strength = 'Надёжность: ${estimate.label} (~${estimate.bits.floor()} '
        'бит)${estimate.score <= 2 ? '. ${_why(estimate)}' : ''}';
  }

  static String _why(StrengthEstimate estimate) {
    final r = estimate.reasons;
    if (r.contains(StrengthReason.common)) return 'Это частый пароль.';
    if (r.contains(StrengthReason.userInput)) {
      return 'В нём название или логин.';
    }
    if (r.contains(StrengthReason.russianLayout)) {
      return 'Русское слово в английской раскладке подбирают первым.';
    }
    if (r.contains(StrengthReason.keyboard)) return 'Соседние клавиши.';
    if (r.contains(StrengthReason.date)) return 'В нём год или дата.';
    if (r.contains(StrengthReason.short)) return 'Слишком короткий.';
    return 'Его легко подобрать.';
  }

  Future<void> _generate() async {
    final picked = await pickGenerated(context, kit);
    if (picked == null || !mounted) {
      picked?.$1.wipe();
      return;
    }
    final (value, options) = picked;
    final text = utf8.decode(value.unsafeBytes, allowMalformed: true);
    value.wipe();
    setState(() {
      _password.text = text;
      _structure = options.structureHint;
      _rate(text);
    });
    _checkRepeat(text);
    // Сгенерированное оценено сразу — ждать паузы незачем.
    _rateTimer?.cancel();
    _rateTimer = null;
  }

  static String _title(String text) => text.isEmpty
      ? text
      : text.substring(0, 1).toUpperCase() + text.substring(1);

  @override
  void onLocked() => _clear();

  void _clear() {
    _rateTimer?.cancel();
    _rateTimer = null;
    _password.clear();
    _note.clear();
    _warnedRepeat = null;
  }

  @override
  void dispose() {
    stopWatching();
    _clear();
    for (final c in <TextEditingController>[
      _service,
      _urls,
      _login,
      _password,
      _hint,
      _note,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isNew => widget.id == null;

  void _checkRepeat(String value) {
    final same = kit.sameAs(value, except: widget.id);
    setState(() {
      _rateLater(value);
      _repeatWarning = _repeatText(same);
    });
  }

  static String? _repeatText(List<VaultEntry> same) => same.isEmpty
      ? null
      : 'Этот пароль уже используется для: '
          '${same.map((VaultEntry e) => e.service).join(', ')}.';

  /// Поля редактора отличаются от записи [entry].
  bool _changed(VaultEntry entry, String service, String hint) {
    final urls = <String>[
      for (final line in _urls.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    return service != entry.service ||
        hint != entry.hint ||
        _login.text.trim() != entry.login ||
        urls.join('\n') != entry.urls.join('\n') ||
        _important != entry.important ||
        _password.text.isNotEmpty ||
        _note.text.isNotEmpty;
  }

  Future<void> _save() async {
    final service = _service.text.trim();
    final password = _password.text;
    final hint = _hint.text.trim();
    setState(() {
      _serviceError = service.isEmpty ? 'Как назвать запись?' : null;
      _passwordError =
          _isNew && password.isEmpty ? 'Без пароля запись не сохранить.' : null;
      _hintError = null;
      _failure = null;
    });
    if (_serviceError != null || _passwordError != null) return;
    final previous = widget.id == null ? null : kit.vault.entry(widget.id!);
    // Правка охраняемой важной записи (15.2) — только после мастер-пароля:
    // новое название, логин или адрес сверяются с куском её пароля (флаги
    // «в пароле название или логин», оценка), новая подсказка — с самим
    // паролем. Без переспроса это оракул по подстрокам без предела.
    // «Снять «Важный»» спрашивает мастер-пароль сам — второй раз не нужно.
    final dropping = previous != null &&
        previous.important &&
        !_important &&
        VaultPrefs.repromptImportant.of(kit.vault.prefs);
    // Запас [PasswordsKit.saveMargin]: окно подтверждения не должно
    // кончиться, пока идут проверки и запись.
    if (previous != null &&
        !dropping &&
        _changed(previous, service, hint) &&
        kit.needsReprompt(previous.id, margin: PasswordsKit.saveMargin)) {
      final ok = await askMaster(
        context,
        title: 'Важная запись',
        text: 'Правка важной записи подтверждается мастер-паролем.',
        check: kit.confirm,
      );
      if (!mounted) return;
      if (!ok) {
        setState(
          () => _failure = 'Не сохранено: для важной записи нужен '
              'мастер-пароль.',
        );
        return;
      }
    }
    // HintGuard (5.3): кусок пароля с учётом регистра, раскладки,
    // транслита и l33t, пароль другой записи — запрет; слово фразы —
    // предупреждение (второй «Сохранить» сохраняет).
    // Прежнюю подсказку при прежнем пароле не перепроверяем: её отметит
    // «Проверка» (флаг «подсказка раскрывает пароль»).
    // Повтор пароля с важными записями сообщается только здесь (живое
    // предупреждение их не сравнивает, 15.2): показать один раз, второй
    // «Сохранить» сохраняет.
    final review = previous != null && previous.hint == hint && password.isEmpty
        ? SaveReview.fine
        : await kit.reviewSave(hint, password, id: widget.id);
    if (!mounted) return;
    final verdict = review.hint;
    if (verdict.block == HintProblem.needsConfirm) {
      setState(() => _hintError = verdict.message);
      final ok = await askMaster(
        context,
        title: 'Проверить подсказку',
        text: 'Без мастер-пароля подсказку больше не сверить с паролями '
            'важных записей. Подтвердите — и сохраните ещё раз.',
        check: kit.confirm,
      );
      if (!mounted || !ok) return;
      return _save();
    }
    if (!verdict.ok || (verdict.warning != null && _warnedHint != hint)) {
      setState(() {
        _hintError = verdict.message;
        if (verdict.ok) _warnedHint = hint;
      });
      return;
    }
    final repeat = _repeatText(review.same);
    if (repeat != null &&
        repeat != _repeatWarning &&
        _warnedRepeat != password) {
      setState(() {
        _repeatWarning = repeat;
        _warnedRepeat = password;
      });
      return;
    }
    final id = widget.id;
    final before = id == null ? null : kit.vault.entry(id);
    final urls = <String>[
      for (final line in _urls.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final login = _login.text.trim();
    final note = _note.text;
    if (id != null &&
        before != null &&
        before.important &&
        !_important &&
        VaultPrefs.repromptImportant.of(kit.vault.prefs)) {
      // Снять «Важный» — ослабить защиту (3.6, 15.2): как и выключение
      // переспроса в настройках, только с мастер-паролем. Мастер-пароль
      // проверяется той же операцией, что сохраняет правку: всё или
      // ничего.
      setState(() => _busy = true);
      String? failure;
      final ok = await askMaster(
        context,
        title: 'Снять «Важный»?',
        text: 'Без этой отметки пароль покажут и скопируют без '
            'подтверждения. Подтвердите мастер-паролем.',
        check: (String master) async {
          final bytes = SecretBytes.fromText(master);
          try {
            failure = await _write(
              id: id,
              service: service,
              login: login,
              hint: hint,
              urls: urls,
              password: password,
              note: note,
              master: bytes,
            );
            return true;
          } on VaultError {
            return false;
          } finally {
            bytes.wipe();
          }
        },
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _failure = 'Отметка «Важный» не снята: нужен мастер-пароль.';
        });
        return;
      }
      _finish(failure);
      return;
    }
    setState(() => _busy = true);
    try {
      _finish(
        await _write(
          id: id,
          service: service,
          login: login,
          hint: hint,
          urls: urls,
          password: password,
          note: note,
        ),
      );
    } on VaultError {
      _finish('Не получилось сохранить.');
    }
  }

  /// Итог сохранения: закрыть редактор или показать [failure].
  void _finish(String? failure) {
    if (!mounted) return;
    if (failure == null) {
      _clear();
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  /// Записать правку одной операцией хранилища ([Vault.updateEntry]):
  /// поля, пароль и заметка ложатся вместе или не ложатся вовсе.
  /// `null` — сохранено, иначе текст ошибки. Неверный [master] —
  /// `VaultError` наружу (диалог мастер-пароля скажет «не подошёл»).
  Future<String?> _write({
    required String? id,
    required String service,
    required String login,
    required String hint,
    required List<String> urls,
    required String password,
    required String note,
    SecretBytes? master,
  }) async {
    final passwordBytes =
        password.isEmpty ? null : SecretBytes.fromText(password);
    final noteBytes = note.isEmpty ? null : SecretBytes.fromText(note);
    try {
      if (id == null) {
        await kit.vault.addEntry(
          service: service,
          password: passwordBytes!,
          note: noteBytes,
          login: login,
          hint: hint,
          urls: urls,
          important: _important,
        );
      } else {
        await kit.vault.updateEntry(
          id,
          service: service,
          login: login,
          hint: hint,
          urls: urls,
          important: _important,
          password: passwordBytes,
          note: noteBytes,
          master: master,
        );
      }
      return null;
    } on VaultError catch (error) {
      if (master != null &&
          (error.code == VaultErrorCode.wrongPassword ||
              error.code == VaultErrorCode.rateLimited)) {
        rethrow;
      }
      return 'Не получилось сохранить.';
    } on ArgumentError {
      return 'Слишком длинное поле — сократите его.';
    } on StateError {
      // Окно подтверждения кончилось до записи: ничего не сохранено.
      return 'Не сохранено: для важной записи нужен мастер-пароль. '
          'Нажмите «Сохранить» ещё раз.';
    } on Object {
      return 'Не получилось сохранить.';
    } finally {
      passwordBytes?.wipe();
      noteBytes?.wipe();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(
        backgroundColor: AssistantColors.workspace,
        title: Text(_isNew ? 'Новая запись' : 'Изменить запись'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              TextField(
                key: const ValueKey<String>('editor-service'),
                controller: _service,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Сервис',
                  errorText: _serviceError,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('editor-urls'),
                controller: _urls,
                enabled: !_busy,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Адреса (по одному в строке)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('editor-login'),
                controller: _login,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Логин',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SecretField(
                key: const ValueKey<String>('editor-password'),
                controller: _password,
                label: _isNew ? 'Пароль' : 'Новый пароль',
                helper: <String>[
                  if (_repeatWarning != null) _repeatWarning!,
                  if (_strength != null) _strength!,
                  if (_repeatWarning == null && _strength == null && !_isNew)
                    'Пусто — оставить прежний пароль.',
                ].join('\n').nullIfEmpty,
                error: _passwordError,
                enabled: !_busy,
                allowShow: true,
                autofocus: widget.passwordOnly,
                onChanged: _checkRepeat,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey<String>('editor-generate'),
                  onPressed: _busy ? null : () => unawaited(_generate()),
                  icon: const Icon(Icons.casino_outlined, size: 16),
                  label: const Text('Сгенерировать'),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                key: const ValueKey<String>('editor-hint'),
                controller: _hint,
                onChanged: (_) => setState(() {}),
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Подсказка',
                  // Предупреждение — первым: при крупном шрифте хвост
                  // подсказки обрезается, а оно должно остаться на виду.
                  helperText: 'Не пишите в ней сам пароль. Помощник '
                      'покажет её, когда вы забудете пароль.',
                  helperMaxLines: 12,
                  errorText: _hintError,
                  errorMaxLines: 4,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_structure != null && _hint.text.trim().isEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey<String>('editor-structure-hint'),
                    onPressed: () => setState(() {
                      _hint.text = '${_structure!}. ';
                    }),
                    child: const Text('Подставить подсказку по структуре'),
                  ),
                ),
              const SizedBox(height: 12),
              SecretField(
                key: const ValueKey<String>('editor-note'),
                controller: _note,
                label: _isNew ? 'Заметка' : 'Новая заметка',
                helper: _isNew
                    ? 'Скрыта так же, как пароль.'
                    : 'Пусто — оставить прежнюю заметку.',
                enabled: !_busy,
                allowShow: true,
                multiline: true,
              ),
              SwitchListTile(
                key: const ValueKey<String>('editor-important'),
                contentPadding: EdgeInsets.zero,
                value: _important,
                onChanged:
                    _busy ? null : (bool v) => setState(() => _important = v),
                title: const Text('Важный — тренировать память'),
                subtitle: const Text(
                  'Показ и копирование — с подтверждением мастер-паролем; '
                  'иногда спрошу пароль по памяти.',
                ),
              ),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text(
                    _failure!,
                    style: const TextStyle(color: AssistantColors.danger),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey<String>('editor-save'),
                onPressed: _busy ? null : () => unawaited(_save()),
                child: Text(_busy ? 'Сохраняю…' : 'Сохранить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
