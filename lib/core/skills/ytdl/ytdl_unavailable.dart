/// Загрузчик видео там, где его нет (ADR-024): Android, iOS, macOS и сборка
/// для Google Play. Фразы те же, что у [YtdlConnector] (та же
/// [YtdlPhrases.formatOf] и та же уверенность), — маршрутизация не
/// меняется, но вместо карточки Лиорио коротко и честно отвечает, почему
/// загрузчика здесь нет. Ссылку из фразы коннектор не берёт вовсе: её нет
/// ни в данных совпадения, ни в ответе.
library;

import '../../build_flags.dart';
import '../../connectors/connector.dart';
import '../../jobs/extension_forms.dart';
import 'ytdl_connector.dart';

/// Почему загрузчика нет.
enum YtdlUnavailableReason {
  /// Android: запуск скачанных программ запрещён, а yt-dlp нужен Python.
  android,

  /// iOS и macOS: только в версиях для Windows и Linux.
  platform,

  /// Сборка для Google Play (или Windows и Linux без закреплённой
  /// сборки yt-dlp для этого процессора): в этой версии загрузчика нет.
  build;

  /// Почему загрузчика нет на платформе [platform] в сборке [play] (для
  /// Google Play или нет).
  static YtdlUnavailableReason of(JobPlatform platform, {required bool play}) {
    if (play || ytdlSupported(platform, play: false)) return build;
    return platform == JobPlatform.android
        ? android
        : YtdlUnavailableReason.platform;
  }
}

final class YtdlUnavailableConnector
    implements Connector, FormConnector, IntentTarget {
  const YtdlUnavailableConnector(this.reason);

  /// Тот же id, что у настоящего загрузчика: отвечает его ведущий (Лиорио).
  static const String id = YtdlConnector.id;

  static const String command = 'ytdl.unavailable';

  final YtdlUnavailableReason reason;

  /// Строка в «Настройки → Расширения» вместо плитки.
  static const String settingsNote = 'только в версиях для Windows и Linux';

  @override
  ConnectorInfo get info => ConnectorInfo(
        id: id,
        title: 'Загрузчик видео',
        // В сборке для Google Play строки в настройках нет.
        description: reason == YtdlUnavailableReason.build ? '' : settingsNote,
        kind: ExtensionKind.skill,
        // Как у настоящего: фразы о паролях не видит (раздел 5.9), чтобы
        // маршрутизация была одной и той же.
        requiresNetwork: true,
        unavailable: true,
      );

  String get _replyId => switch (reason) {
        YtdlUnavailableReason.android => 'ytdl.unavailable.android',
        YtdlUnavailableReason.platform => 'ytdl.unavailable.platform',
        YtdlUnavailableReason.build => 'ytdl.unavailable.build',
      };

  /// Как выполнить команду по подсказке запасного слоя (ADR-045).
  static const Map<String, IntentRecipe> intentRecipes = <String, IntentRecipe>{
    'ytdl.download': IntentRecipe(
      carriers: <String>['скачай видео'],
      ask: 'скачай видео',
      accepts: <String>{'ytdl.unavailable'},
      example: 'скачай видео по ссылке',
    ),
  };

  @override
  ConnectorMatch? matchAs(
    String commandId,
    Utterance utterance,
    UtteranceAnalyzer analyze,
  ) =>
      matchByRecipe(this, intentRecipes, commandId, utterance, analyze);

  @override
  String? intentExample(String commandId) =>
      intentRecipes[commandId]?.example ?? intentRecipes[commandId]?.ask;

  @override
  ConnectorMatch? match(Utterance utterance) {
    if (YtdlPhrases.formatOf(utterance) == null) return null;
    return const ConnectorMatch(
      connectorId: id,
      commandId: command,
      confidence: YtdlConnector.confidence,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async =>
      _reply(session);

  @override
  AssistantResponse openForm(String? action, AssistantSession session) =>
      _reply(session);

  AssistantResponse _reply(AssistantSession session) => session.reply(
        _replyId,
        intent: command,
        status: AssistantStatus.noAction,
      );
}
