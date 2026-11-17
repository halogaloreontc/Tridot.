/// Флаги сборки (ADR-024).
///
/// Сборка для Google Play: `flutter build appbundle
/// --dart-define=TRIDOT_STORE=play`. В ней нет загрузчика видео — правила
/// магазина такие приложения не пропускают. Флейворов Gradle нет: флаг —
/// константа Dart. За ним стоят все места, откуда достижим загрузчик:
/// коннектор и программа yt-dlp (main.dart), исполнитель задач
/// (home_page.dart), форма карточки ([ExtensionForms.of]), команда в «+»,
/// плитка в настройках и закреплённые ссылки yt-dlp (`ToolSpecs.all`). Их
/// код выбрасывается при сборке как недостижимый: в libapp.so сборки для
/// Play нет ни аргументов yt-dlp, ни ссылок на него (проверено по строкам
/// собранного APK). Остаются только подписи вроде названия «Загрузчик
/// видео» в общих таблицах текстов и `YtdlUnavailableConnector`: он узнаёт
/// те же фразы и отвечает «В этой версии загрузчика видео нет» (на Android
/// вне Play — почему: запуск скачанных программ запрещён, yt-dlp нужен
/// Python).
library;

import 'jobs/extension_forms.dart';

/// Сборка для Google Play.
const bool kPlayBuild = String.fromEnvironment('TRIDOT_STORE') == 'play';

/// Есть ли в сборке загрузчик видео (yt-dlp) на платформе [platform].
///
/// Только Windows и Linux: на Android запуск скачанных программ запрещён
/// системой (Android 10+), а yt-dlp нужен Python — без встраивания
/// интерпретатора его не запустить ни в какой Android-сборке; на macOS —
/// песочница и карантин, до решения владельца (ADR-024). [play] — сборка
/// для Google Play: там загрузчика нет ни на какой платформе.
bool ytdlSupported(JobPlatform platform, {bool play = kPlayBuild}) =>
    !play && (platform == JobPlatform.windows || platform == JobPlatform.linux);
