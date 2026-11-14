// Кто отвечает без обращения по имени (ADR-016): зона главного — Связной,
// расширения — их ведущий, оповещения — ведущий оповещений; ведущий,
// выключенный режимом, отдаёт зону Связной. Матрица: режим × помощник Дуэта ×
// переназначение обязанностей. Пароли — только канарейки.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/personas/duty_zones.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/manifest/fixtures.dart';
import '../passwords/vault_test_support.dart';

/// Ожидаемый ведущий обязанности, назначенной [assigned]: он сам, если
/// режим его включает, иначе Связной. Считается здесь независимо от
/// [PersonaCast].
String _expected(TeamMode mode, String duoHelper, String assigned) =>
    switch (mode) {
      TeamMode.trio => assigned,
      TeamMode.duo => duoHelper == assigned ? assigned : 'sado',
      TeamMode.solo => 'sado',
    };

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  setUp(PersonaCast.resetForTest);
  tearDown(PersonaCast.resetForTest);

  Future<(AssistantController, Vault)> setUpWith(
    PersonaSettings personas,
  ) async {
    final clock = TestClock(DateTime.utc(2026, 11, 10, 9));
    final vault = testVault(InMemoryVaultStore(), crypto, clock: clock);
    await vault.load();
    final facade = VaultFacade(vault);
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: FixedClock(clock.value),
    );
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: FixedClock(clock.value)),
        ),
        // Склад не подключён: ответ «ещё не подключён» — без сети.
        warehouseConnector(path: patchedManifestPath),
        PasswordsConnector(vault: facade, vaultExisted: () => true),
      ],
      choice: const ExtensionChoice(
        enabled: <String>{PasswordsConnector.id},
        enabledRoles: <String>{Roles.storekeeperId},
      ),
    );
    vault.followExtension(registry, PasswordsConnector.id);
    await vault.create(secret(Canary.master), params: fastKdf);
    await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: Canary.hint,
      password: secret(Canary.password),
    );
    final assistant = AssistantController(
      extensions: registry,
      clock: FixedClock(clock.value),
      personas: personas,
      knownSecret: facade.knownSecret,
    );
    return (assistant, vault);
  }

  test('зоны навыков', () {
    for (final id in <String>['tasks', 'calc', 'talk', 'data', 'jokes.x']) {
      expect(DutyZones.dutyOf(id), PersonaDuty.main, reason: id);
    }
    for (final id in <String>[
      'warehouse',
      'passwords',
      'converter',
      'archiver',
      'ytdl',
    ]) {
      expect(DutyZones.dutyOf(id), PersonaDuty.extensions, reason: id);
    }
  });

  final overdue = Task(
    id: 'o',
    title: 'Отчёт',
    status: TaskStatus.planned,
    priority: TaskPriority.normal,
    dueAt: DateTime(2026, 11, 1),
    duePrecision: DuePrecision.date,
    createdAt: DateTime(2026, 10, 30),
    updatedAt: DateTime(2026, 10, 30),
  );

  for (final mode in TeamMode.values) {
    for (final duoHelper in Personas.helperIds) {
      if (mode != TeamMode.duo && duoHelper != Personas.liorio.id) continue;
      for (final extensions in Personas.helperIds) {
        for (final notifications in Personas.helperIds) {
          final settings = PersonaSettings(
            teamMode: mode,
            duoHelper: duoHelper,
            dutyExtensions: extensions,
            dutyNotifications: notifications,
          );
          final label = '${mode.name}'
              '${mode == TeamMode.duo ? ' с $duoHelper' : ''}, '
              'расширения — $extensions, оповещения — $notifications';
          test(label, () async {
            final (assistant, _) = await setUpWith(settings);
            final ext = _expected(mode, duoHelper, extensions);
            final notifier = _expected(mode, duoHelper, notifications);

            final task = await assistant.handle('добавь задачу хлеб');
            expect(task.intent, 'task.create');
            expect(task.personaId, 'sado', reason: 'задачи — зона Связной');

            final store = await assistant.handle('где лежит 64115');
            expect(store.replyId, 'role.notConnected');
            expect(store.personaId, ext, reason: 'склад — расширение');
            expect(assistant.working('где лежит 64115').personaId, ext);

            final password = await assistant.handle('забыл пароль от почты');
            expect(password.intent, startsWith('passwords.'));
            expect(password.personaId, ext, reason: 'пароли — расширение');
            for (final canary in Canary.secrets) {
              expect(password.message, isNot(contains(canary)));
            }

            final line = assistant.overdueNotice(<Task>[overdue])!;
            expect(line.personaId, notifier, reason: 'просрочки — оповещения');

            expect(assistant.welcome().personaId, 'sado');
          });
        }
      }
    }
  }

  group('смена режима с экрана', () {
    test('продолжение с выключенным помощником снимается', () async {
      final (assistant, _) = await setUpWith(const PersonaSettings());
      final named = await assistant.handle('Нода, покажи задачи');
      expect(named.personaId, 'noda');
      expect(assistant.followUpPersonaId, 'noda');
      // Экран переключает на Дуэт с Лиорио (не через беседу).
      assistant.personas = assistant.personas.copyWith(
        teamMode: TeamMode.duo,
        duoHelper: 'rio',
      );
      expect(assistant.followUpPersonaId, isNull);
      final next = await assistant.handle('покажи задачи');
      expect(next.personaId, 'sado');
      expect(assistant.working('покажи задачи').personaId, 'sado');
    });

    test('«Нода» без команды, затем выключение Ноды', () async {
      final (assistant, _) = await setUpWith(const PersonaSettings());
      expect((await assistant.handle('Нода')).personaId, 'noda');
      assistant.personas = assistant.personas.copyWith(
        teamMode: TeamMode.duo,
        duoHelper: 'rio',
      );
      expect(assistant.working('добавь задачу сыр').personaId, 'sado');
      expect((await assistant.handle('добавь задачу сыр')).personaId, 'sado');
    });

    test('продолжение с активным помощником остаётся', () async {
      final (assistant, _) = await setUpWith(const PersonaSettings());
      await assistant.handle('Нода, покажи задачи');
      assistant.personas = assistant.personas.copyWith(
        teamMode: TeamMode.duo,
        duoHelper: 'noda',
      );
      expect(assistant.followUpPersonaId, 'noda');
      expect((await assistant.handle('покажи задачи')).personaId, 'noda');
    });

    test('вопрос выключенного помощника — ответ от ведущего зоны', () async {
      final (assistant, _) = await setUpWith(const PersonaSettings());
      await assistant.handle('добавь задачу купить хлеб');
      // Нода спрашивает «отметить выполненной?» по обращению.
      final asked = await assistant.handle('Нода, я купил хлеб');
      expect(asked.personaId, 'noda');
      expect(assistant.session.pendingConfirmation, isNotNull);
      assistant.personas = assistant.personas.copyWith(
        teamMode: TeamMode.duo,
        duoHelper: 'rio',
      );
      final answer = await assistant.handle('да');
      expect(answer.personaId, 'sado', reason: 'задачи — зона Связной');
    });

    test('имя выключенного помощника снимается, отвечает Связной', () async {
      final (assistant, _) = await setUpWith(
        const PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'rio'),
      );
      final response = await assistant.handle('Нода, добавь задачу хлеб');
      expect(response.personaId, 'sado');
      expect(response.addressedPersonaId, isNull);
      expect(response.message, contains('«Хлеб»'));
    });
  });
}
