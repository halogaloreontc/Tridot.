// «+» → «Прикрепить файл» (ADR-019): выбор файлов (подделка), чипы над
// полем, отправка без текста, ответ «сохранил в сессии», превью и чипы в
// ленте, перезапуск, удаление сессии стирает файлы, режим «Только в
// памяти», имя файла без секретов.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/attachments/attachment_picker.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Прозрачная картинка 1×1.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

final class _Source implements AttachmentSource {
  _Source(this.name, this.bytes, {this.mimeType, int? size})
      : _size = size ?? bytes.length;

  @override
  final String name;
  @override
  final String? mimeType;
  final Uint8List bytes;
  final int _size;

  @override
  Future<int> length() async => _size;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Future<void> saveTo(String path) async =>
      throw UnsupportedError('в тесте хранилище в памяти');
}

final class _Picker implements AttachmentPicker {
  List<AttachmentSource> next = <AttachmentSource>[];
  final List<PickKind> asked = <PickKind>[];

  @override
  Future<List<AttachmentSource>> pick(PickKind kind) async {
    asked.add(kind);
    final files = next;
    next = <AttachmentSource>[];
    return files;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required ChatStore store,
  required _Picker picker,
  Key? key,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = FixedClock(DateTime(2026, 11, 13, 12));
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
    ],
    clock: clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      key: key,
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: clock,
        settingsStore: InMemorySettingsStore(),
        chatStore: store,
        attachmentPicker: picker,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _attach(WidgetTester tester, PickKind kind) async {
  await tester.tap(find.byKey(const Key('templates-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('composer-attach')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('attach-${kind.name}')));
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('assistant-send')));
  await tester.pumpAndSettle();
}

void main() {
  late InMemoryAttachmentStore files;
  late InMemoryChatStore store;
  late _Picker picker;

  setUp(() {
    files = InMemoryAttachmentStore(persistent: true);
    store = InMemoryChatStore(attachments: files);
    picker = _Picker();
  });

  testWidgets('фото без текста: чип, отправка, ответ, перезапуск, удаление',
      (WidgetTester tester) async {
    await _pump(tester, store: store, picker: picker);
    picker.next = <AttachmentSource>[
      _Source('кот.png', _png, mimeType: 'image/png'),
      _Source('отчёт.pdf', Uint8List(2048)),
    ];
    await _attach(tester, PickKind.photo);
    expect(picker.asked, <PickKind>[PickKind.photo]);
    expect(find.byKey(const Key('pending-attachment-0')), findsOneWidget);
    expect(find.byKey(const Key('pending-attachment-1')), findsOneWidget);
    expect(files.paths, isEmpty, reason: 'до отправки ничего не копируется');

    // Крестик убирает файл из сообщения.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('pending-attachment-1')),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pending-attachment-1')), findsNothing);

    // Поле пустое, но с файлом — кнопка отправляет, а не включает голос.
    expect(find.byTooltip('Отправить'), findsOneWidget);
    await _send(tester);
    expect(find.byKey(const Key('pending-attachment-0')), findsNothing);
    expect(files.paths, hasLength(1));
    final sessionId = store.chatIds.single;
    final thread = (await store.loadMessages(sessionId));
    final sent = thread.firstWhere((ChatMessage m) => m.fromUser);
    expect(sent.text, isEmpty);
    expect(sent.attachments.single.name, 'кот.png');
    final answer = thread.last;
    expect(answer.fromUser, isFalse);
    expect(answer.text, contains('в этой сессии'));
    expect(answer.text, contains('1 файл'));
    expect(answer.text, contains('конвертер'));
    expect(
      find.byKey(
        ValueKey<String>('attachment-preview-${sent.attachments.single.id}'),
      ),
      findsOneWidget,
    );
    expect(find.text('Фото'), findsWidgets, reason: 'название сессии');

    // «Перезапуск»: новый экран над тем же хранилищем.
    await _pump(tester, store: store, picker: picker, key: UniqueKey());
    await tester.tap(find.byTooltip('Меню'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('chat-$sessionId')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('attachment-${sent.attachments.single.id}')),
      findsOneWidget,
    );

    // Удаление сессии стирает её файлы.
    await tester.tap(find.byKey(const Key('session-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();
    expect(store.chatIds, isEmpty);
    expect(files.paths, isEmpty);
  });

  testWidgets('файл с текстом: команда выполняется, под ответом — строка',
      (WidgetTester tester) async {
    await _pump(tester, store: store, picker: picker);
    picker.next = <AttachmentSource>[_Source('смета.xlsx', Uint8List(10))];
    await _attach(tester, PickKind.document);
    await tester.enterText(find.byKey(const Key('assistant-input')), '2+2');
    await _send(tester);
    final messages = await store.loadMessages(store.chatIds.single);
    expect(messages.first.text, '2+2');
    expect(messages.first.attachments.single.kind, AttachmentKind.document);
    expect(messages.last.text, contains('4'));
    expect(messages.last.text, contains('Файлы сохранены в этой сессии: 1'));
    expect(find.text('смета.xlsx'), findsOneWidget);
  });

  testWidgets('файл с непонятным текстом: ответ — как на одни файлы',
      (WidgetTester tester) async {
    await _pump(tester, store: store, picker: picker);
    picker.next = <AttachmentSource>[_Source('смета.xlsx', Uint8List(10))];
    await _attach(tester, PickKind.document);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Смета и эскиз',
    );
    await _send(tester);
    final messages = await store.loadMessages(store.chatIds.single);
    expect(messages.first.text, 'Смета и эскиз');
    expect(messages.last.text, startsWith('Сохранил в этой сессии 1 файл'));
    expect(messages.last.text, isNot(contains('Пока понимаю')));
    expect(messages.last.text, isNot(contains('Файлы сохранены')));
  });

  testWidgets('больше 25 МБ — понятное сообщение, файл не прикреплён',
      (WidgetTester tester) async {
    await _pump(tester, store: store, picker: picker);
    picker.next = <AttachmentSource>[
      _Source('фильм.mp4', Uint8List(1), size: AttachmentStore.maxBytes + 1),
    ];
    await _attach(tester, PickKind.video);
    expect(
      find.text('Файл больше 25 МБ — такие пока не прикрепляются'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pending-attachment-0')), findsNothing);
  });

  testWidgets('имя файла с паролем показывается без него',
      (WidgetTester tester) async {
    await _pump(tester, store: store, picker: picker);
    picker.next = <AttachmentSource>[
      _Source('пароль=Kx9#mQ2!vL7@pR4z.txt', Uint8List(4)),
    ];
    await _attach(tester, PickKind.any);
    await _send(tester);
    final messages = await store.loadMessages(store.chatIds.single);
    final name = messages.first.attachments.single.name;
    expect(name, isNot(contains('Kx9#mQ2!vL7@pR4z')));
    expect(find.textContaining('Kx9#mQ2!vL7@pR4z'), findsNothing);
  });

  testWidgets('«Только в памяти» — файлы не прикрепляются',
      (WidgetTester tester) async {
    await _pump(tester, store: InMemoryChatStore(), picker: picker);
    picker.next = <AttachmentSource>[_Source('a.txt', Uint8List(1))];
    await _attach(tester, PickKind.any);
    expect(picker.asked, isEmpty);
    expect(
      find.text('В режиме «Только в памяти» файлы не сохраняются'),
      findsOneWidget,
    );
  });

  testWidgets('«Подключить диск» → «Прикрепить файл» открывает выбор',
      (WidgetTester tester) async {
    await _pump(tester, store: store, picker: picker);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-cloud')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cloud-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cloud-disk-attach')));
    await tester.pumpAndSettle();
    expect(picker.asked, <PickKind>[PickKind.any]);
  });
}
