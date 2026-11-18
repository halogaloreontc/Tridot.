import '../commands/command_suggest.dart';
import '../connectors/utterance.dart';
import '../passwords/secret_guard.dart';
import '../personas/persona_address.dart';
import '../skills/passwords/passwords_phrases.dart';
import 'command_frame.dart';
import 'layout_fix.dart';
import 'route_policy.dart';
import 'typo_fix.dart';

/// Разбор фразы одним коннектором-набором: что нашли и кого выбрали.
typedef LayerRoute<T> = ({T found, RouteDecision decision});

/// Итог слоёв распознавания (ADR-037) над одной фразой.
final class Layered<T> {
  const Layered({
    required this.text,
    required this.utterance,
    required this.hide,
    required this.found,
    required this.decision,
    this.repair,
  });

  /// Текст, который понят: исходный, без обёртки, с исправленным сроком
  /// или исправленный спасательным проходом.
  final String text;
  final Utterance utterance;

  /// Фразу не получают сетевые коннекторы (фраза о паролях, раздел 5.9).
  final bool hide;
  final T found;
  final RouteDecision decision;

  /// Спасательный проход: `router.repaired` (не та раскладка) или
  /// `router.typo` (опечатка) — ответ с пояснением «понял как «…»», а
  /// запись только после «Да». `null` — фраза понята первым проходом.
  final String? repair;
}

/// Слои распознавания перед общим выбором [RoutePolicy] — одни и те же в
/// маршрутизаторе (AssistantController), корпусном тесте и
/// `tool/route_phrases.dart` (ADR-037):
///
/// 1. фраза как есть;
/// 2. разговорная обёртка ([CommandFrame]) — по [CommandFrame.prefer]; без
///    обёртки фраза о ПИН, коде, логине не становится новым делом;
/// 3. опечатка в слове срока при понятой команде ([TypoFix.repairDue]);
/// 4. если как есть не понял никто явно — спасательные проходы: не та
///    раскладка ([LayoutFix]), опечатка ([TypoFix.repair]); исправленный
///    текст проходит те же шаги 2–3, поэтому проверяется ровно та команда,
///    которая выполнится. Фразы о паролях, ПИН, кодах не исправляются:
///    исправленный текст повторяется в чате.
abstract final class RecognitionLayers {
  /// Фразу о паролях не получает ни один сетевой коннектор (раздел 5.9) —
  /// и с опечаткой: «где лежит парль от почты» — тоже о паролях.
  static bool hidesFromNetwork(
    Utterance utterance,
    Utterance Function(String text) analyze,
  ) {
    if (PasswordPhrases.looksLike(utterance)) return true;
    final repaired = TypoFix.repair(utterance.original);
    return repaired != null && PasswordPhrases.looksLike(analyze(repaired));
  }

  static Layered<T> route<T>({
    required String message,
    required Utterance utterance,
    required bool hide,
    required LayerRoute<T> Function(Utterance utterance, bool hide) router,
    required Utterance Function(String text) analyze,
    LayerRoute<T>? first,
    bool fromVoice = false,
    bool rescue = true,
    FingerprintMatcher? knownSecret,
  }) {
    final asIs = decide<T>(
      text: message,
      utterance: utterance,
      hide: hide,
      router: router,
      analyze: analyze,
      first: first,
      fromVoice: fromVoice,
    );
    if (!rescue ||
        asIs.hide ||
        _private(message) ||
        SecretGuard.redact(message, known: knownSecret).guarded) {
      return asIs;
    }
    final original = asIs.decision;
    final rescues = <(String, String, bool Function(RouteDecision))>[
      for (final repaired in LayoutFix.candidates(message))
        (
          repaired,
          'router.repaired',
          (RouteDecision d) => LayoutFix.prefer(original, d),
        ),
      if (TypoFix.repair(message) case final String typo)
        (typo, 'router.typo', (RouteDecision d) => TypoFix.prefer(original, d)),
    ];
    for (final (raw, reply, prefer) in rescues) {
      // «Yjlf? yfgjvyb …» — «Нода, напомни …»: обращение не в задачу.
      final text = PersonaAddressing.commandText(raw);
      final fixed = analyze(text);
      if (PasswordPhrases.looksLike(fixed) ||
          _private(text) ||
          SecretGuard.redact(text, known: knownSecret).guarded) {
        break;
      }
      final repaired = decide<T>(
        text: text,
        utterance: fixed,
        hide: false,
        router: router,
        analyze: analyze,
        fromVoice: fromVoice,
      );
      if (PasswordPhrases.looksLike(repaired.utterance)) break;
      if (!prefer(repaired.decision)) continue;
      return Layered<T>(
        text: repaired.text,
        utterance: repaired.utterance,
        hide: repaired.hide,
        found: repaired.found,
        decision: repaired.decision,
        repair: reply,
      );
    }
    return asIs;
  }

  /// ПИН, код, логин, пароль во фразе ([CommandSuggester.isPrivate]).
  /// Ссылка — не секрет: «скачай видео https://…/v/1» исправлять можно.
  static bool _private(String text) =>
      CommandSuggester.isPrivate(text.replaceAll(_url, ' '));

  static final RegExp _url = RegExp(r'https?://\S+|www\.\S+');

  /// Шаги 1–3 над [text]: как есть, без обёртки, с исправленным сроком.
  static Layered<T> decide<T>({
    required String text,
    required Utterance utterance,
    required bool hide,
    required LayerRoute<T> Function(Utterance utterance, bool hide) router,
    required Utterance Function(String text) analyze,
    LayerRoute<T>? first,
    bool fromVoice = false,
  }) {
    var current = text;
    var currentUtterance = utterance;
    var currentHide = hide;
    var currentRoute = first ?? router(utterance, hide);
    final framedText = CommandFrame.strip(text, fromVoice: fromVoice);
    if (framedText != null) {
      final framed = analyze(framedText);
      final framedHide = currentHide || PasswordPhrases.looksLike(framed);
      final framedRoute = router(framed, framedHide);
      final winner = framedRoute.decision.winner;
      final was = currentRoute.decision.winner;
      // Без обёртки фраза о ПИН, коде, логине стала бы новым делом с
      // секретом в названии («не дай мне забыть пин от карты …»): так —
      // только если и как есть это было то же дело. Явная фраза о паролях
      // («напомни пароль от почты») — не утечка: её возьмут «Пароли», а
      // выключенный навык ответит «Пароли выключены».
      final newAction = winner != null &&
          (was == null ||
              was.connectorId != winner.connectorId ||
              was.commandId != winner.commandId);
      final passwords = PasswordPhrases.parse(framed);
      final firmPasswords =
          passwords != null && passwords.confidence >= PasswordPhrases.firm;
      final leaks = newAction &&
          !firmPasswords &&
          winner.connectorId != RoutePolicy.passwordsId &&
          CommandSuggester.isPrivate(framedText);
      if (!leaks &&
          CommandFrame.prefer(currentRoute.decision, framedRoute.decision)) {
        current = framedText;
        currentUtterance = framed;
        currentHide = framedHide;
        currentRoute = framedRoute;
      }
    }
    if (currentRoute.decision.winner != null) {
      final dueText = TypoFix.repairDue(current);
      if (dueText != null) {
        final fixed = analyze(dueText);
        final fixedRoute = router(fixed, currentHide);
        if (TypoFix.sameCommand(currentRoute.decision, fixedRoute.decision)) {
          current = dueText;
          currentUtterance = fixed;
          currentRoute = fixedRoute;
        }
      }
    }
    return Layered<T>(
      text: current,
      utterance: currentUtterance,
      hide: currentHide,
      found: currentRoute.found,
      decision: currentRoute.decision,
    );
  }
}
