// Что конвертер делает на какой платформе (ADR-026): одна честная таблица
// для карточки, ответов и выбора исполнителя. Системные кодировщики
// телефона и Mac — подделкой NativeMediaCaps.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/skills/converter/convert_targets.dart';

ConvertRoute _route(
  JobPlatform platform,
  MediaKind source,
  String target, [
  Set<String> tools = const <String>{},
]) =>
    ConvertCaps.route(
      platform: platform,
      tools: tools,
      source: source,
      target: target,
    );

String _of(ConvertRoute r) => r.backend?.name ?? 'нет:${r.block!.name}';

void main() {
  const allNative = NativeMediaCaps(
    targets: <String>{
      ConvertTargets.mp3,
      ConvertTargets.m4a,
      ConvertTargets.wav,
      ConvertTargets.mp4,
      ConvertTargets.mov,
      ConvertTargets.frameJpeg,
      ConvertTargets.framePng,
    },
  );

  test('картинка → png/jpeg — на Dart везде', () {
    for (final platform in JobPlatform.values) {
      for (final target in <String>['png', 'jpeg']) {
        expect(
          _of(_route(platform, MediaKind.image, target)),
          'dart',
          reason: '${platform.name} $target',
        );
      }
    }
  });

  test('Windows и Linux: звук и видео — ffmpeg, без него — noTool', () {
    for (final platform in <JobPlatform>[
      JobPlatform.windows,
      JobPlatform.linux,
    ]) {
      for (final target in ConvertTargets.targetsFor('a.mkv')) {
        expect(
          _of(_route(platform, MediaKind.video, target)),
          'нет:noTool',
          reason: target,
        );
        expect(
          _of(_route(platform, MediaKind.video, target, <String>{'ffmpeg'})),
          'ffmpeg',
          reason: target,
        );
      }
    }
  });

  test('телефон: системой то, что она умеет; WebM и MOV — нет вовсе', () {
    final tools = allNative.toTools();
    final matrix = <String, String>{
      for (final target in ConvertTargets.targetsFor('a.mkv'))
        target:
            _of(_route(JobPlatform.android, MediaKind.video, target, tools)),
    };
    expect(matrix, <String, String>{
      'mp3': 'native',
      'm4a': 'native',
      'wav': 'native',
      'mp4': 'native',
      'mov': 'нет:impossible',
      'webm': 'нет:impossible',
      'frame-jpeg': 'native',
      'frame-png': 'native',
    });
    // ffmpeg на телефоне не помогает: запуск скачанных программ запрещён.
    expect(
      _of(
        _route(JobPlatform.android, MediaKind.audio, 'mp3', <String>{
          'ffmpeg',
        }),
      ),
      'нет:imagesOnly',
    );
  });

  test(
      'Mac: MOV есть, WebM нет; без системных кодировщиков — только '
      'картинки', () {
    final tools = allNative.toTools();
    expect(
      _of(_route(JobPlatform.macos, MediaKind.video, 'mov', tools)),
      'native',
    );
    expect(
      _of(_route(JobPlatform.macos, MediaKind.video, 'webm', tools)),
      'нет:impossible',
    );
    expect(
      _of(_route(JobPlatform.macos, MediaKind.audio, 'mp3')),
      'нет:imagesOnly',
    );
    expect(
      _of(_route(JobPlatform.ios, MediaKind.audio, 'mp3', tools)),
      'нет:imagesOnly',
    );
  });

  test('системные кодировщики — через набор программ туда и обратно', () {
    const caps = NativeMediaCaps(
      targets: <String>{'mp3', 'mp4'},
      video1080: false,
    );
    final back = NativeMediaCaps.fromTools(<String>{
      'ffmpeg',
      ...caps.toTools(),
    });
    expect(back.targets, <String>{'mp3', 'mp4'});
    expect(back.video1080, isFalse);
    expect(
      NativeMediaCaps.fromTools(const <String>{'ffmpeg'}).targets,
      isEmpty,
    );
  });

  test('варианты «Во что»: невозможное скрыто, но видно, если его просили', () {
    final phone = ConvertCaps.targetChoices(
      'клип.mp4',
      JobPlatform.android,
      allNative.toTools(),
    );
    expect(phone.map((Choice c) => c.value), isNot(contains('webm')));
    expect(phone.map((Choice c) => c.value), isNot(contains('mov')));
    expect(phone.every((Choice c) => c.enabled), isTrue);
    expect(
      phone.firstWhere((Choice c) => c.value == 'mp4').label,
      'MP4 (пережать)',
    );
    final asked = ConvertCaps.targetChoices(
      'клип.mp4',
      JobPlatform.android,
      allNative.toTools(),
      keep: 'webm',
    );
    final webm = asked.firstWhere((Choice c) => c.value == 'webm');
    expect(webm.disabledReason, contains('На телефоне WebM не делается'));
    final mac = ConvertCaps.targetChoices(
      'клип.mp4',
      JobPlatform.macos,
      const <String>{},
    );
    expect(mac.map((Choice c) => c.value), contains('mov'));
    expect(
      mac.firstWhere((Choice c) => c.value == 'mp3').disabledReason,
      contains('только картинки'),
    );
  });

  test('форматы для ответа — по платформе', () {
    expect(
      ConvertCaps.mediaTargets(JobPlatform.linux, const <String>{}),
      <String>[
        'mp3',
        'm4a',
        'wav',
        'mp4',
        'mov',
        'webm',
        'frame-jpeg',
        'frame-png',
      ],
    );
    expect(
      ConvertCaps.mediaTargets(JobPlatform.android, const <String>{}),
      isEmpty,
    );
    expect(
      ConvertCaps.mediaTargets(JobPlatform.android, allNative.toTools()),
      isNot(contains('webm')),
    );
    expect(
      ConvertCaps.impossibleWhy(JobPlatform.android, 'webm'),
      startsWith('в системе'),
    );
  });

  test(
      'нет части целей у системы — «на этом устройстве не делается», а '
      'не «только картинки»', () {
    const partial = NativeMediaCaps(targets: <String>{'wav', 'm4a'});
    expect(
      _of(
        _route(
          JobPlatform.android,
          MediaKind.video,
          'mp3',
          partial.toTools(),
        ),
      ),
      'нет:deviceLacks',
    );
    expect(
      _of(
        _route(
          JobPlatform.android,
          MediaKind.video,
          'm4a',
          partial.toTools(),
        ),
      ),
      'native',
    );
    expect(
      _of(_route(JobPlatform.android, MediaKind.video, 'mp3')),
      'нет:imagesOnly',
    );
    final choices = ConvertCaps.targetChoices(
      'клип.mp4',
      JobPlatform.android,
      partial.toTools(),
    );
    final mp3 = choices.firstWhere((Choice c) => c.value == 'mp3');
    expect(
        mp3.disabledReason,
        'На телефоне MP3 не делается: встроенный '
        'кодировщик MP3 не загрузился');
    final mp4 = choices.firstWhere((Choice c) => c.value == 'mp4');
    expect(mp4.disabledReason, contains('H.264'));
  });

  test('Mac не открывает WebM, MKV, AVI, OGG, Opus; телефон — AVI кроме MP4',
      () {
    for (final name in <String>[
      'a.webm',
      'a.mkv',
      'a.avi',
      'a.ogg',
      'a.oga',
      'a.opus',
    ]) {
      final choices = ConvertCaps.targetChoices(
        name,
        JobPlatform.macos,
        allNative.toTools(),
      );
      expect(choices, isNotEmpty, reason: name);
      expect(
        choices.every((Choice c) => !c.enabled),
        isTrue,
        reason: name,
      );
      expect(choices.first.disabledReason, contains('не открывается'));
    }
    for (final name in <String>['a.mp4', 'a.mov', 'a.m4a', 'a.mp3', 'a.wav']) {
      expect(
        ConvertCaps.targetChoices(name, JobPlatform.macos, allNative.toTools())
            .where((Choice c) => c.value != 'webm')
            .every((Choice c) => c.enabled),
        isTrue,
        reason: name,
      );
    }
    final avi = ConvertCaps.targetChoices(
      'a.avi',
      JobPlatform.android,
      allNative.toTools(),
    );
    expect(avi.firstWhere((Choice c) => c.value == 'mp4').enabled, isTrue);
    expect(
      avi.firstWhere((Choice c) => c.value == 'mp3').disabledReason,
      contains('только MP4'),
    );
    // На компьютере ffmpeg открывает всё.
    expect(
      ConvertCaps.targetChoices('a.mkv', JobPlatform.linux, <String>{'ffmpeg'})
          .every((Choice c) => c.enabled),
      isTrue,
    );
  });

  test('без системных кодировщиков — короткая причина без «платформы»', () {
    expect(
      ConvertCaps.reason(ConvertBlock.imagesOnly, JobPlatform.android, 'mp3'),
      'На телефоне — только картинки',
    );
    expect(
      ConvertCaps.reason(ConvertBlock.imagesOnly, JobPlatform.macos, 'mp3'),
      'На Mac — только картинки',
    );
    expect(
      ConvertCaps.mediaNames(<String>{'mp4', 'mp3', 'frame-png'}),
      'mp3, mp4, кадр',
    );
  });
}
