import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../../core/passwords/vault_prefs.dart';
import '../assistant_theme.dart';
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
    if (!(confirmed ?? false)) return;
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
                        style: technicalTextStyle,
                      ),
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
                          style: technicalTextStyle,
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
          Text(label, style: technicalTextStyle),
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
  });

  final PasswordsKit kit;

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
    startWatching();
  }

  static String _title(String text) => text.isEmpty
      ? text
      : text.substring(0, 1).toUpperCase() + text.substring(1);

  @override
  void onLocked() => _clear();

  void _clear() {
    _password.clear();
    _note.clear();
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
      _repeatWarning = same.isEmpty
          ? null
          : 'Этот пароль уже используется для: '
              '${same.map((VaultEntry e) => e.service).join(', ')}.';
    });
  }

  Future<void> _save() async {
    final service = _service.text.trim();
    final password = _password.text;
    final hint = _hint.text.trim();
    setState(() {
      _serviceError = service.isEmpty ? 'Как назвать запись?' : null;
      _passwordError =
          _isNew && password.isEmpty ? 'Без пароля запись не сохранить.' : null;
      _hintError = password.length >= 4 &&
              hint.toLowerCase().contains(password.toLowerCase())
          ? 'В подсказке не должно быть самого пароля.'
          : null;
      _failure = null;
    });
    if (_serviceError != null || _passwordError != null || _hintError != null) {
      return;
    }
    final id = widget.id;
    final before = id == null ? null : kit.vault.entry(id);
    if (id != null &&
        before != null &&
        before.important &&
        !_important &&
        VaultPrefs.repromptImportant.of(kit.vault.prefs)) {
      // Снять «Важный» — ослабить защиту (3.6, 15.2): как и выключение
      // переспроса в настройках, только с мастер-паролем.
      setState(() => _busy = true);
      final ok = await askMaster(
        context,
        title: 'Снять «Важный»?',
        text: 'Без этой отметки пароль покажут и скопируют без '
            'подтверждения. Подтвердите мастер-паролем.',
        check: (String master) => kit.dropImportant(id, master),
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _failure = 'Отметка «Важный» не снята: нужен мастер-пароль.';
        });
        return;
      }
    }
    setState(() => _busy = true);
    final urls = <String>[
      for (final line in _urls.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final login = _login.text.trim();
    final passwordBytes =
        password.isEmpty ? null : SecretBytes.fromText(password);
    final noteBytes =
        _note.text.isEmpty ? null : SecretBytes.fromText(_note.text);
    _clear();
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
        await kit.vault.updateInfo(
          id,
          service: service,
          login: login,
          hint: hint,
          urls: urls,
          important: _important,
        );
        if (passwordBytes != null) {
          await kit.vault.updatePassword(id, passwordBytes);
        }
        if (noteBytes != null) await kit.vault.updateNote(id, noteBytes);
      }
      if (mounted) Navigator.of(context).pop();
    } on ArgumentError {
      if (mounted) {
        setState(() => _failure = 'Слишком длинное поле — сократите его.');
      }
    } on Object {
      if (mounted) setState(() => _failure = 'Не получилось сохранить.');
    } finally {
      passwordBytes?.wipe();
      noteBytes?.wipe();
      if (mounted) setState(() => _busy = false);
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
                helper: _repeatWarning ??
                    (_isNew ? null : 'Пусто — оставить прежний пароль.'),
                error: _passwordError,
                enabled: !_busy,
                allowShow: true,
                autofocus: widget.passwordOnly,
                onChanged: _checkRepeat,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('editor-hint'),
                controller: _hint,
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
                  border: const OutlineInputBorder(),
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
                title: const Text('Важный'),
                subtitle: const Text(
                  'Показ и копирование — с подтверждением мастер-паролем.',
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
