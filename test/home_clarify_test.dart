import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final _clock = FixedClock(DateTime(2026, 11, 13, 12));

Future<AssistantController> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1300, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final assistant = AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
        PasswordsConnector(),
        const DataConnector(),
      ],
      choice: const ExtensionChoice(
        enabled: <String>{PasswordsConnector.id},
      ),
    ),
    clock: _clock,
  );
  // Навык «Пароли» включён в настройках: иначе выбирать не из чего.
  final settings = InMemorySettingsStore();
  await settings.save(
    const AppSettings(enabledExtensions: <String>{PasswordsConnector.id}),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: settings,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return assistant;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await _settle(tester);
}

void main() {
  testWidgets('вопрос с вариантами — кнопки; нажатие = набранная подпись',
      (tester) async {
    final assistant = await _pump(tester);

    await _say(tester, 'сделай бэкап');

    expect(find.text('Копию чего: паролей или всех данных?'), findsWidgets);
    final first = find.byKey(const Key('clarify-option-0'));
    final second = find.byKey(const Key('clarify-option-1'));
    expect(
      find.descendant(of: first, matching: find.text('Пароли')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.text('Все данные')),
      findsOneWidget,
    );

    await tester.tap(second);
    await _settle(tester);

    // Нажатие — обычное сообщение с подписью варианта.
    expect(find.text('Все данные'), findsWidgets);
    expect(find.textContaining('«Создать резервную копию»'), findsWidgets);
    expect(assistant.pendingClarification, isNull);
    expect(find.byKey(const Key('clarify-option-0')), findsNothing);
  });

  testWidgets('другая фраза снимает вопрос — кнопки пропадают', (tester) async {
    await _pump(tester);

    await _say(tester, 'открой хранилище');
    expect(find.byKey(const Key('clarify-option-0')), findsOneWidget);

    await _say(tester, 'покажи задачи');
    expect(find.byKey(const Key('clarify-option-0')), findsNothing);
  });

  test('варианты не пишутся в историю чата', () {
    final clarification = Clarification(
      questionId: 'data.clarify.backup',
      options: const <ClarifyOption>[
        ClarifyOption(label: 'Пароли', text: 'сделай резервную копию сейфа'),
        ClarifyOption(
          label: 'Все данные',
          text: 'сделай резервную копию всех данных',
        ),
      ],
    );
    final message = ChatMessage(
      id: 'm1',
      author: ChatAuthor.persona,
      text: 'Копию чего: паролей или всех данных?',
      timestamp: _clock.value,
      clarification: clarification,
    );
    final json = message.toJson();
    expect(json.toString(), isNot(contains('сейфа')));
    expect(ChatMessage.fromJson(json)!.clarification, isNull);
    expect(message.copyAs('m2').clarification, isNull);
    expect(
      identical(message.withLink(null).clarification, clarification),
      isTrue,
    );
  });
}
