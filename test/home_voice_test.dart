import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/app/widgets/command_highlight.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

import 'support/fake_voice.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

const _phone = Size(390, 844);
const _desktop = Size(1300, 900);

const _mic = Key('assistant-voice');
const _inputKey = Key('assistant-input');

/// Голосовой ввод на главном экране (ADR-023) с подделками распознавателя
/// и загрузчика.
final class _Rig {
  _Rig(this.voice, this.recognizer, this.downloader, this.store);

  final VoiceKit voice;
  final FakeVoiceRecognizer recognizer;
  final FakeFileDownloader downloader;
  final InMemorySettingsStore store;
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Size size = _phone,
  AppSettings settings = const AppSettings(),
  bool installed = false,
  String? sha,
  FakeVoiceRecognizer? recognizer,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final temp = Directory.systemTemp.createTempSync('home_voice_test');
  addTearDown(() => temp.deleteSync(recursive: true));
  final dir = p.join(temp.path, 'assistant', 'voice');
  final bytes = List<int>.generate(4000, (int i) => i % 251);
  final spec = fakeVoiceSpec(bytes, sha: sha);
  if (installed) installFakeModelSync(dir, spec);
  final fakeRecognizer = recognizer ?? FakeVoiceRecognizer();
  final downloader = FakeFileDownloader(bytes);
  final voice = fakeVoiceKit(
    recognizer: fakeRecognizer,
    downloader: downloader,
    spec: spec,
    dir: dir,
  );
  addTearDown(voice.dispose);
  await tester.runAsync(voice.refresh);
  final store = InMemorySettingsStore();
  await store.save(settings);
  final tasks = TaskService(
    repository: InMemoryTaskRepository(),
    clock: _clock,
  );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
    ],
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: store,
        voice: voice,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Rig(voice, fakeRecognizer, downloader, store);
}

/// Готов к разговору: включён, модель есть, про микрофон уже объяснено.
const _ready = AppSettings(voiceInput: true, voiceMicExplained: true);

String _inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_inputKey)).controller!.text;

CommandInputController _input(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_inputKey)).controller!
        as CommandInputController;

/// Нажатие на микрофон: начать или закончить.
Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.byKey(_mic));
  await tester.pump();
  await tester.pump();
}

/// Ctrl+Shift+M с аппаратной клавиатуры.
Future<void> _shortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.pump();
}

/// Долгое нажатие пальцем на поле ввода.
Future<void> _longPressInput(WidgetTester tester) async {
  await tester.longPress(find.byKey(_inputKey));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('без движка распознавания микрофона нет', (tester) async {
    await _pump(
      tester,
      recognizer: FakeVoiceRecognizer(support: VoiceSupport.unsupported),
    );
    expect(find.byKey(_mic), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
  });

  testWidgets('выключен: микрофон предлагает включить, «Не сейчас» — ничего',
      (tester) async {
    final rig = await _pump(tester);
    expect(find.byKey(_mic), findsOneWidget);
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    expect(find.text('Включить голосовой ввод?'), findsOneWidget);
    // Размер и источник — из закреплённой модели, а не отдельной цифрой.
    expect(find.textContaining('МБ) с сайта example.invalid'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-offer-later')));
    await tester.pumpAndSettle();
    expect(rig.downloader.calls, 0);
    expect(rig.recognizer.startCalls, 0);
    expect((await rig.store.load()).voiceInput, isFalse);
  });

  testWidgets('«Скачать»: ход загрузки, затем «Голосовой ввод готов»',
      (tester) async {
    final rig = await _pump(tester);
    final gate = Completer<void>();
    rig.downloader
      ..preamble = const <DownloadProgress>[
        DownloadProgress(12 * 1024 * 1024, 44 * 1024 * 1024),
      ]
      ..gate = gate;
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-offer-download')));
    await tester.pump();
    await pumpUntilVoice(
      tester,
      () => rig.voice.received == 12 * 1024 * 1024,
    );
    await tester.pump();
    expect(find.byKey(const Key('voice-install-sheet')), findsOneWidget);
    expect(find.textContaining('12 из 44 МБ'), findsOneWidget);
    expect(find.byKey(const Key('voice-cancel')), findsOneWidget);
    // Включено сразу и сохранено.
    expect((await rig.store.load()).voiceInput, isTrue);

    gate.complete();
    await pumpUntilVoice(tester, () => rig.voice.isInstalled);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-install-sheet')), findsNothing);
    expect(find.text('Голосовой ввод готов'), findsOneWidget);
    expect(rig.recognizer.startCalls, 0);
  });

  testWidgets(
      'лист загрузки можно скрыть: загрузка продолжается, о '
      'готовности скажет поле', (tester) async {
    final rig = await _pump(tester);
    final gate = Completer<void>();
    rig.downloader
      ..gate = gate
      ..gateFrom = 1;
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-offer-download')));
    await tester.pump();
    await pumpUntilVoice(tester, () => rig.voice.received > 0);
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-sheet-hide')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-install-sheet')), findsNothing);
    expect(rig.voice.isBusy, isTrue);
    expect((await rig.store.load()).voiceInput, isTrue);

    gate.complete();
    await pumpUntilVoice(tester, () => rig.voice.isInstalled);
    await tester.pump();
    expect(find.text('Голосовой ввод готов'), findsOneWidget);
  });

  testWidgets('контрольная сумма не совпала — ошибка и «Повторить»',
      (tester) async {
    final rig = await _pump(tester, sha: '0' * 64);
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-offer-download')));
    await tester.pump();
    await pumpUntilVoice(
      tester,
      () => rig.voice.phase == VoiceKitPhase.error,
    );
    await tester.pump();
    expect(find.byKey(const Key('voice-error')), findsOneWidget);
    expect(find.textContaining('контрольная сумма не совпала'), findsOneWidget);
    expect(find.byKey(const Key('voice-retry')), findsOneWidget);
    expect(rig.voice.isInstalled, isFalse);

    await tester.tap(find.byKey(const Key('voice-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-install-sheet')), findsNothing);
  });

  testWidgets('«Отмена» во время загрузки: выключен, скачанное сохранено',
      (tester) async {
    final rig = await _pump(tester);
    rig.downloader
      ..gate = Completer<void>()
      ..gateFrom = 1;
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-offer-download')));
    await tester.pump();
    await pumpUntilVoice(tester, () => rig.voice.received > 0);
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-cancel')));
    await tester.pump();
    await pumpUntilVoice(
      tester,
      () => rig.voice.phase == VoiceKitPhase.notInstalled,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-install-sheet')), findsNothing);
    expect(find.textContaining('Загрузка остановлена'), findsOneWidget);
    expect(rig.voice.hasPartial, isTrue);
    expect((await rig.store.load()).voiceInput, isFalse);
    // Микрофон снова предлагает включить (уведомление уже скрылось).
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    expect(find.text('Включить голосовой ввод?'), findsOneWidget);
  });

  testWidgets(
      'нажатие начинает, повторное заканчивает: серый промежуточный '
      'текст, затем текст в поле', (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await _tapMic(tester);
    expect(rig.recognizer.permissionCalls, 1);
    expect(rig.recognizer.loadCalls, 1);
    expect(rig.recognizer.isListening, isTrue);
    // Слушает — красный «стоп» на месте микрофона, крестик на месте «+».
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byKey(const Key('voice-abort')), findsOneWidget);
    expect(find.byKey(const Key('templates-button')), findsNothing);

    rig.recognizer.emit(const VoicePartial('покажи'));
    await tester.pump();
    final partial = tester.widget<Text>(find.byKey(const Key('voice-partial')));
    expect(partial.data, 'Покажи');
    expect(partial.style?.color, AssistantColors.muted);
    // Промежуточное — не в поле.
    expect(_inputText(tester), isEmpty);

    rig.recognizer
      ..emit(const VoicePartial('покажи задачи'))
      ..finalText = 'покажи   задачи';
    await tester.pump();
    // Держать не нужно: палец давно убран, а микрофон слушает.
    await tester.pump(const Duration(seconds: 3));
    expect(rig.recognizer.isListening, isTrue);
    await _tapMic(tester);
    expect(rig.recognizer.stopCalls, 1);
    expect(rig.recognizer.cancelCalls, 0);
    expect(find.byKey(const Key('voice-partial')), findsNothing);
    expect(_inputText(tester), 'Покажи задачи');
    // Подсветка команды, как у набранного текста.
    await tester.pump(const Duration(milliseconds: 200));
    expect(_input(tester).spans, isNotEmpty);
    // Ничего не отправлено: текст ждёт правки, на месте микрофона —
    // отправка, «+» вернулся.
    expect(find.byKey(const Key('assistant-send')), findsOneWidget);
    expect(find.byKey(const Key('templates-button')), findsOneWidget);
    expect(find.byKey(const Key('voice-abort')), findsNothing);
    expect(find.text('Активных задач пока нет.'), findsNothing);
  });

  testWidgets('вид и семантика: готов, слушаю, «стоп»', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = await _pump(tester, installed: true, settings: _ready);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(_mic)),
      matchesSemantics(
        label: 'Голосовой ввод',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await _tapMic(tester);
    expect(rig.recognizer.isListening, isTrue);
    expect(find.text('Говорите…'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(_mic)),
      matchesSemantics(
        label: 'Голосовой ввод',
        value: 'слушаю',
        hint: 'нажмите, чтобы закончить',
        isButton: true,
        hasTapAction: true,
      ),
    );
    final circle = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(_mic),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(
      (circle.decoration! as BoxDecoration).color,
      AssistantColors.danger,
    );
    await _tapMic(tester);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    handle.dispose();
  });

  testWidgets('модель загружается один раз', (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    for (var i = 0; i < 2; i++) {
      await _tapMic(tester);
      rig.recognizer.finalText = '';
      await _tapMic(tester);
    }
    expect(rig.recognizer.loadCalls, 1);
    expect(rig.recognizer.startCalls, 2);
    // Пустой итог — честно «не распознано», без текста.
    expect(find.text('Не удалось распознать речь'), findsOneWidget);
  });

  testWidgets('два быстрых нажатия: начал и закончил, ничего не зависло',
      (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await tester.tap(find.byKey(_mic));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(_mic));
    await tester.pump();
    await tester.pump();
    expect(rig.recognizer.startCalls, 1);
    expect(rig.recognizer.stopCalls, 1);
    expect(rig.recognizer.isListening, isFalse);
    expect(find.text('Не удалось распознать речь'), findsOneWidget);
    expect(_inputText(tester), isEmpty);
    // Следующее нажатие снова слушает.
    await _tapMic(tester);
    expect(rig.recognizer.startCalls, 2);
    expect(rig.recognizer.isListening, isTrue);
    await _tapMic(tester);
  });

  testWidgets('крестик прерывает без текста', (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await _tapMic(tester);
    rig.recognizer
      ..emit(const VoicePartial('покажи задачи'))
      ..finalText = 'покажи задачи';
    await tester.pump();
    expect(find.byKey(const Key('voice-partial')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-abort')));
    await tester.pump();
    await tester.pump();
    expect(rig.recognizer.cancelCalls, 1);
    expect(rig.recognizer.stopCalls, 0);
    expect(rig.recognizer.isListening, isFalse);
    expect(find.byKey(const Key('voice-partial')), findsNothing);
    expect(find.byKey(const Key('voice-abort')), findsNothing);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(_inputText(tester), isEmpty);
  });

  testWidgets(
      'подсказка — над полем, а не поверх микрофона: можно сразу '
      'нажать снова', (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await _tapMic(tester);
    await _tapMic(tester);
    // Подсказка в поле ввода, всплывающего уведомления нет.
    expect(find.byKey(const Key('voice-notice')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final notice = tester.getRect(find.byKey(const Key('voice-notice')));
    final mic = tester.getRect(find.byKey(_mic));
    expect(notice.overlaps(mic), isFalse);
    // Сразу же — нажатие, и микрофон слушает.
    await _tapMic(tester);
    expect(rig.recognizer.startCalls, 2);
    expect(rig.recognizer.isListening, isTrue);
    // Пока слушает, поле говорит об этом, а подсказка уступает место.
    expect(find.text('Говорите…'), findsOneWidget);
    expect(find.text('Спросить, найти или поручить…'), findsNothing);
    rig.recognizer.emit(const VoicePartial('покажи'));
    await tester.pump();
    expect(find.byKey(const Key('voice-notice')), findsNothing);
    rig.recognizer.finalText = '';
    await _tapMic(tester);
    expect(find.text('Не удалось распознать речь'), findsOneWidget);
    // Через несколько секунд подсказка исчезает сама.
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const Key('voice-notice')), findsNothing);
  });

  testWidgets('модель загружается заранее, как только ввод включён',
      (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    expect(rig.recognizer.loadCalls, 1);
    expect(rig.recognizer.startCalls, 0);
  });

  testWidgets('нажали снова, пока модель загружалась: отмена, не слушает',
      (tester) async {
    final gate = Completer<void>();
    final rig = await _pump(
      tester,
      installed: true,
      settings: _ready,
      recognizer: FakeVoiceRecognizer()..loadGate = gate,
    );
    await _tapMic(tester);
    expect(rig.recognizer.isListening, isFalse);
    expect(find.text('Готовлю распознавание…'), findsOneWidget);
    expect(find.byKey(const Key('voice-abort')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    await _tapMic(tester);
    // Сразу снова готов: ожидание загрузки не держит экран.
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.text('Готовлю распознавание…'), findsNothing);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(rig.recognizer.startCalls, 0);
    expect(rig.recognizer.isListening, isFalse);
    expect(find.byKey(const Key('voice-notice')), findsNothing);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets(
      'фон во время загрузки модели и новое нажатие: слушает одна '
      'попытка', (tester) async {
    final gate = Completer<void>();
    final rig = await _pump(
      tester,
      installed: true,
      settings: _ready,
      recognizer: FakeVoiceRecognizer()..loadGate = gate,
    );
    await _tapMic(tester);
    // Шторка уведомлений: приложение неактивно и снова активно.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    await _tapMic(tester);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(rig.recognizer.startCalls, 1);
    expect(rig.recognizer.isListening, isTrue);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    // «Стоп» заканчивает именно эту попытку: итог приходит.
    rig.recognizer.finalText = 'покажи задачи';
    await _tapMic(tester);
    expect(rig.recognizer.stopCalls, 1);
    expect(rig.recognizer.isListening, isFalse);
    expect(_inputText(tester), 'Покажи задачи');
  });

  testWidgets('системный запрос доступа не прерывает попытку', (tester) async {
    final gate = Completer<void>();
    final rig = await _pump(
      tester,
      installed: true,
      settings: _ready,
      recognizer: FakeVoiceRecognizer()..permissionGate = gate,
    );
    await _tapMic(tester);
    // Диалог Android делает приложение неактивным.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    gate.complete();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(rig.recognizer.cancelCalls, 0);
    expect(rig.recognizer.startCalls, 1);
    expect(rig.recognizer.isListening, isTrue);
    rig.recognizer.finalText = 'покажи';
    await _tapMic(tester);
    expect(_inputText(tester), 'Покажи');
  });

  testWidgets('«Отправлять сразу»: распознанное уходит без правки',
      (tester) async {
    final rig = await _pump(
      tester,
      installed: true,
      settings: _ready.copyWith(voiceSendImmediately: true),
    );
    await _tapMic(tester);
    rig.recognizer.finalText = 'покажи задачи';
    await _tapMic(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_inputText(tester), isEmpty);
    expect(find.text('Покажи задачи'), findsWidgets);
    expect(find.text('Активных задач пока нет.'), findsOneWidget);
  });

  testWidgets('«Отправлять сразу»: фраза о сейфе остаётся в поле',
      (tester) async {
    final rig = await _pump(
      tester,
      installed: true,
      settings: _ready.copyWith(voiceSendImmediately: true),
    );
    await _tapMic(tester);
    rig.recognizer.finalText = 'покажи пароли';
    await _tapMic(tester);
    expect(_inputText(tester), 'Покажи пароли');
    expect(
      find.text('Похоже на пароль — проверьте текст и отправьте вручную'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(_inputText(tester), 'Покажи пароли');
  });

  testWidgets('нет доступа к микрофону — сообщение, не слушает',
      (tester) async {
    final rig = await _pump(
      tester,
      installed: true,
      settings: _ready,
      recognizer: FakeVoiceRecognizer(permission: VoicePermission.denied),
    );
    await _tapMic(tester);
    expect(rig.recognizer.startCalls, 0);
    expect(
      find.text('Нет доступа к микрофону. Разрешите его в настройках Android'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.byKey(const Key('voice-abort')), findsNothing);
  });

  testWidgets('первый раз — объяснение, зачем микрофон, затем запрос',
      (tester) async {
    final rig = await _pump(
      tester,
      installed: true,
      settings: const AppSettings(voiceInput: true),
    );
    await tester.tap(find.byKey(_mic));
    await tester.pumpAndSettle();
    expect(find.text('Доступ к микрофону'), findsOneWidget);
    expect(find.textContaining('никуда не отправляется'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-rationale-continue')));
    await tester.pumpAndSettle();
    expect(rig.recognizer.permissionCalls, 1);
    expect(rig.recognizer.startCalls, 0);
    expect(
      find.text('Микрофон доступен. Нажмите на него и говорите'),
      findsOneWidget,
    );
    expect((await rig.store.load()).voiceMicExplained, isTrue);
  });

  testWidgets('фон прерывает распознавание без итога', (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await _tapMic(tester);
    rig.recognizer.emit(const VoicePartial('покажи'));
    await tester.pump();
    expect(find.byKey(const Key('voice-partial')), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(rig.recognizer.cancelCalls, greaterThanOrEqualTo(1));
    expect(rig.recognizer.isListening, isFalse);
    expect(find.byKey(const Key('voice-partial')), findsNothing);
    expect(rig.recognizer.stopCalls, 0);
    expect(_inputText(tester), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    // Таймеры автостопа прерванной попытки не срабатывают позже.
    await tester.pump(const Duration(seconds: 61));
    expect(rig.recognizer.stopCalls, 0);
    expect(find.byKey(const Key('voice-notice')), findsNothing);
  });

  group('долгое нажатие на пустое поле', () {
    testWidgets('начинает голосовой ввод без клавиатуры и меню',
        (tester) async {
      final rig = await _pump(tester, installed: true, settings: _ready);
      await _longPressInput(tester);
      expect(rig.recognizer.startCalls, 1);
      expect(rig.recognizer.isListening, isTrue);
      expect(find.text('Говорите…'), findsOneWidget);
      // Поле не забрало жест: ни фокуса с клавиатурой, ни «Вставить».
      final field = tester.widget<TextField>(find.byKey(_inputKey));
      expect(field.focusNode!.hasFocus, isFalse);
      expect(find.text('Вставить'), findsNothing);
      expect(find.text('Paste'), findsNothing);
      // Заканчивает нажатие на «стоп».
      rig.recognizer.finalText = 'покажи задачи';
      await _tapMic(tester);
      expect(_inputText(tester), 'Покажи задачи');
    });

    testWidgets('с текстом — обычное выделение, голос не включается',
        (tester) async {
      final rig = await _pump(tester, installed: true, settings: _ready);
      await tester.enterText(find.byKey(_inputKey), 'покажи задачи');
      await tester.pump();
      await tester.longPress(find.byKey(_inputKey));
      await tester.pumpAndSettle();
      expect(rig.recognizer.startCalls, 0);
      // Слово под пальцем выделено, меню поля открыто.
      final selection = _input(tester).selection;
      expect(selection.isCollapsed, isFalse);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    });

    testWidgets('первая буква не сбрасывает фокус и клавиатуру',
        (tester) async {
      await _pump(tester, installed: true, settings: _ready);
      await tester.tap(find.byKey(_inputKey));
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(_inputKey));
      final node = field.focusNode!;
      expect(node.hasFocus, isTrue);
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      tester.testTextInput.enterText('п');
      await tester.pump();
      expect(node.hasFocus, isTrue);
      // Тот же State поля: TextField не пересоздан.
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editable),
      );
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.enterText('');
      await tester.pump();
      expect(node.hasFocus, isTrue);
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editable),
      );
    });

    testWidgets('выключенный голосовой ввод не перехватывает жест',
        (tester) async {
      final rig = await _pump(tester);
      await _longPressInput(tester);
      await tester.pumpAndSettle();
      expect(find.text('Включить голосовой ввод?'), findsNothing);
      expect(rig.recognizer.startCalls, 0);
    });

    testWidgets('мышью — обычное долгое нажатие', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final rig = await _pump(
          tester,
          size: _desktop,
          installed: true,
          settings: _ready,
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(_inputKey)),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(seconds: 1));
        await gesture.up();
        await tester.pump();
        expect(rig.recognizer.startCalls, 0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('автостоп', () {
    testWidgets('8 с тишины после речи: стоп с итогом и подсказка',
        (tester) async {
      final rig = await _pump(tester, installed: true, settings: _ready);
      await _tapMic(tester);
      rig.recognizer
        ..emit(const VoicePartial('покажи'))
        ..finalText = 'покажи задачи';
      await tester.pump();
      // Новые слова продлевают ожидание.
      await tester.pump(const Duration(seconds: 7));
      rig.recognizer.emit(const VoicePartial('покажи задачи'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 7));
      expect(rig.recognizer.isListening, isTrue);
      // Тот же промежуточный текст — не речь.
      rig.recognizer.emit(const VoicePartial('покажи задачи'));
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      await tester.pump();
      expect(rig.recognizer.stopCalls, 1);
      expect(rig.recognizer.cancelCalls, 0);
      expect(rig.recognizer.isListening, isFalse);
      expect(_inputText(tester), 'Покажи задачи');
      expect(
        find.text('Микрофон выключен: долго не было речи'),
        findsOneWidget,
      );
    });

    testWidgets('10 с без речи: стоп, «речи не слышно»', (tester) async {
      final rig = await _pump(tester, installed: true, settings: _ready);
      await _tapMic(tester);
      await tester.pump(const Duration(seconds: 9));
      expect(rig.recognizer.isListening, isTrue);
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      await tester.pump();
      expect(rig.recognizer.stopCalls, 1);
      expect(rig.recognizer.isListening, isFalse);
      expect(_inputText(tester), isEmpty);
      expect(find.text('Микрофон выключен: речи не слышно'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });

    testWidgets('минута речи без пауз: стоп с итогом', (tester) async {
      final rig = await _pump(tester, installed: true, settings: _ready);
      await _tapMic(tester);
      rig.recognizer.finalText = 'покажи задачи';
      for (var i = 1; i <= 12; i++) {
        rig.recognizer.emit(VoicePartial('слово ' * i));
        await tester.pump(const Duration(seconds: 5));
      }
      await tester.pump();
      expect(rig.recognizer.stopCalls, 1);
      expect(rig.recognizer.isListening, isFalse);
      expect(find.text('Микрофон выключен: прошла минута'), findsOneWidget);
      expect(_inputText(tester), 'Покажи задачи');
    });

    testWidgets('итог похож на пароль — предупреждение важнее', (tester) async {
      final rig = await _pump(
        tester,
        installed: true,
        settings: _ready.copyWith(voiceSendImmediately: true),
      );
      await _tapMic(tester);
      rig.recognizer
        ..emit(const VoicePartial('покажи'))
        ..finalText = 'покажи пароли';
      await tester.pump();
      await tester.pump(const Duration(seconds: 8, milliseconds: 100));
      await tester.pump();
      expect(_inputText(tester), 'Покажи пароли');
      expect(
        find.text('Похоже на пароль — проверьте текст и отправьте вручную'),
        findsOneWidget,
      );
    });
  });

  testWidgets('телефон с клавиатурой: Ctrl+Shift+M начинает и заканчивает',
      (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await _shortcut(tester);
    expect(rig.recognizer.isListening, isTrue);
    rig.recognizer.finalText = 'покажи';
    await _shortcut(tester);
    expect(rig.recognizer.stopCalls, 1);
    expect(_inputText(tester), 'Покажи');
  });

  testWidgets('компьютер: нажатие начинает и заканчивает, Ctrl+Shift+M тоже',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final rig = await _pump(
        tester,
        size: _desktop,
        installed: true,
        settings: _ready,
      );
      await _tapMic(tester);
      expect(rig.recognizer.isListening, isTrue);
      rig.recognizer
        ..emit(const VoicePartial('покажи'))
        ..finalText = 'покажи';
      await tester.pump();
      expect(find.byKey(const Key('voice-partial')), findsOneWidget);
      await _tapMic(tester);
      expect(rig.recognizer.stopCalls, 1);
      expect(_inputText(tester), 'Покажи');

      // С черновиком микрофона нет, но сочетание клавиш работает и
      // дописывает через пробел.
      expect(find.byKey(_mic), findsNothing);
      await _shortcut(tester);
      expect(rig.recognizer.startCalls, 2);
      expect(rig.recognizer.isListening, isTrue);
      rig.recognizer.finalText = 'задачи';
      await _shortcut(tester);
      expect(rig.recognizer.stopCalls, 2);
      expect(_inputText(tester), 'Покажи задачи');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('набранный текст по-прежнему отправляется стрелкой',
      (tester) async {
    final rig = await _pump(tester, installed: true, settings: _ready);
    await tester.enterText(find.byKey(_inputKey), 'Покажи задачи');
    await tester.pump();
    expect(find.byKey(_mic), findsNothing);
    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Активных задач пока нет.'), findsOneWidget);
    expect(rig.recognizer.startCalls, 0);
  });
}
