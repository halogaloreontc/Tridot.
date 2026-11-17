// Навык «Загрузчик видео» (ADR-024, шаг 3): какие фразы его, ссылка — только
// в поле карточки (не в тексте ответа, не в ошибке, не в журнале), формат
// из фразы, форма с полями ссылки и формата, выключенный навык и сборка
// для Google Play.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/build_flags.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:local_assistant/core/commands/command_catalog.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_unavailable.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final DateTime _now = DateTime(2026, 11, 14, 10);

const String _url = 'https://example.com/v/секрет-123?t=42';

String? _format(String text) {
  final match = YtdlConnector().match(Utterance.analyze(text, now: _now));
  if (match == null) return null;
  return (match.payload! as (String, String?)).$1;
}

AssistantController _assistant({
  bool enabled = true,
  YtdlUnavailableReason? unavailable,
}) {
  final clock = FixedClock(_now);
  return AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: TaskService(
            repository: InMemoryTaskRepository(),
            clock: clock,
          ),
          parser: ScenarioParser(clock: clock),
        ),
        ConverterConnector(),
        TalkConnector(),
        if (unavailable == null)
          YtdlConnector()
        else
          YtdlUnavailableConnector(unavailable),
      ],
      choice: ExtensionChoice(
        enabled: <String>{
          ConverterConnector.id,
          if (enabled) YtdlConnector.id,
        },
      ),
    ),
    clock: clock,
  );
}

ExtensionCard _card({String? url, String format = YtdlFormats.video720}) =>
    ExtensionCard(
      id: 'j1_0',
      extensionId: YtdlConnector.id,
      updatedAt: _now,
      values: <String, Object?>{
        if (url != null) 'url': url,
        'format': format,
      },
    );

void main() {
  group('фразы', () {
    test('глагол и объект или ссылка', () {
      expect(_format('скачай видео по ссылке $_url'), YtdlPhrases.unspecified);
      expect(_format('скачай ролик https://youtu.be/abc'), isNotNull);
      expect(_format('скачай видео'), YtdlPhrases.unspecified);
      expect(_format('скачай https://youtu.be/abc'), isNotNull);
      expect(_format('сохрани видео $_url'), isNotNull);
      expect(_format('загрузи клип $_url'), isNotNull);
      expect(_format('Пожалуйста, скачай видос $_url'), isNotNull);
    });

    test('формат из фразы', () {
      expect(_format('скачай звук из видео $_url'), YtdlFormats.audio);
      expect(_format('скачай mp3 $_url'), YtdlFormats.audio);
      expect(_format('скачай видео в 1080p $_url'), YtdlFormats.video1080);
      expect(_format('скачай видео 480 $_url'), YtdlFormats.video480);
    });

    test('не его фразы', () {
      for (final text in <String>[
        'https://youtu.be/abc',
        'скачать музыку',
        'скачать видео',
        'скачай музыку',
        'скачай приложение',
        'напомни скачать видео завтра',
        'добавь задачу скачать видео $_url',
        'видеозвонок',
        'сохрани видео в mp3',
        'загрузи видео',
        'загрузи видео на ютуб $_url',
        'я скачал файл с паролями',
      ]) {
        expect(_format(text), isNull, reason: text);
      }
    });

    test('ссылка: только http(s), без хвостовой пунктуации', () {
      expect(
        YtdlUrl.find('вот: https://youtu.be/abc.'),
        'https://youtu.be/abc',
      );
      expect(
        YtdlUrl.find('(https://example.com/a?b=1)'),
        'https://example.com/a?b=1',
      );
      expect(YtdlUrl.find('ftp://example.com/a'), isNull);
      expect(YtdlUrl.find('без ссылки'), isNull);
      expect(YtdlUrl.valid('https://${'a' * 3000}.com'), isFalse);
    });

    test('конвертер не берёт фразы со ссылкой', () {
      expect(
        ConverterConnector().match(
          Utterance.analyze('сохрани видео $_url в mp3', now: _now),
        ),
        isNull,
      );
    });
  });

  group('карточка', () {
    test('ссылка — только в поле карточки, не в тексте ответа', () async {
      final printed = <String>[];
      final response = await runZoned(
        () => _assistant().handle('Лиорио, скачай видео по ссылке $_url'),
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
              printed.add(line),
        ),
      );
      final card = response.job!;
      expect(card.extensionId, YtdlConnector.id);
      expect(card.values['url'], _url);
      expect(card.choice('format'), YtdlFormats.fallback);
      expect(response.intent, YtdlConnector.downloadCommand);
      expect(response.personaId, 'rio');
      expect(response.message, isNot(contains('example.com')));
      expect(response.message, isNot(contains('секрет')));
      expect(response.message, contains('Скачать'));
      // Журнала нет: ничего не печатается.
      expect(printed.where((String l) => l.contains('example.com')), isEmpty);
    });

    test('без ссылки — пустое поле; звук из фразы', () async {
      final empty = await _assistant().handle('скачай видео');
      expect(empty.job!.values['url'], isNull);
      expect(empty.message, contains('ссылку'));
      final audio = await _assistant().handle('скачай звук из видео $_url');
      expect(audio.job!.choice('format'), YtdlFormats.audio);
    });

    test('карточка из «+» — пустая форма от Лиорио', () {
      final response = _assistant().openForm(YtdlConnector.id)!;
      expect(response.job!.values['url'], isNull);
      expect(response.personaId, 'rio');
    });

    test('выключен — подсказка, где включить', () async {
      final response = await _assistant(enabled: false).handle(
        'скачай видео по ссылке $_url',
      );
      expect(response.intent, 'extension.off');
      expect(response.message, contains('Загрузчик видео'));
      expect(response.message, isNot(contains('example.com')));
      expect(response.job, isNull);
    });

    test('ссылку переживает файл чата (длиннее 300 знаков)', () {
      final long = 'https://example.com/${'a' * 600}';
      final card = _card(url: long);
      final restored = ExtensionCard.fromJson(card.toJson())!;
      expect(restored.values['url'], long);
    });
  });

  group('форма', () {
    test('«Скачать» — только с yt-dlp, на Windows и Linux, с верной ссылкой',
        () {
      const tools = <String>{YtdlFormats.tool};
      expect(ExtensionForms.runLabel(YtdlConnector.id), 'Скачать');
      expect(
        ExtensionForms.blocker(_card(url: _url), JobPlatform.linux),
        contains('yt-dlp'),
      );
      expect(
        ExtensionForms.blocker(
          _card(url: _url),
          JobPlatform.android,
          tools: tools,
        ),
        contains('недоступно'),
      );
      expect(
        ExtensionForms.blocker(_card(), JobPlatform.windows, tools: tools),
        'Вставьте ссылку',
      );
      expect(
        ExtensionForms.blocker(
          _card(url: 'ftp://x'),
          JobPlatform.windows,
          tools: tools,
        ),
        contains('https://'),
      );
      expect(
        ExtensionForms.blocker(
          _card(url: _url),
          JobPlatform.linux,
          tools: tools,
        ),
        isNull,
      );
    });

    test('«Только звук» без ffmpeg — недоступен с причиной', () {
      final options = ExtensionForms.of(YtdlConnector.id)!
          .firstWhere((FieldSpec f) => f.code == 'format')
          .options!;
      final without = options(_card(), JobPlatform.linux, <String>{});
      final audio =
          without.firstWhere((Choice c) => c.value == YtdlFormats.audio);
      expect(audio.enabled, isFalse);
      expect(audio.disabledReason, contains('ffmpeg'));
      expect(
        without.where((Choice c) => c.value != YtdlFormats.audio),
        everyElement(predicate<Choice>((Choice c) => c.enabled)),
      );
      final withTool = options(
        _card(),
        JobPlatform.linux,
        <String>{YtdlFormats.ffmpeg},
      );
      expect(withTool.every((Choice c) => c.enabled), isTrue);
      expect(
        ExtensionForms.blocker(
          _card(url: _url, format: YtdlFormats.audio),
          JobPlatform.linux,
          tools: const <String>{YtdlFormats.tool},
        ),
        contains('ffmpeg'),
      );
    });
  });

  group('сборка', () {
    test('загрузчик — только Windows и Linux и не в сборке для Play', () {
      expect(kPlayBuild, isFalse);
      expect(ytdlSupported(JobPlatform.windows, play: false), isTrue);
      expect(ytdlSupported(JobPlatform.linux, play: false), isTrue);
      for (final platform in <JobPlatform>[
        JobPlatform.android,
        JobPlatform.ios,
        JobPlatform.macos,
      ]) {
        expect(ytdlSupported(platform, play: false), isFalse);
      }
      for (final platform in JobPlatform.values) {
        expect(ytdlSupported(platform, play: true), isFalse);
      }
    });
  });

  group('нет в сборке (Android, macOS, Google Play)', () {
    test('причина по платформе и сборке', () {
      expect(
        YtdlUnavailableReason.of(JobPlatform.android, play: false),
        YtdlUnavailableReason.android,
      );
      expect(
        YtdlUnavailableReason.of(JobPlatform.macos, play: false),
        YtdlUnavailableReason.platform,
      );
      expect(
        YtdlUnavailableReason.of(JobPlatform.ios, play: false),
        YtdlUnavailableReason.platform,
      );
      for (final platform in JobPlatform.values) {
        expect(
          YtdlUnavailableReason.of(platform, play: true),
          YtdlUnavailableReason.build,
        );
      }
    });

    test('те же фразы, что у настоящего загрузчика', () {
      const unavailable =
          YtdlUnavailableConnector(YtdlUnavailableReason.android);
      for (final text in <String>[
        'скачай видео по ссылке $_url',
        'скачай видео',
        'скачай звук из видео $_url',
        'сохрани $_url',
        'скачай музыку',
        'загрузи видео на ютуб',
        'скачать видео завтра',
        'задача скачай видео',
        'привет',
      ]) {
        final utterance = Utterance.analyze(text, now: _now);
        final real = YtdlConnector().match(utterance);
        final match = unavailable.match(utterance);
        expect(match == null, real == null, reason: text);
        if (match != null) {
          expect(match.confidence, real!.confidence, reason: text);
          expect(match.connectorId, real.connectorId, reason: text);
          // Ссылка не уходит даже в данные совпадения.
          expect(match.payload, isNull, reason: text);
        }
      }
    });

    test('Android: Лиорио честно объясняет, ссылки в ответе нет', () async {
      final printed = <String>[];
      final response = await runZoned(
        () => _assistant(unavailable: YtdlUnavailableReason.android)
            .handle('скачай видео по ссылке $_url'),
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
              printed.add(line),
        ),
      );
      expect(response.intent, YtdlUnavailableConnector.command);
      expect(response.replyId, 'ytdl.unavailable.android');
      expect(response.personaId, 'rio');
      expect(response.job, isNull);
      expect(response.message, isNot(contains('Пока понимаю')));
      expect(response.message, contains('Android'));
      expect(response.message, contains('Windows и Linux'));
      expect(response.message, isNot(contains('example.com')));
      expect(response.message, isNot(contains('секрет')));
      expect(response.message, isNot(contains('http')));
      expect(printed.where((String l) => l.contains('example.com')), isEmpty);
    });

    test('сборка для Google Play: «в этой версии нет»', () async {
      final response = await _assistant(
        unavailable: YtdlUnavailableReason.build,
      ).handle('скачай видео по ссылке $_url');
      expect(response.replyId, 'ytdl.unavailable.build');
      expect(response.personaId, 'rio');
      expect(response.job, isNull);
      expect(response.message, contains('В этой версии'));
      expect(response.message, isNot(contains('Windows')));
      expect(response.message, isNot(contains('example.com')));
    });

    test('macOS: только в версиях для Windows и Linux', () async {
      final response = await _assistant(
        unavailable: YtdlUnavailableReason.platform,
      ).handle('скачай звук из видео $_url');
      expect(response.replyId, 'ytdl.unavailable.platform');
      expect(response.message, contains('Windows и Linux'));
      expect(response.message, isNot(contains('example.com')));
    });

    test('чужие фразы не берёт: «скачай музыку» — не к нему', () async {
      final response = await _assistant(
        unavailable: YtdlUnavailableReason.android,
      ).handle('добавь задачу скачать видео завтра');
      expect(response.intent, isNot(YtdlUnavailableConnector.command));
    });

    test(
        'не рекламируется: ни в «что умеешь», ни в каталоге, ни в '
        'настройках', () async {
      final assistant = _assistant(unavailable: YtdlUnavailableReason.android);
      final skills = await assistant.handle('что ты умеешь');
      expect(skills.message, isNot(contains('Загрузчик')));
      final catalog = CommandCatalog.build(connectors: assistant.connectors);
      expect(
        catalog.entries.where((CommandEntry e) => e.connectorId == 'ytdl'),
        isEmpty,
      );
      expect(assistant.extensions.info(YtdlConnector.id), isNull);
      expect(
        assistant.extensions.unavailable.map((ConnectorInfo i) => i.id),
        <String>[YtdlConnector.id],
      );
    });
  });
}
