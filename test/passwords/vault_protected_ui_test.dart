// Экраны сейфа, защищённого устройством (ADR-025): создание без
// мастер-пароля и код восстановления, замок (устройство, ПИН-код, код),
// переход с мастер-пароля, «Вход в сейф» в настройках, подтверждения и
// вход в приложение по отпечатку. Только синтетические значения: CANARY и
// canaryPin().
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/passwords/passwords_settings_screen.dart';
import 'package:local_assistant/app/passwords/pin_pad.dart';
import 'package:local_assistant/app/passwords/vault_confirm.dart';
import 'package:local_assistant/app/security/app_lock.dart';
import 'package:local_assistant/app/security/device_auth.dart';
import 'package:local_assistant/app/security/security_section.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

import 'vault_test_support.dart';

/// Системная проверка личности в памяти.
final class FakeAuth implements DeviceAuth {
  FakeAuth({this.status_ = const DeviceAuthStatus()});

  DeviceAuthStatus status_;
  DeviceAuthResult next = DeviceAuthResult.ok;
  int asked = 0;
  final List<bool> secure = <bool>[];

  @override
  Future<DeviceAuthStatus> status() async => status_;

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    asked++;
    return next;
  }

  @override
  Future<void> secureWindow(bool on) async => secure.add(on);
}

const DeviceAuthStatus _withLock = DeviceAuthStatus(
  supported: true,
  credential: true,
  biometric: true,
  fingerprint: true,
);

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late InMemoryVaultStore store;
  late Vault vault;
  late PasswordsKit kit;
  late FakeDeviceKey device;
  late FakeAuth auth;

  PasswordsKit makeKit({FakeDeviceKey? key, FakeAuth? withAuth}) {
    store = InMemoryVaultStore();
    device = key ?? FakeDeviceKey();
    auth = withAuth ?? FakeAuth();
    vault = testVault(store, crypto, deviceKey: device);
    kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.android,
      kdfForTesting: fastKdf,
      auth: auth,
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.android,
        cipher: crypto,
        write: (String _) async {},
        read: () async => null,
      ),
    );
    return kit;
  }

  /// Сейф с одной записью; код — текстом.
  Future<String> seed() async {
    await vault.load();
    final code = await kit.createProtected();
    await kit.confirmRecovery();
    await vault.addEntry(service: 'Почта', password: secret(Canary.password));
    return code;
  }

  Widget app(Widget home) => MaterialApp(
        theme: AssistantTheme.dark(),
        home: home,
      );

  Future<void> finish(WidgetTester tester) async {
    vault.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    kit.dispose();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.byKey(ValueKey<String>('pin-pad-$digit')).last);
      await tester.pump();
    }
    await settle(tester);
  }

  /// Код с экрана: группы в виджете `recovery-code`.
  String shownCode(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('recovery-code')),
          matching: find.byType(Text),
        ),
      )
      .map((Text t) => t.data!)
      .join();

  group('создание', () {
    testWidgets('без мастер-пароля; код один раз, «Я сохранил» с проверкой',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('create-master')), findsNothing);
      expect(
        find.textContaining('пароли не восстановить'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('create-submit')));
      await settle(tester);
      expect(vault.isProtected, isTrue);
      expect(
        find.byKey(const ValueKey<String>('recovery-code-view')),
        findsOne,
      );
      expect(auth.secure, contains(true), reason: 'снимки экрана запрещены');
      final code = shownCode(tester);
      expect(code, hasLength(29));
      expect(
        find.textContaining('без него при смене телефона или сбросе'),
        findsOneWidget,
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('recovery-code-saved')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-code-check')),
        'ZZZZZ',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('recovery-code-confirm')),
      );
      await settle(tester);
      expect(find.textContaining('Не совпало'), findsOneWidget);
      expect(vault.recoveryConfirmed, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-code-check')),
        code.substring(24).toLowerCase(),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('recovery-code-confirm')),
      );
      await settle(tester);
      expect(vault.recoveryConfirmed, isTrue);
      expect(
        find.byKey(const ValueKey<String>('passwords-open-bar')),
        findsOne,
      );
      expect(auth.secure.last, isFalse, reason: 'запрет снят');
      await finish(tester);
    });

    testWidgets('код не подтверждён — баннер «Новый код»',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await kit.createProtected();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('passwords-code-unconfirmed')),
        findsOne,
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('passwords-new-code')));
      await settle(tester);
      // Устройство без блокировки экрана — кнопка «Подтвердить».
      await tester.tap(find.byKey(const ValueKey<String>('vault-confirm-ok')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('recovery-code-view')),
        findsOne,
      );
      await finish(tester);
    });
  });

  group('замок', () {
    testWidgets('ключ устройства открывает сам', (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(vault.isUnlocked, isTrue);
      expect(
        find.byKey(const ValueKey<String>('passwords-open-bar')),
        findsOne,
      );
      await finish(tester);
    });

    testWidgets('ПИН-код: набор без поля ввода, ошибка, верный открывает',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(find.byType(PinPad), findsOne);
      expect(find.byType(EditableText), findsNothing);
      expect(find.bySemanticsLabel('Введено 0 из 6'), findsOne);
      await typePin(tester, wrongPin());
      expect(find.text('ПИН-код не подошёл.'), findsOneWidget);
      expect(vault.isUnlocked, isFalse);
      await typePin(tester, canaryPin());
      expect(vault.isUnlocked, isTrue);
      expect(find.textContaining(canaryPin()), findsNothing);
      await finish(tester);
    });

    testWidgets('ключ потерян — «Восстановить по коду» открывает',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final code = await seed();
      vault.lock();
      device.lose(device.aliases.single);
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('lock-code')), findsOne);
      expect(find.textContaining('кодом восстановления'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey<String>('lock-code')),
        code.toLowerCase(),
      );
      await tester.tap(find.byKey(const ValueKey<String>('lock-code-submit')));
      await settle(tester);
      expect(vault.isUnlocked, isTrue);
      expect(find.textContaining('Сейф открыт кодом'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('сейф с мастер-паролем: ввод в последний раз и код',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final legacy = testVault(store, crypto);
      await legacy.create(secret(Canary.master), params: fastKdf);
      legacy.lock();
      await vault.load();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('lock-migrate-note')),
        findsOne,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('lock-master')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('lock-submit')));
      await settle(tester);
      expect(vault.isProtected, isTrue);
      expect(
        find.byKey(const ValueKey<String>('recovery-code-view')),
        findsOne,
      );
      expect(shownCode(tester), hasLength(29));
      await finish(tester);
    });
  });

  group('вход в сейф в настройках', () {
    testWidgets('включить ПИН-код: дважды, слабый не принимается',
        (WidgetTester tester) async {
      big(tester);
      makeKit(key: FakeDeviceKey(bio: false));
      await seed();
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('prefs-vault-bio')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('prefs-vault-pin')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('new-pin-dialog')), findsOne);
      await typePin(tester, '111111');
      expect(find.text('Все цифры одинаковые — так легко угадать.'), findsOne);
      await typePin(tester, canaryPin());
      await typePin(tester, canaryPin());
      expect(vault.protection!.pin, isTrue);
      expect(vault.protection!.device, isFalse);
      expect(
        find.byKey(const ValueKey<String>('new-pin-dialog')),
        findsNothing,
      );
      await finish(tester);
    });

    testWidgets('выключить ПИН-код — подтверждение ПИН-кодом',
        (WidgetTester tester) async {
      big(tester);
      makeKit(key: FakeDeviceKey(bio: false));
      await seed();
      await vault.enablePin(secret(canaryPin()));
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('prefs-vault-pin')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('vault-confirm')), findsOne);
      await typePin(tester, wrongPin());
      expect(vault.protection!.pin, isTrue);
      expect(find.text('ПИН-код не подошёл.'), findsOneWidget);
      await typePin(tester, canaryPin());
      expect(vault.protection!.pin, isFalse);
      expect(vault.protection!.device, isTrue);
      await finish(tester);
    });

    testWidgets('сейф по отпечатку — виден, где есть биометрия',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('prefs-vault-bio')), findsOne);
      expect(find.text('Сейф по отпечатку / Face ID'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('prefs-vault-bio')));
      await settle(tester);
      expect(vault.protection!.bio, isTrue);
      expect(device.prompts, 1);
      await finish(tester);
    });

    testWidgets('ПИН-код там, где ключ лежит файлом, не включить',
        (WidgetTester tester) async {
      big(tester);
      makeKit(
        key: FakeDeviceKey(kind: 'file-key', pinAllowed: false, bio: false),
      );
      await seed();
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await settle(tester);
      final pin = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey<String>('prefs-vault-pin')),
      );
      expect(pin.onChanged, isNull);
      expect(find.textContaining('перебрали бы'), findsOneWidget);
      await finish(tester);
    });
  });

  group('подтверждение', () {
    Widget confirmButton(ValueChanged<bool> done) => Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              key: const ValueKey<String>('ask'),
              onPressed: () async => done(
                await askVaultConfirm(
                  context,
                  kit: kit,
                  title: 'Проверка',
                  check: kit.confirmProof,
                ),
              ),
              child: const Text('Спросить'),
            ),
          ),
        );

    testWidgets('только устройство: системный запрос блокировки экрана',
        (WidgetTester tester) async {
      big(tester);
      makeKit(withAuth: FakeAuth(status_: _withLock));
      await seed();
      bool? result;
      await tester.pumpWidget(app(confirmButton((bool v) => result = v)));
      await tester.tap(find.byKey(const ValueKey<String>('ask')));
      await settle(tester);
      expect(auth.asked, 1);
      expect(result, isTrue);
      auth.next = DeviceAuthResult.canceled;
      await tester.tap(find.byKey(const ValueKey<String>('ask')));
      await settle(tester);
      expect(result, isFalse);
      await finish(tester);
    });

    testWidgets('вместо ПИН-кода — подтверждение кодом восстановления',
        (WidgetTester tester) async {
      big(tester);
      makeKit(key: FakeDeviceKey(bio: false));
      final code = await seed();
      await vault.enablePin(secret(canaryPin()));
      bool? result;
      await tester.pumpWidget(app(confirmButton((bool v) => result = v)));
      await tester.tap(find.byKey(const ValueKey<String>('ask')));
      await settle(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('vault-confirm-use-code')),
      );
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('vault-confirm-code')),
        code,
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('vault-confirm-submit')));
      await settle(tester);
      expect(result, isTrue);
      await finish(tester);
    });
  });

  group('SecretGuard', () {
    test('код восстановления скрывается всегда', () {
      final result = SecretGuard.redact(
        'мой код abcde-fgh01-jkmnp-qrstv-wxyz0 запиши',
      );
      expect(result.guarded, isTrue);
      expect(result.text, isNot(contains('abcde')));
    });

    testWidgets('ПИН-код после верного ввода скрывается, чужие цифры — нет',
        (WidgetTester tester) async {
      makeKit(key: FakeDeviceKey(bio: false));
      await seed();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device);
      expect(
        again.matchesKnownSecret(canaryPin()),
        isFalse,
        reason: 'до ввода не узнать',
      );
      await again.unlockPin(secret(canaryPin()));
      again.lock();
      final guarded = SecretGuard.redact(
        'вот ${canaryPin()}',
        known: again.matchesKnownSecret,
      );
      expect(guarded.guarded, isTrue);
      expect(guarded.text, isNot(contains(canaryPin())));
      expect(
        SecretGuard.redact('вот ${wrongPin()}', known: again.matchesKnownSecret)
            .guarded,
        isFalse,
      );
      kit.dispose();
    });
  });

  group('вход в приложение', () {
    testWidgets('закрыто при запуске; системный запрос открывает',
        (WidgetTester tester) async {
      final fake = FakeAuth(status_: _withLock);
      final lock = AppLockController(auth: fake, enabled: true);
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              AppLockGate(controller: lock, child: child!),
          home: const Scaffold(body: Text('содержимое')),
        ),
      );
      expect(find.byKey(const ValueKey<String>('app-lock')), findsOne);
      expect(find.text('содержимое', skipOffstage: true), findsNothing);
      await tester.pump();
      await tester.pump();
      expect(fake.asked, 1);
      await tester.pump();
      expect(lock.locked, isFalse);
      expect(find.text('содержимое'), findsOne);
      lock.dispose();
    });

    testWidgets('после фона: дольше срока — снова закрыто, раньше — нет',
        (WidgetTester tester) async {
      final fake = FakeAuth(status_: _withLock);
      final watch = _FakeStopwatch();
      final lock = AppLockController(
        auth: fake,
        enabled: true,
        stopwatch: watch,
      );
      await lock.unlock();
      expect(lock.locked, isFalse);
      lock.onAppState(AppLifecycleState.paused);
      watch.add(const Duration(seconds: 30));
      lock.onAppState(AppLifecycleState.resumed);
      expect(lock.locked, isFalse);
      lock.onAppState(AppLifecycleState.paused);
      watch.add(const Duration(seconds: 61));
      lock.onAppState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
      // Блокировку экрана убрали — замок выключается сам.
      fake.status_ = const DeviceAuthStatus(supported: true);
      var disabled = false;
      await lock.unlock(onDisabled: () => disabled = true);
      expect(disabled, isTrue);
      expect(lock.locked, isFalse);
      expect(lock.enabled, isFalse);
      lock.dispose();
    });

    testWidgets('системный запрос не считается уходом в фон',
        (WidgetTester tester) async {
      final watch = _FakeStopwatch();
      final lock = AppLockController(
        auth: FakeAuth(status_: _withLock),
        enabled: true,
        after: Duration.zero,
        stopwatch: watch,
      );
      await lock.unlock();
      await SystemAuthGuard.run(() async {
        lock.onAppState(AppLifecycleState.paused);
        watch.add(const Duration(seconds: 5));
        lock.onAppState(AppLifecycleState.resumed);
      });
      expect(lock.locked, isFalse);
      lock.dispose();
    });

    testWidgets('переключатель виден только с блокировкой экрана',
        (WidgetTester tester) async {
      var settings = const AppSettings();
      Widget section(FakeAuth fake) => MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter set) =>
                    SecuritySection(
                  key: ObjectKey(fake),
                  settings: settings,
                  onChanged: (AppSettings next) => set(() => settings = next),
                  lock: AppLockController(auth: fake),
                ),
              ),
            ),
          );
      await tester.pumpWidget(section(FakeAuth()));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('setting-app-lock')),
        findsNothing,
      );
      final fake = FakeAuth(status_: _withLock)
        ..next = DeviceAuthResult.canceled;
      await tester.pumpWidget(section(fake));
      await tester.pump();
      expect(
        find.text('Вход в приложение по отпечатку / Face ID'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('setting-app-lock')));
      await tester.pump();
      await tester.pump();
      expect(settings.appLock, isFalse, reason: 'без проверки не включается');
      fake.next = DeviceAuthResult.ok;
      await tester.tap(find.byKey(const ValueKey<String>('setting-app-lock')));
      await tester.pump();
      await tester.pump();
      expect(settings.appLock, isTrue);
      expect(
        find.byKey(const ValueKey<String>('setting-app-lock-after-300')),
        findsOne,
      );
      expect(AppSettings.fromJson(settings.toJson()).appLock, isTrue);
    });
  });

  group('удобство экранов сейфа', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    testWidgets('пауза ПИН-кода: кнопки не нажимаются, отсчёт идёт',
        (WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      var now = DateTime(2026, 11, 14, 12);
      final until = now.add(const Duration(seconds: 3));
      var ended = 0;
      var sent = 0;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Center(
              child: PinPad(
                until: until,
                now: () => now,
                onPauseEnd: () => ended++,
                onComplete: (_) async => sent++,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('через 0:03'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('pin-pad-1')));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('Введено 0 из 6')), findsOne);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('через 0:02'), findsOneWidget);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(ended, 1);
      expect(find.textContaining('Следующая попытка'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('pin-pad-1')));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('Введено 1 из 6')), findsOne);
      expect(sent, 0);
      handle.dispose();
    });

    testWidgets('320×640, шрифт 130 %: ошибка целиком, «0» и «стереть» видны',
        (WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: PinPad(
                error: 'Все цифры одинаковые — так легко угадать.',
                onComplete: (_) async {},
              ),
            ),
          ),
        ),
      );
      final error = find.byKey(const ValueKey<String>('pin-error'));
      final paragraph = tester.renderObject<RenderBox>(
        find.descendant(of: error, matching: find.byType(RichText)),
      );
      // Высота абзаца — как у текста целиком, ничего не срезано.
      expect(
        tester.getBottomLeft(error).dy,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byKey(const ValueKey<String>('pin-pad-1'))).dy,
        ),
      );
      expect(paragraph.size.height, greaterThan(20));
      for (final key in <String>['pin-pad-0', 'pin-pad-back']) {
        expect(
          tester.getBottomLeft(find.byKey(ValueKey<String>(key))).dy,
          lessThanOrEqualTo(640),
          reason: key,
        );
      }
    });

    testWidgets('кнопки ПИН-кода видны в диалоге: заливка не как у окна',
        (WidgetTester tester) async {
      big(tester);
      makeKit(key: FakeDeviceKey(bio: false));
      await seed();
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('prefs-vault-pin')));
      await settle(tester);
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      final key = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('pin-pad-5')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(key.color, isNot(dialog.backgroundColor));
      await typePin(tester, canaryPin());
      await typePin(tester, canaryPin());
      expect(find.textContaining('Забудете — откроет код'), findsOneWidget);
      expect(find.textContaining('больше не откроется'), findsNothing);
      // Подпись под сейфом — о ПИН-коде, а не «включите ПИН-код».
      expect(find.textContaining('Кто держит разблокированный'), findsNothing);
      expect(find.textContaining('ПИН-кодом сейфа'), findsWidgets);
      await finish(tester);
    });

    testWidgets('замок с ПИН-кодом: подпись не зовёт включить ПИН-код',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(find.textContaining('Кто держит разблокированный'), findsNothing);
      expect(
        find.textContaining('открывается ПИН-кодом сейфа'),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('«Я сохранил»: кода на экране нет, строки через дефис',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      makeKit();
      await vault.load();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('create-submit')));
      await settle(tester);
      final rows = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('recovery-code')),
              matching: find.byType(Text),
            ),
          )
          .map((Text t) => t.data!)
          .toList();
      // Ровные строки, дефис в конце строки, а не 4 + 1.
      expect(rows.length, lessThanOrEqualTo(3));
      expect(rows.join(), hasLength(29));
      for (final row in rows.take(rows.length - 1)) {
        expect(row, endsWith('-'));
      }
      expect(rows.last.length, greaterThan(5));
      await tester
          .tap(find.byKey(const ValueKey<String>('recovery-code-saved')));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('recovery-code')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('recovery-code-copy')),
        findsNothing,
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('recovery-code-again')));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('recovery-code')), findsOne);
      await finish(tester);
    });

    testWidgets('переход с мастер-пароля: без «ADR» и лишних подписей',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final legacy = testVault(store, crypto);
      await legacy.create(secret(Canary.master), params: fastKdf);
      legacy.lock();
      await vault.load();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await settle(tester);
      expect(find.textContaining('ADR'), findsNothing);
      expect(find.textContaining('только мастер-паролем'), findsNothing);
      expect(
        find.textContaining('Сейф открывается мастер-паролем'),
        findsNothing,
      );
      await finish(tester);
    });
  });
}

final class _FakeStopwatch extends Stopwatch {
  Duration _elapsed = Duration.zero;

  void add(Duration by) => _elapsed += by;

  @override
  Duration get elapsed => _elapsed;
}
