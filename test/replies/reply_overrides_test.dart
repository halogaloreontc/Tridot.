import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/web_widget/widget_texts.dart';

void main() {
  final base = ReplyLibrary.builtIn.withEntries(
    ConnectionSlots.warehouse.replies,
    protectedIds: ConnectionSlots.warehouse.protectedReplies,
  );

  test('тексты веб-помощника — во всех стилях, без путей приложения', () {
    final library = base.withOverrides(WidgetTexts.replies);
    for (final style in library.styles) {
      for (final id in WidgetTexts.replies.keys) {
        final text = library.render(
          Reply(
            id,
            const <String, String>{
              'app': 'Склад',
              'role': 'Кладовщик',
              'button': '«Подключить»',
              'login': 'ivanov',
              'now': 'petrov',
            },
          ),
          ReplyVoice(style: style.style),
        );
        expect(
          text,
          isNot(contains('Мой Связной')),
          reason: '$id/${style.style}',
        );
        expect(text, isNot(contains('{')), reason: '$id/${style.style}');
      }
    }
    // Остальное — как было.
    expect(
      library.variants('warehouse.offline', 'neutral'),
      base.variants('warehouse.offline', 'neutral'),
    );
  });

  test('неизвестная запись или не те подстановки — ошибка', () {
    expect(
      () => base.withOverrides(const <String, String>{'no.such.entry': 'x'}),
      throwsFormatException,
    );
    expect(
      () => base.withOverrides(
        const <String, String>{'warehouse.act.otherLogin': 'Без подстановок.'},
      ),
      throwsFormatException,
    );
  });
}
