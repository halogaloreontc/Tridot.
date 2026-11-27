import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

void main() {
  test('«Расширения» в меню: по умолчанию раскрыты, свёрнутое сохраняется', () {
    expect(const AppSettings().drawerExtensionsOpen, isTrue);
    expect(
      const AppSettings().toJson().containsKey('ui.drawer_extensions_open'),
      isFalse,
    );
    const closed = AppSettings(drawerExtensionsOpen: false);
    expect(closed.toJson()['ui.drawer_extensions_open'], isFalse);
    expect(AppSettings.fromJson(closed.toJson()).drawerExtensionsOpen, isFalse);
    expect(
      AppSettings.fromJson(const <String, dynamic>{}).drawerExtensionsOpen,
      isTrue,
    );
  });
}
