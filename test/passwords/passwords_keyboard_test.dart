// «Пароли»: поле в фокусе всегда видно над экранной клавиатурой (ADR-040) —
// каждый экран и окно сейфа с полем ввода, на телефоне 390×844 и маленьком
// 360×640 с клавиатурой 300. Значения — только канарейки (CANARY).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/backup_screens.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/passwords/passwords_settings_screen.dart';
import 'package:local_assistant/app/passwords/secret_widgets.dart';
import 'package:local_assistant/app/passwords/secure_card_view.dart';
import 'package:local_assistant/app/passwords/vault_confirm.dart';
import 'package:local_assistant/app/widgets/keyboard_safe.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import '../support/keyboard.dart';
import 'import_backup_ui_test.dart' show FakeFiles;
import 'vault_test_support.dart';

/// Сейф для экрана: [kit] и [entry] — номер записи «Почта».
typedef _Vault = ({
  PasswordsKit kit,
  Vault vault,
  String? entry,
  FakeFiles files,
  SodiumVaultCrypto crypto,
});

/// Экран сейфа: [open] показывает его, [fields] — все поля на нём.
final class _Case {
  const _Case(
    this.name,
    this.open, {
    this.created = true,
    this.unlocked = true,
    this.device = false,
    this.bio = true,
    this.pin = false,
    required this.fields,
  });

  final String name;
  final Future<void> Function(WidgetTester tester, _Vault v) open;
  final bool created;
  final bool unlocked;
  final bool device;

  /// Отпечаток на «устройстве» и ПИН-код у сейфа (с [device]).
  final bool bio;
  final bool pin;
  final List<Finder> fields;
}

Finder _value(String key) => find.byKey(ValueKey<String>(key));

Widget _app(Widget home) => MaterialApp(
      theme: AssistantTheme.dark(),
      builder: (BuildContext context, Widget? child) =>
          KeyboardSafeScope(child: child!),
      home: home,
    );

Future<void> _show(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(_app(screen));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await scrollToField(tester, _value(key));
  await tester.ensureVisible(_value(key));
  await tester.pumpAndSettle();
  await tester.tap(_value(key));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await scrollToField(tester, _value(key));
  await tester.enterText(_value(key), text);
  await tester.pump();
}

/// Кнопка, которая открывает окно [ask].
Future<void> _launch(
  WidgetTester tester,
  Future<void> Function(BuildContext context) ask,
) async {
  await _show(
    tester,
    Scaffold(
      body: Builder(
        builder: (BuildContext context) => Center(
          child: TextButton(
            key: const ValueKey<String>('launch'),
            onPressed: () => unawaited(ask(context)),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, 'launch');
}

final List<_Case> _cases = <_Case>[
  _Case(
    'создание сейфа',
    (tester, v) => _show(tester, PasswordsScreen(kit: v.kit)),
    created: false,
    fields: <Finder>[_value('create-master'), _value('create-repeat')],
  ),
  _Case(
    'сейф заперт',
    (tester, v) => _show(tester, PasswordsScreen(kit: v.kit)),
    unlocked: false,
    fields: <Finder>[_value('lock-master')],
  ),
  _Case(
    'забыли мастер-пароль',
    (tester, v) async {
      await _show(tester, PasswordsScreen(kit: v.kit));
      await _tap(tester, 'lock-forgot');
    },
    unlocked: false,
    fields: <Finder>[_value('recovery-word')],
  ),
  _Case(
    'проверка мастер-пароля по памяти',
    (tester, v) async {
      await _show(tester, PasswordsScreen(kit: v.kit));
      await _enter(tester, 'create-master', Canary.master);
      await _enter(tester, 'create-repeat', Canary.master);
      await _tap(tester, 'create-understood');
      await _tap(tester, 'create-submit');
      await tester.pumpAndSettle();
    },
    created: false,
    fields: <Finder>[_value('recheck-master')],
  ),
  _Case(
    'восстановление копии в новый сейф',
    (tester, v) async {
      // Копия с другого сейфа; на этом устройстве сейфа нет.
      final other = testVault(InMemoryVaultStore(), v.crypto);
      final source = PasswordsKit(
        vault: other,
        platform: PasswordsPlatform.android,
        kdfForTesting: fastKdf,
      );
      await other.load();
      await other.create(secret(Canary.master), params: fastKdf);
      await other.addEntry(service: 'Почта', password: secret(Canary.password));
      v.files
        ..disk['/dl/copy.relaybak'] = await source.exportBackup(Canary.master)
        ..next = '/dl/copy.relaybak';
      other.lock();
      source.dispose();
      await _show(tester, BackupRestoreScreen(kit: v.kit));
      await _tap(tester, 'restore-pick');
      await expectFieldAboveKeyboard(tester, _value('restore-pass'));
      await _enter(tester, 'restore-pass', Canary.master);
      await _tap(tester, 'restore-open');
      await _tap(tester, 'restore-same-master');
    },
    created: false,
    fields: <Finder>[_value('restore-master'), _value('restore-repeat')],
  ),
  _Case(
    'список: поиск',
    (tester, v) => _show(tester, PasswordsScreen(kit: v.kit)),
    fields: <Finder>[_value('passwords-search')],
  ),
  _Case(
    'новая запись',
    (tester, v) =>
        _show(tester, EntryEditorScreen(kit: v.kit, service: 'озон')),
    fields: <Finder>[
      _value('editor-service'),
      _value('editor-urls'),
      _value('editor-login'),
      _value('editor-password'),
      _value('editor-hint'),
      _value('editor-note'),
    ],
  ),
  _Case(
    'правка записи',
    (tester, v) => _show(tester, EntryEditorScreen(kit: v.kit, id: v.entry)),
    fields: <Finder>[
      _value('editor-service'),
      _value('editor-urls'),
      _value('editor-login'),
      _value('editor-password'),
      _value('editor-hint'),
      _value('editor-note'),
    ],
  ),
  _Case(
    'защита устройством: проверка кода',
    (tester, v) async {
      await _show(tester, PasswordsScreen(kit: v.kit));
      await _tap(tester, 'create-submit');
      await _tap(tester, 'recovery-code-saved');
    },
    created: false,
    device: true,
    fields: <Finder>[_value('recovery-code-check')],
  ),
  _Case(
    'защита устройством: вход по коду',
    (tester, v) async {
      await _show(tester, PasswordsScreen(kit: v.kit));
      await _tap(tester, 'lock-recover');
    },
    device: true,
    pin: true,
    unlocked: false,
    fields: <Finder>[_value('lock-code')],
  ),
  _Case(
    'сменить мастер-пароль',
    (tester, v) async {
      await _show(tester, PasswordsSettingsScreen(kit: v.kit));
      await _tap(tester, 'prefs-change-master');
    },
    fields: <Finder>[
      _value('change-current'),
      _value('change-next'),
      _value('change-repeat'),
    ],
  ),
  _Case(
    'мастер-пароль для действия',
    (tester, v) => _launch(
      tester,
      (context) => askMaster(
        context,
        title: 'Показать пароль',
        text: 'Введите мастер-пароль, чтобы показать пароль записи.',
        check: (String master) async => false,
      ),
    ),
    fields: <Finder>[_value('master-dialog-field')],
  ),
  _Case(
    'подтверждение кодом восстановления',
    (tester, v) async {
      await _launch(
        tester,
        (context) => askVaultConfirm(
          context,
          kit: v.kit,
          title: 'Выгрузить копию',
          check: (proof) async => false,
        ),
      );
      await _tap(tester, 'vault-confirm-use-code');
    },
    device: true,
    bio: false,
    pin: true,
    fields: <Finder>[_value('vault-confirm-code')],
  ),
  _Case(
    'выгрузка копии',
    (tester, v) => _show(tester, BackupExportScreen(kit: v.kit)),
    fields: <Finder>[_value('backup-master')],
  ),
  _Case(
    'выгрузка копии: свой пароль копии',
    (tester, v) async {
      await _show(tester, BackupExportScreen(kit: v.kit));
      await _tap(tester, 'backup-own');
    },
    fields: <Finder>[
      _value('backup-master'),
      _value('backup-separate'),
      _value('backup-repeat'),
    ],
  ),
  _Case(
    'карточка подсказки: проверить себя',
    (tester, v) async {
      await _show(
        tester,
        Scaffold(
          body: ListView(
            children: <Widget>[
              SecureCardView(
                card: SecureCardRequest(
                  kind: SecureCardKind.hint,
                  entryIds: <String>[v.entry!],
                ),
                kit: v.kit,
                onCommand: (
                  SecureCardRequest c,
                  String action, {
                  String? entryId,
                  String? detail,
                }) {},
              ),
            ],
          ),
        ),
      );
      await _tap(tester, 'hint-check-self');
    },
    fields: <Finder>[_value('recall-input')],
  ),
];

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  Future<_Vault> makeVault(_Case c) async {
    final vault = testVault(
      InMemoryVaultStore(),
      crypto,
      deviceKey: c.device ? FakeDeviceKey(bio: c.bio) : null,
    );
    String? clipboard;
    final files = FakeFiles();
    final kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.android,
      kdfForTesting: fastKdf,
      files: files,
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.android,
        cipher: crypto,
        write: (String text) async => clipboard = text,
        read: () async => clipboard,
      ),
    );
    await vault.load();
    String? entry;
    if (c.created) {
      if (c.device) {
        await kit.createProtected();
      } else {
        await vault.create(secret(Canary.master), params: fastKdf);
      }
      entry = await vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        hint: Canary.hint,
        password: secret(Canary.password),
        note: secret(Canary.note),
      );
      if (c.pin) await vault.enablePin(secret(canaryPin()));
      if (!c.unlocked) vault.lock();
    }
    return (
      kit: kit,
      vault: vault,
      entry: entry,
      files: files,
      crypto: crypto,
    );
  }

  for (final screen in keyboardScreens) {
    final size = '${screen.width.round()}×${screen.height.round()}';
    for (final c in _cases) {
      testWidgets('${c.name}, $size: поле над клавиатурой', (tester) async {
        setPhoneScreen(tester, screen);
        final v = await makeVault(c);
        await c.open(tester, v);
        for (final field in c.fields) {
          await expectFieldAboveKeyboard(tester, field);
        }
        v.vault.lock();
        await tester.pumpWidget(const SizedBox.shrink());
        v.kit.dispose();
      });
    }
  }
}
