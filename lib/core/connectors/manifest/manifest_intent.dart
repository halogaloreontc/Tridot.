import '../connector.dart';
import 'manifest_format.dart';

/// Рецепты запасного слоя (ADR-041) для подключения по описанию
/// `assistant/1`: из самих фраз `say` команд и действий, без знаний о
/// конкретном приложении. Носитель — начало фразы до первого слота («где
/// лежит {q}» → «где лежит»); после носителя — сначала артикулы и коды
/// ячеек из фразы, потом вся фраза. Без слотов — первая фраза `say`.
/// Действие на запись — из встроенной копии описания и со своей карточкой
/// подтверждения, как всегда.
abstract final class ManifestIntent {
  /// Рецепт команды `<slot>.<id>` или действия `<slot>.act.<kind>`.
  static IntentRecipe? recipe(
    String slotId,
    String commandId,
    ManifestDescription? description,
    ManifestDescription? builtIn,
  ) {
    final prefix = '$slotId.';
    if (!commandId.startsWith(prefix)) return null;
    final name = commandId.substring(prefix.length);
    final List<String> say;
    final List<String> examples;
    final bool slots;
    if (name.startsWith('act.')) {
      final kind = name.substring(4);
      final action = builtIn?.actions
          .where((ManifestAction a) => a.kind == kind)
          .firstOrNull;
      if (action == null) return null;
      say = action.say;
      examples = action.examples;
      slots = action.slots.isNotEmpty;
    } else {
      final command = description?.commands
          .where((ManifestCommand c) => c.id == name)
          .firstOrNull;
      if (command == null) return null;
      say = command.say;
      examples = command.examples;
      slots = command.slots.isNotEmpty;
    }
    if (say.isEmpty) return null;
    final example = examples.firstOrNull ?? say.first;
    if (!slots) return IntentRecipe(ask: say.first, example: example);
    final carriers = <String>{
      for (final phrase in say)
        if (phrase.indexOf('{') case final int at when at > 0)
          phrase.substring(0, at).trim(),
    }.where((String c) => c.isNotEmpty).toList();
    return IntentRecipe(
      carriers: carriers,
      ask: carriers.firstOrNull,
      example: example,
      values: _values,
    );
  }

  /// Артикулы и коды ячеек фразы, потом вся фраза.
  static List<String> _values(Utterance utterance) => <String>[
        ...utterance.codes,
        for (final match in _cell.allMatches(utterance.original))
          match.group(0)!,
        utterance.original,
      ];

  static final RegExp _cell = RegExp(r'\d{3}(?:\s*-\s*[0-9a-zа-яё]+)+');
}
