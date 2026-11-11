import '../../connectors/connector.dart';
import '../../extensions/extension_registry.dart';
import '../../models/secure_card.dart';
import '../../passwords/vault.dart';
import '../../passwords/vault_errors.dart';
import '../../passwords/vault_facade.dart';
import 'passwords_phrases.dart';
import 'service_aliases.dart';

export 'passwords_phrases.dart';

/// Навык «Пароли» (ADR-014): хранилище на устройстве под мастер-паролем.
///
/// Включаемый навык вне ролей, по умолчанию выключен. Видит только
/// [VaultFacade]: ни пароля, ни заметки, ни подсказки он не получает
/// (подсказка — только при флаге `hints_in_history`). Пароль показывают,
/// копируют и вводят экраны и временные карточки в `lib/app`; в ответах
/// навыка — только названия, логин в маске и числа.
///
/// `match` не зависит от замка (корпус детерминирован), замок проверяет
/// `run`.
final class PasswordsConnector implements Connector, ConnectorHealth {
  PasswordsConnector({
    VaultFacade? vault,
    this.canCopySecrets = true,
    bool Function()? vaultExisted,
  })  : _vault = vault,
        _vaultExisted = vaultExisted ?? _never;

  static const String id = 'passwords';

  /// Нажатие в карточке ([SecureCardCommand]).
  static const String cardCommand = 'passwords.card';

  static bool _never() => false;

  final VaultFacade? _vault;

  /// Можно ли копировать пароли в буфер: на Windows и macOS — нет, пока
  /// нет канала без облачного буфера и Handoff (D22, этап 4).
  final bool canCopySecrets;

  /// `passwords.vault_existed` из настроек: хранилище здесь уже было.
  final bool Function() _vaultExisted;

  static const ConnectorInfo _info = ConnectorInfo(
    id: id,
    title: 'Пароли',
    description: 'Хранит пароли на этом устройстве под мастер-паролем: '
        'подсказка, показ и копирование по просьбе. В сеть ничего не '
        'отправляет.',
    examples: <String>[
      'Забыл пароль от почты',
      'Запомни пароль от озона',
      'Какой у меня логин от госуслуг',
      'Запри пароли',
    ],
    kind: ExtensionKind.skill,
    access: ConnectorAccess.readWrite,
    defaultEnabled: false,
    sensitive: true,
    chips: <RoleChip>[
      RoleChip(
        label: 'Подсказка к паролю…',
        text: 'Забыл пароль от |',
        action: RoleChipAction.insert,
        icon: 'key',
      ),
      RoleChip(label: 'Открыть пароли', text: 'Открой пароли', icon: 'lock'),
    ],
  );

  @override
  ConnectorInfo get info => _info;

  @override
  ConnectorMatch? match(Utterance utterance) {
    final command = PasswordPhrases.parse(utterance);
    if (command == null) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: command.cmd,
      confidence: command.confidence,
      implicit: command.implicit,
      payload: command,
    );
  }

  @override
  Future<HealthReport> health() async {
    final vault = _vault;
    if (vault == null) {
      return const HealthReport(
        HealthStatus.down,
        detail: 'не загрузилась библиотека шифрования',
      );
    }
    return const HealthReport.ok();
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    try {
      return await _dispatch(match, session);
    } on VaultError catch (error) {
      if (error.code == VaultErrorCode.locked) {
        return _locked(session, match.commandId);
      }
      return session.reply(
        'passwords.failed',
        values: <String, String>{'code': error.code.name},
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    }
  }

  Future<AssistantResponse> _dispatch(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) return _answer(payload, session);
    if (payload is SecureCardCommand) return _card(payload, session);
    if (payload is PasswordCommand) {
      return _command(payload.cmd, payload.query, session);
    }
    return _reply(session, 'passwords.help', PasswordCommands.help);
  }

  // ------------------------------------------------------- команды

  /// Команды, которым хранилище не нужно.
  static const Set<String> _soon = <String>{
    PasswordCommands.generate,
    PasswordCommands.check,
    PasswordCommands.train,
    PasswordCommands.backup,
    PasswordCommands.import,
  };

  Future<AssistantResponse> _command(
    String cmd,
    String? query,
    AssistantSession session,
  ) async {
    switch (cmd) {
      case PasswordCommands.help:
        return _reply(session, 'passwords.help', cmd);
      case PasswordCommands.recoverHelp:
        return _reply(session, 'passwords.recoverHelp', cmd);
      case PasswordCommands.lostDevice:
        return _reply(session, 'passwords.lostDevice', cmd);
      case PasswordCommands.masterForgot:
        return session.reply(
          'passwords.noRecovery',
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard: const SecureCardRequest(kind: SecureCardKind.recovery),
        );
    }
    if (_soon.contains(cmd)) return _reply(session, 'passwords.soon', cmd);
    final vault = _vault;
    if (vault == null) {
      return session.reply(
        'passwords.unavailable',
        intent: cmd,
        status: AssistantStatus.failed,
      );
    }
    switch (vault.state) {
      case VaultState.notCreated:
        return session.reply(
          _vaultExisted()
              ? 'passwords.notFoundOnDevice'
              : 'passwords.notCreated',
          intent: cmd,
          status: AssistantStatus.noAction,
          secureCard: SecureCardRequest(
            kind: SecureCardKind.unlock,
            resume: cmd == PasswordCommands.open ? null : cmd,
            options: <String, Object?>{if (query != null) 'query': query},
          ),
        );
      case VaultState.disabled:
        return _reply(session, 'passwords.off', cmd);
      case VaultState.locked:
        if (cmd == PasswordCommands.lock) {
          return _reply(session, 'passwords.lock.done', cmd);
        }
        return _locked(session, cmd, query: query);
      case VaultState.unlocked:
        break;
    }
    switch (cmd) {
      case PasswordCommands.lock:
        vault.lock();
        return _reply(session, 'passwords.lock.done', cmd);
      case PasswordCommands.open:
        return session.reply(
          'passwords.opened',
          values: <String, String>{'minutes': '${vault.idleMinutes}'},
          intent: cmd,
          status: AssistantStatus.completed,
        );
      case PasswordCommands.list:
        final all = vault.all();
        if (all.isEmpty) return _reply(session, 'passwords.list.empty', cmd);
        return session.reply(
          'passwords.list.count',
          values: <String, String>{'count': '${all.length}'},
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard: SecureCardRequest(
            kind: SecureCardKind.list,
            entryIds: <String>[for (final ref in all) ref.id],
          ),
        );
      case PasswordCommands.add:
        return session.reply(
          query == null ? 'passwords.add.blank' : 'passwords.add.editor',
          values: <String, String>{if (query != null) 'service': query},
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard: SecureCardRequest(
            kind: SecureCardKind.editor,
            options: <String, Object?>{if (query != null) 'service': query},
          ),
        );
    }
    if (query == null) {
      return session.reply(
        'passwords.which',
        intent: cmd,
        status: AssistantStatus.needsClarification,
      );
    }
    var found = <VaultEntryRef>[
      for (final ref in vault.all())
        if (ServiceAliases.matches(query, ref.names)) ref,
    ];
    // «wifi дома» не нашлось целиком — пробуем по первому слову.
    final words = query.split(RegExp(r'\s+'));
    if (found.isEmpty && words.length > 1) {
      final first = ServiceAliases.display(words.first);
      found = <VaultEntryRef>[
        for (final ref in vault.all())
          if (ServiceAliases.matches(first, ref.names)) ref,
      ];
    }
    if (found.isEmpty) {
      return session.reply(
        cmd == PasswordCommands.hint
            ? 'passwords.notFound.recover'
            : 'passwords.notFound',
        values: <String, String>{'query': query},
        intent: cmd,
        status: AssistantStatus.noAction,
      );
    }
    if (found.length > 1) {
      return session.reply(
        'passwords.choose',
        values: <String, String>{'count': '${found.length}'},
        intent: cmd,
        status: AssistantStatus.needsClarification,
        secureCard: SecureCardRequest(
          kind: SecureCardKind.choose,
          entryIds: <String>[for (final ref in found) ref.id],
          resume: cmd,
        ),
      );
    }
    return _forEntry(cmd, found.single, vault, session);
  }

  AssistantResponse _forEntry(
    String cmd,
    VaultEntryRef ref,
    VaultFacade vault,
    AssistantSession session,
  ) {
    final service = <String, String>{'service': ref.service};
    final ids = <String>[ref.id];
    switch (cmd) {
      case PasswordCommands.hint:
        final card =
            SecureCardRequest(kind: SecureCardKind.hint, entryIds: ids);
        final inline = vault.hintForHistory(ref.id);
        if (inline != null) {
          return session.reply(
            'passwords.hint.inline',
            values: <String, String>{...service, 'hint': inline},
            intent: cmd,
            status: AssistantStatus.completed,
            secureCard: card,
          );
        }
        return session.reply(
          vault.hasHint(ref.id) ? 'passwords.hint.card' : 'passwords.hint.none',
          values: service,
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard: card,
        );
      case PasswordCommands.reveal:
        session.requestConfirmation(
          PendingConfirmation(
            connectorId: id,
            commandId: cmd,
            itemId: ref.id,
          ),
        );
        return session.reply(
          'passwords.reveal.confirm',
          values: <String, String>{
            ...service,
            'seconds': '${vault.revealSeconds}',
          },
          intent: cmd,
          status: AssistantStatus.needsClarification,
        );
      case PasswordCommands.copy:
        if (!canCopySecrets) {
          return _reply(session, 'passwords.copy.unavailable', cmd);
        }
        session.requestConfirmation(
          PendingConfirmation(
            connectorId: id,
            commandId: cmd,
            itemId: ref.id,
          ),
        );
        return session.reply(
          'passwords.copy.confirm',
          values: service,
          intent: cmd,
          status: AssistantStatus.needsClarification,
        );
      case PasswordCommands.login:
        if (!ref.hasLogin) {
          return session.reply(
            'passwords.login.none',
            values: service,
            intent: cmd,
            status: AssistantStatus.noAction,
          );
        }
        return session.reply(
          vault.loginInReplies
              ? 'passwords.login.full'
              : 'passwords.login.card',
          values: <String, String>{...service, 'login': ref.maskedLogin},
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard:
              SecureCardRequest(kind: SecureCardKind.login, entryIds: ids),
        );
      case PasswordCommands.change:
        return session.reply(
          'passwords.change.editor',
          values: service,
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard: SecureCardRequest(
            kind: SecureCardKind.editor,
            entryIds: ids,
            options: const <String, Object?>{'mode': 'password'},
          ),
        );
      case PasswordCommands.delete:
        session.requestConfirmation(
          PendingConfirmation(
            connectorId: id,
            commandId: cmd,
            itemId: ref.id,
          ),
        );
        return session.reply(
          'passwords.delete.confirm',
          values: service,
          intent: cmd,
          status: AssistantStatus.needsClarification,
          secureCard:
              SecureCardRequest(kind: SecureCardKind.delete, entryIds: ids),
        );
    }
    return _reply(session, 'passwords.help', cmd);
  }

  // ------------------------------------------- подтверждения и карточки

  Future<AssistantResponse> _answer(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) async {
    final cmd = answer.pending.commandId;
    if (!answer.confirmed) return _reply(session, 'passwords.cancelled', cmd);
    final vault = _vault;
    if (vault == null || !vault.isUnlocked) {
      // Заперли между вопросом и «да»: после открытия карточка продолжит
      // с той же записью, а не спросит сервис заново.
      return _locked(
        session,
        cmd,
        entryId: answer.pending.itemId,
        confirmed: true,
      );
    }
    final ref = vault.ref(answer.pending.itemId ?? '');
    if (ref == null) return _reply(session, 'passwords.gone', cmd);
    return _confirmed(cmd, ref, vault, session, answer.pending);
  }

  /// «Да» на вопрос о записи [ref] (или то же после открытия хранилища).
  AssistantResponse _confirmed(
    String cmd,
    VaultEntryRef ref,
    VaultFacade vault,
    AssistantSession session,
    PendingConfirmation? pending,
  ) {
    final service = <String, String>{'service': ref.service};
    final ids = <String>[ref.id];
    switch (cmd) {
      case PasswordCommands.reveal:
        return session.reply(
          'passwords.reveal.card',
          values: service,
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard:
              SecureCardRequest(kind: SecureCardKind.reveal, entryIds: ids),
        );
      case PasswordCommands.copy:
        if (!canCopySecrets) {
          return _reply(session, 'passwords.copy.unavailable', cmd);
        }
        return session.reply(
          'passwords.copy.done',
          values: <String, String>{'seconds': '${vault.clipboardSeconds}'},
          intent: cmd,
          status: AssistantStatus.completed,
          secureCard: SecureCardRequest(
            kind: SecureCardKind.copy,
            entryIds: ids,
            options: const <String, Object?>{'auto': true},
          ),
        );
      case PasswordCommands.delete:
        // Удаление — только кнопкой карточки: случайное «да» ничего не
        // сотрёт. Вопрос остаётся, «нет» его снимает.
        if (pending == null) return _forEntry(cmd, ref, vault, session);
        session.requestConfirmation(pending);
        return session.reply(
          'passwords.delete.button',
          intent: cmd,
          status: AssistantStatus.needsClarification,
        );
    }
    return _reply(session, 'passwords.help', cmd);
  }

  Future<AssistantResponse> _card(
    SecureCardCommand command,
    AssistantSession session,
  ) async {
    final card = command.card;
    final cmd = card.resume ?? PasswordCommands.open;
    final vault = _vault;
    switch (command.action) {
      case SecureCardCommand.resume:
        final query = card.options['query'];
        final entryId = card.entryIds.isEmpty ? null : card.entryIds.first;
        if (entryId == null) {
          return _command(cmd, query is String ? query : null, session);
        }
        final confirmed = card.options['confirmed'] == true;
        if (vault == null || !vault.isUnlocked) {
          return _locked(session, cmd, entryId: entryId, confirmed: confirmed);
        }
        final ref = vault.ref(entryId);
        if (ref == null) return _reply(session, 'passwords.gone', cmd);
        return confirmed
            ? _confirmed(cmd, ref, vault, session, null)
            : _forEntry(cmd, ref, vault, session);
    }
    if (vault == null || !vault.isUnlocked) {
      return _locked(session, cmd, entryId: command.entryId);
    }
    final ref = vault.ref(command.entryId ?? '');
    if (ref == null) return _reply(session, 'passwords.gone', cmd);
    final service = <String, String>{'service': ref.service};
    switch (command.action) {
      case SecureCardCommand.choose:
        return _forEntry(cmd, ref, vault, session);
      case SecureCardCommand.delete:
        await vault.delete(ref.id);
        final pending = session.pendingConfirmation;
        if (pending != null &&
            pending.connectorId == id &&
            pending.itemId == ref.id) {
          session.takePendingConfirmation();
        }
        return session.reply(
          'passwords.delete.done',
          values: service,
          intent: PasswordCommands.delete,
          status: AssistantStatus.completed,
        );
      case SecureCardCommand.revealed:
        return session.reply(
          'passwords.revealed',
          values: service,
          intent: PasswordCommands.reveal,
          status: AssistantStatus.completed,
        );
      case SecureCardCommand.copied:
        return session.reply(
          'passwords.copy.done',
          values: <String, String>{'seconds': '${vault.clipboardSeconds}'},
          intent: PasswordCommands.copy,
          status: AssistantStatus.completed,
        );
    }
    return _reply(session, 'passwords.help', cmd);
  }

  // ------------------------------------------------------- ответы

  /// «Хранилище заперто» с карточкой открытия. После открытия карточка
  /// повторяет [cmd]: с [query] — поиском, с [entryId] — сразу для этой
  /// записи (только id; [confirmed] — человек уже ответил «да»).
  AssistantResponse _locked(
    AssistantSession session,
    String cmd, {
    String? query,
    String? entryId,
    bool confirmed = false,
  }) =>
      session.reply(
        'passwords.locked',
        intent: cmd,
        status: AssistantStatus.needsClarification,
        secureCard: SecureCardRequest(
          kind: SecureCardKind.unlock,
          resume: cmd == PasswordCommands.open ? null : cmd,
          entryIds: <String>[if (entryId != null) entryId],
          options: <String, Object?>{
            if (query != null) 'query': query,
            if (entryId != null && confirmed) 'confirmed': true,
          },
        ),
      );

  static AssistantResponse _reply(
    AssistantSession session,
    String replyId,
    String cmd,
  ) =>
      session.reply(
        replyId,
        intent: cmd,
        status: AssistantStatus.completed,
      );

  @override
  String toString() => 'PasswordsConnector';
}
