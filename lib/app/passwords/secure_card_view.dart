import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/secure_card.dart';
import '../../core/passwords/generator_options.dart';
import '../../core/passwords/password_training.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../assistant_theme.dart';
import 'backup_screens.dart';
import 'entry_screens.dart';
import 'generator_view.dart';
import 'import_screen.dart';
import 'passwords_kit.dart';
import 'passwords_screen.dart';
import 'recall_views.dart';
import 'secret_widgets.dart';

/// Нажатие в карточке, которое выполняет навык: выбор записи, «Удалить»,
/// повтор команды после открытия, «пароль был показан».
typedef SecureCardCallback = void Function(
  SecureCardRequest card,
  String action, {
  String? entryId,
  String? detail,
});

/// Временная карточка навыка «Пароли» под ответом (D10): несёт только id,
/// значения берёт из хранилища в момент показа. Её нет в истории: после
/// перезапуска остаётся только текст ответа. Пока хранилище заперто —
/// «Хранилище заперто — [Открыть]».
class SecureCardView extends StatefulWidget {
  const SecureCardView({
    super.key,
    required this.card,
    required this.kit,
    required this.onCommand,
    this.busy = false,
  });

  final SecureCardRequest card;
  final PasswordsKit kit;
  final SecureCardCallback onCommand;
  final bool busy;

  @override
  State<SecureCardView> createState() => _SecureCardViewState();
}

class _SecureCardViewState extends State<SecureCardView> {
  PasswordsKit get kit => widget.kit;
  SecureCardRequest get card => widget.card;

  /// «Вспомнил» / «Отмена»: карточка свёрнута.
  bool _closed = false;

  bool _copied = false;

  @override
  void initState() {
    super.initState();
    kit.addListener(_changed);
    if (card.kind == SecureCardKind.copy &&
        card.options['auto'] == true &&
        kit.isUnlocked &&
        kit.takeOnce(card)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoCopy());
    }
  }

  @override
  void dispose() {
    kit.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _autoCopy() async {
    if (!mounted || card.entryIds.isEmpty) return;
    final ok = await copyPassword(context, kit, card.entryIds.first);
    if (mounted) setState(() => _copied = ok);
  }

  Future<void> _open() async {
    final opened = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) =>
            PasswordsScreen(kit: kit, unlockOnly: true),
      ),
    );
    if (!mounted || !(opened ?? false)) return;
    if (card.kind == SecureCardKind.unlock && card.resume != null) {
      widget.onCommand(card, SecureCardCommand.resume);
    }
  }

  Future<void> _push(Widget screen) => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (BuildContext context) => screen),
      );

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (card.kind == SecureCardKind.recovery) {
      body = _recovery();
    } else if (card.kind == SecureCardKind.generate &&
        kit.state != VaultState.disabled) {
      // Генератору хранилище не нужно (5.4): работает и при запертом.
      body = GeneratorPanel(
        kit: kit,
        initial: GeneratorOptions.fromJson(card.options),
      );
    } else if (card.kind == SecureCardKind.restore &&
        kit.state == VaultState.notCreated) {
      // Восстановлению хранилище не нужно (5.12, D28).
      body = _files();
    } else if (kit.state == VaultState.disabled) {
      body = const _Line(
        icon: Icons.lock_outline,
        text: 'Навык «Пароли» выключен — данные сохранены и заперты.',
      );
    } else if (card.kind == SecureCardKind.unlock || !kit.isUnlocked) {
      body = _locked();
    } else if (_closed) {
      body = const _Line(icon: Icons.check, text: 'Готово.');
    } else {
      body = switch (card.kind) {
        SecureCardKind.hint => _hint(),
        SecureCardKind.reveal => _reveal(),
        SecureCardKind.copy => _copy(),
        SecureCardKind.choose => _entries(choose: true),
        SecureCardKind.list => _entries(choose: false),
        SecureCardKind.login => _login(),
        SecureCardKind.editor => _editor(),
        SecureCardKind.delete => _delete(),
        SecureCardKind.check => CheckView(kit: kit, groups: kit.groups()),
        SecureCardKind.training => _training(),
        SecureCardKind.importPreview ||
        SecureCardKind.backup ||
        SecureCardKind.restore =>
          _files(),
        _ => const _Line(
            icon: Icons.schedule,
            text: 'Появится в следующем обновлении навыка.',
          ),
      };
    }
    // Material, а не украшенный Container: строки выбора (ListTile) рисуют
    // отклик нажатия и наведения на ближайшем Material.
    return Padding(
      key: ValueKey<String>('secure-card-${card.kind.name}'),
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: AssistantColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AssistantColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: body,
        ),
      ),
    );
  }

  // --------------------------------------------------------------- виды

  /// Импорт, копия, восстановление — кнопки экранов (5.6, 5.7).
  Widget _files() {
    final unlocked = kit.isUnlocked;
    final buttons = <Widget>[
      if (card.kind == SecureCardKind.importPreview && unlocked)
        FilledButton.icon(
          key: const ValueKey<String>('secure-card-import-open'),
          onPressed: () => unawaited(_push(CsvImportScreen(kit: kit))),
          icon: const Icon(Icons.upload_file_outlined, size: 16),
          label: const Text('Импорт из браузера'),
        ),
      if ((card.kind == SecureCardKind.backup ||
              (card.kind == SecureCardKind.restore &&
                  kit.vault.lastBackupAt == null)) &&
          unlocked)
        FilledButton.icon(
          key: const ValueKey<String>('secure-card-backup-open'),
          onPressed: () => unawaited(_push(BackupExportScreen(kit: kit))),
          icon: const Icon(Icons.save_alt_outlined, size: 16),
          label: Text(
            card.kind == SecureCardKind.backup
                ? 'Сделать копию'
                : 'Сделать копию сейчас',
          ),
        ),
      if (card.kind == SecureCardKind.restore)
        OutlinedButton.icon(
          key: const ValueKey<String>('secure-card-restore-open'),
          onPressed: () => unawaited(_push(BackupRestoreScreen(kit: kit))),
          icon: const Icon(Icons.restore, size: 16),
          label: const Text('Восстановить из копии'),
        ),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _locked() {
    final notCreated = kit.state == VaultState.notCreated;
    final unlocked = kit.isUnlocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Line(
          icon: unlocked ? Icons.lock_open_outlined : Icons.lock_outline,
          text: unlocked
              ? 'Сейф открыт.'
              : notCreated
                  ? (kit.vaultExisted
                      ? 'Сейф на этом устройстве не найден.'
                      : 'Сейфа паролей ещё нет.')
                  : 'Сейф заперт.',
        ),
        if (!unlocked)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(
              key: const ValueKey<String>('secure-card-open'),
              onPressed: widget.busy ? null : () => unawaited(_open()),
              icon: Icon(
                notCreated ? Icons.add : Icons.lock_open_outlined,
                size: 16,
              ),
              label: Text(notCreated ? 'Создать сейф' : 'Открыть'),
            ),
          ),
        if (notCreated && kit.vaultExisted)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              key: const ValueKey<String>('secure-card-restore-open'),
              onPressed: widget.busy
                  ? null
                  : () => unawaited(_push(BackupRestoreScreen(kit: kit))),
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Восстановить из копии'),
            ),
          ),
      ],
    );
  }

  VaultEntry? get _entry =>
      card.entryIds.isEmpty ? null : kit.vault.entry(card.entryIds.first);

  Widget _title(VaultEntry entry) => Row(
        children: <Widget>[
          const Icon(
            Icons.key_outlined,
            size: 16,
            color: AssistantColors.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.service,
              style: const TextStyle(
                color: AssistantColors.textStrong,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (entry.important)
            const Icon(
              Icons.star_outline,
              size: 16,
              color: AssistantColors.warning,
            ),
        ],
      );

  Widget _gone() => const _Line(
        icon: Icons.remove_circle_outline,
        text: 'Этой записи уже нет в сейфе.',
      );

  Widget _loginRow(VaultEntry entry) => Row(
        children: <Widget>[
          const Text('Логин: ', style: metaTextStyle),
          Expanded(
            child: Text(
              entry.login,
              key: const ValueKey<String>('secure-card-login'),
              style: const TextStyle(color: AssistantColors.text),
            ),
          ),
          IconButton(
            tooltip: 'Скопировать логин',
            icon: const Icon(Icons.copy_outlined, size: 16),
            onPressed: () => fireAndForget(kit.clipboard.copyText(entry.login)),
          ),
        ],
      );

  Widget _secret(VaultEntry entry) => SecretRevealText(
        key: ValueKey<String>('secure-card-secret-${entry.id}'),
        load: () => loadPassword(context, kit, entry.id),
        seconds: kit.revealSeconds,
        hide: kit.hideTicks,
        onRevealed: () => widget.onCommand(
          card,
          SecureCardCommand.revealed,
          entryId: entry.id,
        ),
      );

  Widget _copyButton(VaultEntry entry) => kit.canCopySecrets
      ? TextButton.icon(
          key: const ValueKey<String>('secure-card-copy'),
          onPressed: () => fireAndForget(() async {
            if (await copyPassword(context, kit, entry.id)) {
              widget.onCommand(
                card,
                SecureCardCommand.copied,
                entryId: entry.id,
              );
            }
          }()),
          icon: const Icon(Icons.copy_outlined, size: 16),
          label: const Text('Скопировать'),
        )
      : const SizedBox.shrink();

  Widget _hint() {
    final entry = _entry;
    if (entry == null) return _gone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(entry),
        const SizedBox(height: 8),
        if (entry.login.isNotEmpty) _loginRow(entry),
        HintLadder(
          kit: kit,
          entry: entry,
          reveal: _secret(entry),
          copyButton: _copyButton(entry),
          onStep: (int step) => widget.onCommand(
            card,
            SecureCardCommand.hintStep,
            entryId: entry.id,
            detail: '$step',
          ),
        ),
      ],
    );
  }

  Widget _training() {
    final entry = _entry;
    if (entry == null) return _gone();
    return TrainingView(
      kit: kit,
      entry: entry,
      reveal: _secret(entry),
      onOutcome: (TrainingOutcome outcome) => widget.onCommand(
        card,
        SecureCardCommand.trained,
        entryId: entry.id,
        detail: outcome.name,
      ),
    );
  }

  Widget _reveal() {
    final entry = _entry;
    if (entry == null) return _gone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(entry),
        const SizedBox(height: 8),
        _secret(entry),
        Align(alignment: Alignment.centerLeft, child: _copyButton(entry)),
      ],
    );
  }

  Widget _copy() {
    final entry = _entry;
    if (entry == null) return _gone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(entry),
        const SizedBox(height: 6),
        _Line(
          icon: _copied ? Icons.content_paste_outlined : Icons.copy_outlined,
          text: _copied
              ? 'Скопировано. Буфер очистится через ${kit.clipboardSeconds} с.'
              : 'Пароль не скопирован.',
        ),
        if (!_copied) _copyButton(entry),
      ],
    );
  }

  Widget _entries({required bool choose}) {
    final entries = <VaultEntry>[
      for (final id in card.entryIds)
        if (kit.vault.entry(id) case final VaultEntry entry) entry,
    ];
    if (entries.isEmpty) return _gone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          choose ? 'Какую запись?' : 'Записи сейфа',
          style: metaTextStyle,
        ),
        for (final entry in entries.take(choose ? 12 : 50))
          EntryTile(
            entry: entry,
            trailing: choose
                ? const Icon(Icons.chevron_right, size: 18)
                : const Icon(Icons.open_in_new, size: 16),
            onTap: choose
                ? () => widget.onCommand(
                      card,
                      SecureCardCommand.choose,
                      entryId: entry.id,
                    )
                : () => unawaited(_push(EntryScreen(kit: kit, id: entry.id))),
          ),
      ],
    );
  }

  Widget _login() {
    final entry = _entry;
    if (entry == null) return _gone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[_title(entry), _loginRow(entry)],
    );
  }

  Widget _editor() {
    final entry = _entry;
    final service = card.options['service'];
    final title = entry?.service ??
        (service is String && service.isNotEmpty ? service : 'Новая запись');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Line(icon: Icons.edit_outlined, text: title),
        const SizedBox(height: 6),
        FilledButton.icon(
          key: const ValueKey<String>('secure-card-editor'),
          onPressed: () => unawaited(
            _push(
              EntryEditorScreen(
                kit: kit,
                id: entry?.id,
                service: service is String ? service : null,
                passwordOnly: card.options['mode'] == 'password',
              ),
            ),
          ),
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: Text(entry == null ? 'Открыть редактор' : 'Сменить пароль'),
        ),
      ],
    );
  }

  /// «Удалить»: важную запись — после мастер-пароля в окне поверх чата
  /// (3.6); в чат он не вводится. Отменили — ничего не уходит навыку.
  Future<void> _confirmDelete(String id) async {
    if (!await confirmDelete(context, kit, id) || !mounted) return;
    widget.onCommand(card, SecureCardCommand.delete, entryId: id);
  }

  Widget _delete() {
    final entry = _entry;
    if (entry == null) return _gone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(entry),
        if (entry.login.isNotEmpty)
          Text(VaultFacade.maskLogin(entry.login), style: metaTextStyle),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: const ValueKey<String>('secure-card-delete'),
              style: FilledButton.styleFrom(
                backgroundColor: AssistantColors.danger,
                foregroundColor: AssistantColors.background,
              ),
              onPressed: widget.busy ? null : () => _confirmDelete(entry.id),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Удалить'),
            ),
            TextButton(
              onPressed: () => setState(() => _closed = true),
              child: const Text('Отмена'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _recovery() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _Line(
            icon: Icons.info_outline,
            text: 'Восстановить мастер-пароль нельзя. Вход по отпечатку и '
                'восстановление из копии появятся в следующих обновлениях. '
                'Можно начать заново: старый сейф уйдёт в архив, не '
                'сотрётся.',
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey<String>('secure-card-recovery'),
              onPressed: () => unawaited(showRecovery(context, kit)),
              icon: const Icon(Icons.help_outline, size: 16),
              label: const Text('Что можно сделать'),
            ),
          ),
        ],
      );
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 16, color: AssistantColors.muted),
        const SizedBox(width: 8),
        Expanded(
          child:
              Text(text, style: const TextStyle(color: AssistantColors.text)),
        ),
      ],
    );
  }
}
