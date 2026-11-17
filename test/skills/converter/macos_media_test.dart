// Конвертер на Mac (ADR-026, шаг S3): Swift в macos/Runner собрать и
// запустить в этом контейнере нельзя (нет Xcode), поэтому договор с Dart и
// Android сверяется по тексту: имена каналов, коды ошибок, цели, функции
// обёртки LAME, файлы в проекте Xcode, лицензии.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_placement.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/skills/converter/convert_targets.dart';
import 'package:local_assistant/core/skills/converter/platform_media_job.dart';

const String _channel = 'macos/Runner/MediaChannel.swift';
const String _pipelines = 'macos/Runner/MediaPipelines.swift';
const String _window = 'macos/Runner/MainFlutterWindow.swift';
const String _pbxproj = 'macos/Runner.xcodeproj/project.pbxproj';
const String _kotlinDir =
    'android/app/src/main/kotlin/com/example/local_assistant/media';

String _read(String path) => File(path).readAsStringSync();

/// Тело `enum <name> { … }` в Swift.
String _swiftEnum(String text, String name) {
  final start = text.indexOf('enum $name');
  expect(start, isNot(-1), reason: name);
  final open = text.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '{') depth++;
    if (text[i] == '}' && --depth == 0) return text.substring(open + 1, i);
  }
  fail('enum $name не закрыт');
}

void main() {
  final channel = _read(_channel);
  final pipelines = _read(_pipelines);
  final swift = '$channel\n$pipelines';

  test('каналы — те же имена, что у Dart и Android', () {
    final bridge = _read('lib/app/jobs/media_channel_bridge.dart');
    final kotlin = _read('$_kotlinDir/MediaChannel.kt');
    for (final name in <String>['tridot/media', 'tridot/media/events']) {
      expect(bridge, contains("'$name'"), reason: name);
      expect(kotlin, contains('"$name"'), reason: name);
      expect(channel, contains('name: "$name"'), reason: name);
    }
    for (final method in <String>['capabilities', 'start', 'cancel']) {
      expect(channel, contains('case "$method"'), reason: method);
    }
  });

  test('каналы регистрируются в окне приложения', () {
    final window = _read(_window);
    expect(
      window,
      contains(
        'MediaChannel.register(with: flutterViewController.engine'
        '.binaryMessenger)',
      ),
    );
    expect(
      window.indexOf('RegisterGeneratedPlugins'),
      lessThan(window.indexOf('MediaChannel.register')),
    );
  });

  test('коды ошибок — те же, что JobCodes и коды Kotlin', () {
    final cases = RegExp(r'case (\w+)')
        .allMatches(_swiftEnum(channel, 'MediaCode'))
        .map((Match m) => m.group(1)!)
        .toSet();
    final job = _read('$_kotlinDir/MediaJob.kt');
    final block = job.substring(
      job.indexOf('object MediaCodes {'),
      job.indexOf('}', job.indexOf('object MediaCodes {')),
    );
    final kotlin = RegExp(r'const val \w+ = "(\w+)"')
        .allMatches(block)
        .map((Match m) => m.group(1)!)
        .toSet();
    expect(cases, kotlin);
    const known = <String>{
      JobCodes.missing,
      JobCodes.noStream,
      JobCodes.media,
      JobCodes.mediaOpen,
      JobCodes.encoder,
      JobCodes.disk,
      JobCodes.tooBig,
      JobCodes.tooBigWav,
      JobCodes.noMemory,
      JobCodes.unsupported,
      JobCodes.cancelled,
      JobCodes.failed,
    };
    expect(cases, known);
  });

  test('цели Mac: MOV есть, WebM нет; Dart принимает их все', () {
    final targets = RegExp(r'static let \w+ = "([\w-]+)"')
        .allMatches(_swiftEnum(channel, 'MediaTarget'))
        .map((Match m) => m.group(1)!)
        .toSet();
    expect(
      targets,
      <String>{
        ConvertTargets.mp3,
        ConvertTargets.m4a,
        ConvertTargets.wav,
        ConvertTargets.mp4,
        ConvertTargets.mov,
        ConvertTargets.frameJpeg,
        ConvertTargets.framePng,
      },
    );
    expect(targets, isNot(contains(ConvertTargets.webm)));
    final caps = nativeMediaCapsOf(
      <Object?, Object?>{'targets': targets.toList(), 'video1080': true},
      JobPlatform.macos,
    );
    expect(caps.targets, targets);
    // Каждая цель исполняется системой Mac, не ffmpeg.
    for (final target in targets) {
      expect(
        ConvertCaps.route(
          platform: JobPlatform.macos,
          tools: caps.toTools(),
          source: MediaKind.video,
          target: target,
        ).backend,
        ConvertBackend.native,
        reason: target,
      );
    }
    // Каждая цель разобрана в задаче.
    for (final name in <String>[
      'mp3',
      'm4a',
      'wav',
      'mp4',
      'mov',
      'frameJpeg',
      'framePng',
    ]) {
      expect(pipelines, contains('case MediaTarget.$name:'), reason: name);
    }
  });

  test('аргументы start — те же ключи, что отправляет Dart', () {
    final arguments = PlatformMediaJobRunner.argumentsOf(
      JobRequest(
        cardId: 'c1',
        extensionId: 'converter',
        action: ConvertTargets.mp3,
        sources: const <JobSource>[JobSource('/in/a.mp4', 'a.mp4')],
        outputDir: '/out',
        target: '/out/a.mp3',
        temp: JobPlacement.tempFile('/out/a.mp3', 'c1'),
      ),
      'c1-1',
    );
    for (final key in arguments.keys) {
      expect(channel, contains('args["$key"]'), reason: key);
    }
    // Временный файл Dart всегда `….part` — Swift другой не примет.
    expect(arguments['output'], endsWith('.part'));
    expect(channel, contains('path.hasSuffix(".part")'));
  });

  test('LAME: функции обёртки, версия и имя фреймворка', () {
    final header = _read('packages/tridot_lame/src/tridot_lame.h');
    final symbols = RegExp(r'symbol\("(tl_\w+)"')
        .allMatches(channel)
        .map((Match m) => m.group(1)!)
        .toList();
    expect(symbols, hasLength(7));
    for (final name in symbols) {
      expect(header, matches(RegExp('TL_API [^;]*\\b$name\\(')), reason: name);
    }
    expect(channel, contains('static let expectedVersion = "3.100"'));
    expect(channel, contains('static let maxFrames = 1 << 20'));
    expect(header, contains('#define TL_MAX_FRAMES (1 << 20)'));
    final hook = _read('packages/tridot_lame/hook/build.dart');
    expect(hook, contains("name: 'tridot_mp3'"));
    expect(hook, contains('OS.macOS'));
    // Сборщик Flutter кладёт libtridot_mp3.dylib в tridot_mp3.framework.
    expect(channel, contains('tridot_mp3.framework/tridot_mp3'));
  });

  test('в журнал — только цель и код, без путей', () {
    expect(swift, isNot(contains('print(')));
    final logs = RegExp(r'NSLog\(([^\n]*)\)').allMatches(swift).toList();
    expect(logs, hasLength(1));
    expect(
      logs.single.group(1),
      '"TridotMedia %@: %@", request.target, code.rawValue',
    );
  });

  test('файлы Swift — в проекте Xcode и в сборке Runner', () {
    final project = _read(_pbxproj);
    for (final file in <String>['MediaChannel.swift', 'MediaPipelines.swift']) {
      final ref = RegExp(
        '([0-9A-F]{24}) /\\* $file \\*/ = \\{isa = PBXFileReference; '
        'lastKnownFileType = sourcecode.swift; path = $file;',
      ).firstMatch(project);
      expect(ref, isNotNull, reason: file);
      final build = RegExp(
        '([0-9A-F]{24}) /\\* $file in Sources \\*/ = \\{isa = PBXBuildFile; '
        'fileRef = ${ref!.group(1)} /\\* $file \\*/; \\};',
      ).firstMatch(project);
      expect(build, isNotNull, reason: file);
      final sources = project.substring(
        project.indexOf('/* Begin PBXSourcesBuildPhase section */'),
        project.indexOf('/* End PBXSourcesBuildPhase section */'),
      );
      expect(
        sources,
        contains('${build!.group(1)} /* $file in Sources */,'),
        reason: file,
      );
      final group = project.substring(
        project.indexOf('/* Runner */ = {\n\t\t\tisa = PBXGroup;'),
      );
      expect(
        group.substring(0, group.indexOf('};')),
        contains('${ref.group(1)} /* $file */,'),
        reason: file,
      );
    }
    // Ни один id объекта не определён дважды.
    final ids = RegExp(r'^\t\t([0-9A-F]{24}) /\*[^*]*\*/ = \{', multiLine: true)
        .allMatches(project)
        .map((Match m) => m.group(1)!)
        .toList();
    expect(ids.toSet().length, ids.length);
  });

  test('лицензия LAME: NOTICE, экран лицензий, текст LGPL', () {
    final notice = _read('assets/extensions/NOTICE.txt');
    for (final text in <String>[
      'LAME 3.100',
      'LGPL-2.0-or-later',
      'ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e',
      'packages/tridot_lame',
      'libtridot_mp3.so',
      'tridot_mp3.framework',
      'https://lame.sourceforge.io',
      'tridot_lame',
      // LGPL §4/§6: где взять исходники обёртки и куда писать запрос.
      'https://github.com/halogaloreontc/qenqritec/tree/main/packages/tridot_lame',
      'https://github.com/halogaloreontc/qenqritec/issues',
      'tridot_lame_jni.c',
      'Guava',
    ]) {
      expect(notice, contains(text), reason: text);
    }
    final main = _read('lib/main.dart');
    expect(main, contains("'assets/extensions/NOTICE.txt'"));
    expect(main, contains("'LAME'"));
    // Лицензии библиотек Android Flutter сам не показывает: Media3 — в
    // NOTICE.
    expect(main, contains("'Media3'"));
    expect(notice, contains('Media3 1.11.1'));
    expect(
      _read('android/app/build.gradle.kts'),
      contains('androidx.media3:media3-transformer:1.11.1'),
    );
    expect(
      _read('packages/tridot_lame/LICENSE'),
      contains('GNU LIBRARY GENERAL PUBLIC LICENSE'),
    );
    expect(_read('pubspec.yaml'), contains('assets/extensions/NOTICE.txt'));
  });
}
