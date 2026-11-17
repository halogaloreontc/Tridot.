import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/manifest/fixtures.dart';

final FixedClock _clock = FixedClock(DateTime(2026, 11, 2, 16, 30));

(ExtensionRegistry, ManifestConnector) _registry([
  ExtensionChoice choice = const ExtensionChoice(),
]) {
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final warehouse = warehouseConnector(record: connectedRecord());
  return (
    ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
        warehouse,
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
      choice: choice,
    ),
    warehouse,
  );
}

const ExtensionChoice _storekeeper =
    ExtensionChoice(enabledRoles: <String>{Roles.storekeeperId});

void main() {
  group('роли и старшинство выбора', () {
    test('по умолчанию: «Личное» включено, «Кладовщик» — нет', () {
      final (registry, _) = _registry();
      expect(registry.roles.map((RoleInfo r) => r.id), <String>[
        Roles.personalId,
        Roles.storekeeperId,
      ]);
      expect(registry.isRoleEnabled(Roles.personalId), isTrue);
      expect(registry.isRoleEnabled(Roles.storekeeperId), isFalse);
      expect(registry.isEnabled('warehouse'), isFalse);
      for (final id in <String>['tasks', 'calc', 'talk']) {
        expect(registry.isEnabled(id), isTrue, reason: id);
      }
      expect(registry.activeChips, isEmpty);
    });

    test('«Кладовщик» включает склад, кнопки и подсказки', () {
      final (registry, warehouse) = _registry();
      registry.apply(registry.roleChoiceWith(Roles.storekeeperId, true));
      expect(registry.isEnabled('warehouse'), isTrue);
      expect(
        registry.enabledConnectors.map((Connector c) => c.info.id),
        contains('warehouse'),
      );
      expect(registry.activeChips.map((RoleChip c) => c.label), <String>[
        'Где лежит…',
        'Что пришло сегодня',
        'Без фото',
      ]);
      expect(warehouse.roleHints, <String>{'bareCodes', 'bareWords'});
      // Одно название навыка везде: в карточке роли, в «Расширениях» и в
      // «что умеешь».
      expect(registry.skillTitle('warehouse'), 'Склад');

      registry.apply(registry.roleChoiceWith(Roles.storekeeperId, false));
      expect(registry.isEnabled('warehouse'), isFalse);
      expect(registry.activeChips, isEmpty);
      expect(warehouse.roleHints, isEmpty);
      expect(registry.skillTitle('warehouse'), 'Склад');
    });

    test('явное выключение важнее роли; включение снимает его', () {
      final (registry, _) = _registry(_storekeeper);
      registry.apply(registry.choiceWith('warehouse', false));
      expect(registry.choice.disabled, <String>{'warehouse'});
      expect(registry.isEnabled('warehouse'), isFalse);
      expect(registry.isRoleEnabled(Roles.storekeeperId), isTrue);
      registry.apply(registry.choiceWith('warehouse', true));
      expect(registry.choice.disabled, isEmpty);
      expect(registry.choice.enabled, isEmpty, reason: 'включает роль');
      expect(registry.isEnabled('warehouse'), isTrue);
    });

    test('enabled_extensions без роли склад не включает', () {
      final (registry, _) = _registry(
        const ExtensionChoice(enabled: <String>{'warehouse'}),
      );
      expect(registry.isEnabled('warehouse'), isFalse);
    });

    test('без «Личного»: калькулятора нет, задачи всегда, беседа — с ролью',
        () {
      final (registry, _) = _registry(
        const ExtensionChoice(disabledRoles: <String>{Roles.personalId}),
      );
      expect(registry.isEnabled('tasks'), isTrue, reason: 'ядро');
      expect(registry.isEnabled('calc'), isFalse);
      expect(registry.isEnabled('talk'), isFalse);
      registry.apply(
        registry.choice.withRole(Roles.storekeeper, true),
      );
      expect(registry.isEnabled('talk'), isTrue, reason: 'беседа в обеих');
      expect(registry.isEnabled('calc'), isFalse);
      expect(registry.activeRoleOf('talk')?.id, Roles.storekeeperId);
    });

    test('кто ведёт: обязанность навыка, режим, переназначение', () {
      final (registry, _) = _registry(_storekeeper);
      const trio = PersonaSettings();
      expect(registry.ownerFor('warehouse', trio), Personas.liorio);
      expect(registry.ownerFor('passwords', trio), Personas.liorio);
      expect(registry.ownerFor('tasks', trio), Personas.sado);
      expect(registry.ownerFor('talk', trio), Personas.sado);
      expect(registry.ownerFor('calc', trio), Personas.sado);
      expect(
        registry.ownerFor(
          'warehouse',
          trio.copyWith(teamMode: TeamMode.duo, duoHelper: Personas.noda.id),
        ),
        Personas.sado,
        reason: 'ведущий расширений выключен режимом — ведёт Связной',
      );
      // Прежний выбор ведущего роли (role_owners) на ответы не влияет.
      registry.apply(
        registry.choice.withOwner(Roles.storekeeperId, Personas.noda.id),
      );
      expect(registry.ownerFor('warehouse', trio), Personas.liorio);
      // Переназначение обязанности — влияет.
      final noda = trio.copyWith(dutyExtensions: Personas.noda.id);
      expect(registry.ownerFor('warehouse', noda), Personas.noda);
      expect(registry.ownerOf(Roles.storekeeperId, noda), Personas.noda);
      expect(registry.ownerOf(Roles.personalId, noda), Personas.sado);
      final solo = trio.copyWith(teamMode: TeamMode.solo);
      expect(registry.ownerFor('warehouse', solo), Personas.sado);
      expect(
        registry.ownerFor(
          'warehouse',
          noda.copyWith(teamMode: TeamMode.duo, duoHelper: Personas.liorio.id),
        ),
        Personas.sado,
        reason: 'ведущая расширений Нода выключена режимом — ведёт Связной',
      );
      registry.apply(registry.choice.withOwner(Roles.storekeeperId, null));
      expect(registry.choice.roleOwners, isEmpty);
    });

    test('самоописание: с чем помогает', () {
      final (registry, _) = _registry();
      expect(registry.helpsWith, 'с задачами');
      registry.apply(registry.roleChoiceWith(Roles.storekeeperId, true));
      expect(registry.helpsWith, 'с задачами и со складом');
      registry.apply(registry.roleChoiceWith(Roles.personalId, false));
      expect(registry.helpsWith, 'со складом');
    });

    test('выбор с ролями сравнивается целиком', () {
      const a = ExtensionChoice(enabledRoles: <String>{'storekeeper'});
      expect(a.sameAs(const ExtensionChoice()), isFalse);
      expect(
        a.sameAs(const ExtensionChoice(enabledRoles: <String>{'storekeeper'})),
        isTrue,
      );
      expect(
        a.withOwner('storekeeper', 'noda').sameAs(a),
        isFalse,
      );
    });

    test('роль без своих расширений в сборке не показывается', () {
      final registry = ExtensionRegistry(
        connectors: <Connector>[const CalculatorConnector()],
      );
      expect(registry.roles.map((RoleInfo r) => r.id), <String>[
        Roles.personalId,
      ]);
    });
  });

  group('роли в settings.json', () {
    test('туда и обратно; пустые владельцы не пишутся', () {
      const settings = AppSettings(
        enabledRoles: <String>{Roles.storekeeperId},
        disabledRoles: <String>{Roles.personalId},
        roleOwners: <String, String>{Roles.storekeeperId: 'noda'},
      );
      final json = settings.toJson();
      expect(json['enabled_roles'], <String>['storekeeper']);
      expect(json['disabled_roles'], <String>['personal']);
      expect(json['role_owners'], <String, String>{'storekeeper': 'noda'});
      final back = AppSettings.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(back.enabledRoles, settings.enabledRoles);
      expect(back.disabledRoles, settings.disabledRoles);
      expect(back.roleOwners, settings.roleOwners);
      expect(back.extensionChoice.sameAs(settings.extensionChoice), isTrue);
      expect(const AppSettings().toJson().containsKey('role_owners'), isFalse);
    });

    test('битые значения — пусто, неизвестный помощник отбрасывается', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'enabled_roles': 'storekeeper',
        'disabled_roles': <Object?>[1, null, '', 'personal'],
        'role_owners': <String, Object?>{
          'storekeeper': 'nobody',
          'personal': 3,
          'x' * 65: 'noda',
          'ok': 'noda',
        },
      });
      expect(settings.enabledRoles, isEmpty);
      expect(settings.disabledRoles, <String>{'personal'});
      expect(settings.roleOwners, <String, String>{'ok': 'noda'});
      expect(
        AppSettings.fromJson(<String, dynamic>{'role_owners': <Object?>[]})
            .roleOwners,
        isEmpty,
      );
    });

    test('файл до ролей: подключённый склад включает «Кладовщика» один раз',
        () {
      final legacy = AppSettings.fromJson(<String, dynamic>{
        'enabled_extensions': <String>['warehouse'],
      });
      expect(legacy.enabledRoles, <String>{Roles.storekeeperId});
      final (registry, _) = _registry(legacy.extensionChoice);
      expect(registry.isEnabled('warehouse'), isTrue);

      // Человек выключил роль: после перезапуска она не включается снова.
      final off = legacy.withChoice(
        legacy.extensionChoice.withRole(Roles.storekeeper, false),
      );
      final reread = AppSettings.fromJson(
        jsonDecode(jsonEncode(off.toJson())) as Map<String, dynamic>,
      );
      expect(reread.enabledRoles, isEmpty);
      expect(
        AppSettings.fromJson(const <String, dynamic>{}).enabledRoles,
        isEmpty,
      );
    });

    test('сохранение ролей не трогает задачи и остальные настройки', () async {
      final folder = await Directory.systemTemp.createTemp('roles_');
      addTearDown(() => folder.delete(recursive: true));
      final tasks = File('${folder.path}/tasks.json');
      await tasks.writeAsString('{"tasks": []}');
      final before = await tasks.readAsBytes();
      final store = JsonSettingsStore('${folder.path}/settings.json');
      const base = AppSettings(
        reduceMotion: true,
        disabledExtensions: <String>{'calc'},
        personas: PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda'),
      );
      await store.save(base);
      final changed = base.withChoice(
        base.extensionChoice
            .withRole(Roles.storekeeper, true)
            .withOwner(Roles.storekeeperId, 'rio'),
      );
      await store.save(changed);
      final loaded = await store.load();
      expect(loaded.reduceMotion, isTrue);
      expect(loaded.disabledExtensions, <String>{'calc'});
      expect(loaded.personas, base.personas);
      expect(loaded.enabledRoles, <String>{Roles.storekeeperId});
      expect(loaded.roleOwners, <String, String>{Roles.storekeeperId: 'rio'});
      expect(await tasks.readAsBytes(), before);
    });
  });
}
