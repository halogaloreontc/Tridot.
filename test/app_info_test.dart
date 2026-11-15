import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/passwords/vault_backup.dart';

/// Нативные обёртки не видят Dart-констант: название в них записано
/// строкой. Тест держит их вместе с [AppInfo] (ADR-009).
String _read(String path) => File(path).readAsStringSync();

void main() {
  test('название Tridot и служебное латинское Relay (ADR-016)', () {
    expect(AppInfo.name, 'Tridot');
    expect(AppInfo.hubName, 'Мой Связной');
    expect(AppInfo.latinName, 'Relay');
    expect(AppInfo.latinName, matches(RegExp(r'^[A-Za-z]+$')));
  });

  test('версия — как version: в pubspec.yaml', () {
    final match = RegExp(r'^version:\s*(\S+)\+(\d+)\s*$', multiLine: true)
        .firstMatch(_read('pubspec.yaml'));
    expect(match, isNotNull);
    expect(AppInfo.version, match!.group(1));
    expect(AppInfo.build, int.parse(match.group(2)!));
    // Копия паролей пишет ту же версию.
    expect(VaultBackup.appVersion, AppInfo.version);
  });

  test('«Tridot» в косвенных падежах не склоняется (ADR-016)', () {
    expect(AppInfo.nameGenitive, 'Tridot');
    expect(AppInfo.nameDative, 'Tridot');
    expect(AppInfo.nameInstrumental, 'Tridot');
    expect(AppInfo.namePrepositional, 'Tridot');
  });

  test('автор встроенных расширений и пака шуток — название приложения', () {
    expect(ConnectorInfo.defaultAuthor, AppInfo.name);
    final pack = jsonDecode(_read('assets/packs/jokes_basic.json')) as Map;
    expect(pack['author'], AppInfo.name);
  });

  test('название — в заголовках окон и подписи', () {
    final linux = _read('linux/runner/my_application.cc');
    expect(
      linux,
      contains('gtk_header_bar_set_title(header_bar, "${AppInfo.name}")'),
    );
    expect(
      linux,
      contains('gtk_window_set_title(window, "${AppInfo.name}")'),
    );

    final windows = _read('windows/runner/main.cpp');
    expect(windows, contains('L"${AppInfo.name}"'));
    // Без /utf-8 MSVC читает исходник в кодовой странице системы.
    expect(windows.runes.every((r) => r < 128), isTrue);

    expect(
      _read('android/app/src/main/AndroidManifest.xml'),
      contains('android:label="${AppInfo.name}"'),
    );

    final xib = _read('macos/Runner/Base.lproj/MainMenu.xib');
    expect(xib, contains('<window title="${AppInfo.name}"'));
    expect(xib, contains('title="О программе ${AppInfo.name}"'));
    expect(xib, contains('title="Скрыть ${AppInfo.name}"'));
    expect(xib, contains('title="Завершить ${AppInfo.name}"'));
    // Меню целиком по-русски: английских пунктов шаблона Flutter не осталось
    // (внутреннее имя «Main Menu» пользователь не видит). Латиницей —
    // только само название приложения.
    final titles = RegExp(r'title="([^"]*)"')
        .allMatches(xib)
        .map((m) => m.group(1)!)
        .where((t) => t != 'Main Menu');
    for (final title in titles) {
      expect(
        title.replaceAll(AppInfo.name, ''),
        isNot(matches(RegExp('[A-Za-z]'))),
        reason: title,
      );
    }

    // Строка меню приложения и панель «О программе» берут CFBundleName:
    // он — название приложения, а не PRODUCT_NAME (Relay).
    expect(
      _read('macos/Runner/Configs/AppInfo.xcconfig'),
      contains('APP_DISPLAY_NAME = ${AppInfo.name}\n'),
    );
    final plist = _read('macos/Runner/Info.plist');
    for (final key in <String>['CFBundleName', 'CFBundleDisplayName']) {
      expect(
        plist,
        contains('<key>$key</key>\n\t<string>\$(APP_DISPLAY_NAME)</string>'),
        reason: key,
      );
    }
  });

  test('приложение не называет себя помощником', () {
    expect(_read('pubspec.yaml'), isNot(contains('персональный помощник')));
    expect(
      _read('lib/app/widgets/extensions_section.dart'),
      isNot(contains('Соберите помощника')),
    );
  });

  test('латинское название — в имени пакета macOS и свойствах файла Windows',
      () {
    expect(
      _read('macos/Runner/Configs/AppInfo.xcconfig'),
      contains('PRODUCT_NAME = ${AppInfo.latinName}\n'),
    );
    final project = _read('macos/Runner.xcodeproj/project.pbxproj');
    expect(project, contains('path = "${AppInfo.latinName}.app"'));
    expect(
      project,
      contains('${AppInfo.latinName}.app/\$(BUNDLE_EXECUTABLE_FOLDER_PATH)/'
          '${AppInfo.latinName}"'),
    );
    expect(
      _read('macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme'),
      contains('BuildableName = "${AppInfo.latinName}.app"'),
    );
    final rc = _read('windows/runner/Runner.rc');
    // ProductName и CompanyName задают папку данных в RoamingAppData:
    // не меняются при смене названия (ADR-016). Описание файла — новое имя.
    expect(rc, contains('VALUE "ProductName", "${AppInfo.latinName}"'));
    expect(rc, contains('VALUE "CompanyName", "com.example"'));
    expect(rc, contains('VALUE "FileDescription", "${AppInfo.name}"'));
  });

  test('id пакета, приложения и исполняемых файлов не меняются (ADR-008)', () {
    expect(
      _read('macos/Runner/Configs/AppInfo.xcconfig'),
      contains('PRODUCT_BUNDLE_IDENTIFIER = com.example.localAssistant'),
    );
    expect(
      _read('windows/runner/Runner.rc'),
      contains('VALUE "OriginalFilename", "local_assistant.exe"'),
    );
    expect(_read('pubspec.yaml'), startsWith('name: local_assistant'));
    // Обновление поверх установленной версии (ADR-016): id приложения на
    // Android и Linux прежние, папки данных те же.
    final gradle = _read('android/app/build.gradle.kts');
    expect(gradle, contains('applicationId = "com.example.local_assistant"'));
    expect(gradle, contains('namespace = "com.example.local_assistant"'));
    final cmake = _read('linux/CMakeLists.txt');
    expect(
      cmake,
      contains('set(APPLICATION_ID "com.example.local_assistant")'),
    );
    expect(cmake, contains('set(BINARY_NAME "local_assistant")'));
  });

  test('прежнего названия «Связной» нет в подписях и заголовках (ADR-016)', () {
    for (final path in <String>[
      'lib/app/shell/session_header.dart',
      'linux/runner/my_application.cc',
      'windows/runner/main.cpp',
      'windows/runner/Runner.rc',
      'android/app/src/main/AndroidManifest.xml',
      'macos/Runner/Base.lproj/MainMenu.xib',
      'macos/Runner/Configs/AppInfo.xcconfig',
      'assets/packs/jokes_basic.json',
    ]) {
      expect(_read(path), isNot(contains('Связн')), reason: path);
    }
  });

  test('старого названия нигде нет', () {
    for (final path in <String>[
      'lib/core/app_info.dart',
      'linux/runner/my_application.cc',
      'windows/runner/main.cpp',
      'windows/runner/Runner.rc',
      'android/app/src/main/AndroidManifest.xml',
      'macos/Runner/Base.lproj/MainMenu.xib',
      'macos/Runner/Configs/AppInfo.xcconfig',
      'macos/Runner.xcodeproj/project.pbxproj',
      'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
      'assets/packs/jokes_basic.json',
    ]) {
      expect(_read(path), isNot(contains('Qenqrit')), reason: path);
    }
  });
}
