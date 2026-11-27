import 'dart:convert';
import 'dart:io';

import '../commands/command_catalog.dart';
import '../extensions/extension_info.dart';
import '../extensions/role.dart';
import '../jobs/extension_forms.dart';
import '../personas/persona.dart';

export '../personas/persona.dart';

/// Чем распознавать речь (ADR-023): «Распознавание телефона» или
/// «Распознавание Tridot» (Vosk). [auto] — по умолчанию: телефон, если он
/// умеет русский без интернета, иначе Vosk.
enum VoiceEngineChoice {
  auto,
  device,
  vosk;

  /// Значение `voice.engine` в settings.json; [auto] не пишется.
  static VoiceEngineChoice parse(Object? value) => switch (value) {
        'device' => VoiceEngineChoice.device,
        'vosk' => VoiceEngineChoice.vosk,
        _ => VoiceEngineChoice.auto,
      };
}

/// Уровень модели понимания (ADR-045): «Выключено» (по умолчанию) или
/// «Лёгкая» (USER-base; id `accurate` остался от прежнего названия «Точная»).
/// Модель скачивается по выбору пользователя.
enum IntentTier {
  off('off', 'Выключено'),
  accurate('accurate', 'Лёгкая');

  const IntentTier(this.id, this.title);

  /// Значение `intent.tier` в settings.json и уровень в `latest.json`.
  final String id;

  /// Подпись в настройках.
  final String title;

  /// Неизвестное или битое значение — [off].
  static IntentTier parse(Object? value) {
    for (final tier in values) {
      if (tier.id == value) return tier;
    }
    return off;
  }
}

/// Оформление (ADR-027): как в системе, светлое или тёмное.
enum AppAppearance {
  system('system', 'Как в системе'),
  light('light', 'Светлое'),
  dark('dark', 'Тёмное');

  const AppAppearance(this.id, this.title);

  /// Значение в settings.json.
  final String id;

  /// Подпись в настройках.
  final String title;

  /// Неизвестное или битое значение — [system].
  static AppAppearance parse(Object? value) {
    for (final appearance in values) {
      if (appearance.id == value) return appearance;
    }
    return system;
  }
}

/// Пользовательские настройки интерфейса.
final class AppSettings {
  const AppSettings({
    this.appearance = AppAppearance.system,
    this.reduceMotion = false,
    this.showTimestamps = false,
    this.disabledExtensions = const <String>{},
    this.enabledExtensions = const <String>{},
    this.disabledRoles = const <String>{},
    this.enabledRoles = const <String>{},
    this.roleOwners = const <String, String>{},
    this.roleActions = const <String, String>{},
    this.personas = const PersonaSettings(),
    this.noticeDay,
    this.passwordsSeenRev,
    this.passwordsVaultExisted = false,
    this.passwordsTrainingDue,
    this.firstSeenDay,
    this.commandUsage = const <String, int>{},
    this.voiceInput = false,
    this.voiceSendImmediately = false,
    this.voiceMicExplained = false,
    this.voiceEngine = VoiceEngineChoice.auto,
    this.notifyExplained = false,
    this.notifyDismissedDay,
    this.notifyDateOnly = true,
    this.notifyDateOnlyHour = defaultDateOnlyHour,
    this.appLock = false,
    this.appLockAfter = 60,
    this.formDefaults = const <String, String>{},
    this.homeScreenShowText = true,
    this.intentTier = IntentTier.off,
    this.intentLearning = true,
    this.intentLogging = true,
    this.intentOffered = false,
    this.genEnabled = false,
    this.drawerExtensionsOpen = true,
  });

  /// Неизвестные или неверного типа значения заменяются значениями по
  /// умолчанию: битые настройки не должны мешать запуску.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final reduceMotion = json['reduce_motion'];
    // Время у каждого сообщения (ADR-027, S2): по умолчанию выключено.
    // Прежние версии писали `show_timestamps` всегда, и `true` в них —
    // это прежнее значение по умолчанию, а не выбор: явный выбор пишется
    // в `message_times`. Явное «выключено» старых файлов сохраняется.
    final messageTimes = json['message_times'];
    final enabledExtensions = _ids(json['enabled_extensions']);
    // Настройки до ролей: подключение, которое включали сами, включает
    // свою роль (Roles.migratedFrom) — склад продолжает отвечать.
    final legacy = !json.containsKey('enabled_roles') &&
        !json.containsKey('disabled_roles');
    return AppSettings(
      appearance: AppAppearance.parse(json['appearance']),
      reduceMotion: reduceMotion is bool && reduceMotion,
      showTimestamps: messageTimes is bool && messageTimes,
      disabledExtensions: _ids(json['disabled_extensions']),
      enabledExtensions: enabledExtensions,
      disabledRoles: _ids(json['disabled_roles']),
      enabledRoles: legacy
          ? Roles.migratedFrom(enabledExtensions)
          : _ids(json['enabled_roles']),
      roleOwners: _owners(json['role_owners']),
      roleActions: _actions(json['role_actions']),
      personas: PersonaSettings.fromJson(json),
      noticeDay: _day(json['notice_day']),
      passwordsSeenRev: _rev(json['passwords.seen_rev']),
      passwordsVaultExisted: json['passwords.vault_existed'] == true,
      passwordsTrainingDue: _day(json['passwords.training_due']),
      firstSeenDay: _day(json['first_seen_day']),
      commandUsage: CommandUsage.fromJson(json['command_usage']),
      voiceInput: json['voice.enabled'] == true,
      voiceSendImmediately: json['voice.send_now'] == true,
      voiceMicExplained: json['voice.mic_explained'] == true,
      voiceEngine: VoiceEngineChoice.parse(json['voice.engine']),
      notifyExplained: json['notify.explained'] == true,
      notifyDismissedDay: _day(json['notify.dismissed_day']),
      notifyDateOnly: json['notify.date_only'] != false,
      notifyDateOnlyHour: _dateOnlyHour(json['notify.date_only_hour']),
      appLock: json['security.app_lock'] == true,
      appLockAfter: _lockAfter(json['security.app_lock_after']),
      formDefaults: cleanFormDefaults(json['form_defaults']),
      homeScreenShowText: json['widgets.show_text'] != false,
      // Понимание фраз (ADR-045): прежние настройки без этих ключей —
      // модель выключена, учёба и журнал включены.
      // Прежней «Лёгкой» (rubert-tiny2, id `light`) больше нет: её выбор
      // становится нынешней «Лёгкой» (`accurate`).
      intentTier: json['intent.tier'] == 'light'
          ? IntentTier.accurate
          : IntentTier.parse(json['intent.tier']),
      intentLearning: json['intent.learning'] != false,
      intentLogging: json['intent.logging'] != false,
      intentOffered: json['intent.offered'] == true,
      genEnabled: json['gen.enabled'] == true,
      drawerExtensionsOpen: json['ui.drawer_extensions_open'] != false,
    );
  }

  /// Последние выборы в карточках: только известные поля
  /// (`converter.audio_kbps`, `archiver.level`) и допустимые значения;
  /// остальное отбрасывается.
  static Map<String, String> cleanFormDefaults(Object? value) {
    if (value is! Map) return const <String, String>{};
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in value.entries) {
      if (key is! String || value is! String) continue;
      final dot = key.indexOf('.');
      if (dot <= 0) continue;
      if (ExtensionForms.validDefault(
        key.substring(0, dot),
        key.substring(dot + 1),
        value,
      )) {
        out[key] = value;
      }
    }
    return out;
  }

  /// Во сколько напоминать о задаче на день без времени (ADR-029).
  static const int defaultDateOnlyHour = 9;

  /// Час напоминания о задаче без времени: с 5 до 12, иначе
  /// [defaultDateOnlyHour].
  static int _dateOnlyHour(Object? value) =>
      value is int && value >= 5 && value <= 12 ? value : defaultDateOnlyHour;

  /// Варианты «запрашивать после фона» (секунды): сразу, 1 мин, 5 мин.
  static const List<int> appLockAfterChoices = <int>[0, 60, 300];

  static int _lockAfter(Object? value) =>
      value is int && appLockAfterChoices.contains(value) ? value : 60;

  /// Номер версии хранилища: целое от 1, иначе `null`.
  static int? _rev(Object? value) =>
      value is int && value > 0 && value < 1 << 52 ? value : null;

  /// Кто ведёт роль: не объект — пусто; ключи — id до 64 знаков, значения
  /// — только известные помощники.
  static Map<String, String> _owners(Object? value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final MapEntry(:key, :value) in value.entries)
        if (key is String &&
            key.trim().isNotEmpty &&
            key.length <= 64 &&
            value is String &&
            Personas.byId(value) != null)
          key.trim(): value,
    };
  }

  /// «Разрешить действия»: не объект — пусто; ключ — id роли, значение —
  /// логин (до 64 знаков, без управляющих знаков). Не секрет.
  static Map<String, String> _actions(Object? value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final MapEntry(:key, :value) in value.entries)
        if (key is String &&
            key.trim().isNotEmpty &&
            key.length <= 64 &&
            value is String &&
            value.trim().isNotEmpty &&
            value.length <= 64 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))
          key.trim(): value.trim(),
    };
  }

  /// День вида `2026-11-06` или `null`.
  static String? _day(Object? value) =>
      value is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)
          ? value
          : null;

  /// [day] в виде `2026-11-06`.
  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Список id: не список — пусто, не строки и пустые строки пропускаются.
  static Set<String> _ids(Object? value) {
    if (value is! List) return const <String>{};
    return <String>{
      for (final item in value)
        if (item is String && item.trim().isNotEmpty && item.length <= 64)
          item.trim(),
    };
  }

  /// Не анимировать кубик и переходы, даже если система разрешает.
  final bool reduceMotion;

  /// Оформление: как в системе (по умолчанию), светлое или тёмное.
  final AppAppearance appearance;

  /// Время у каждого сообщения чата; выключено — время видно меткой над
  /// группой сообщений и в меню сообщения.
  final bool showTimestamps;

  /// Выключенные расширения из включённых по умолчанию
  /// (docs/EXTENSIONS.md). Новое расширение, включённое по умолчанию,
  /// сюда не попадает и после обновления появляется включённым.
  final Set<String> disabledExtensions;

  /// Явно включённые расширения из выключенных по умолчанию.
  final Set<String> enabledExtensions;

  /// Выключенные роли из включённых по умолчанию («Личное»).
  final Set<String> disabledRoles;

  /// Включённые роли из выключенных по умолчанию («Кладовщик»).
  final Set<String> enabledRoles;

  /// Кто ведёт роль в дуэте: id роли → id помощника. Нет записи — основной.
  final Map<String, String> roleOwners;

  /// «Разрешить действия» (ADR-013): id роли → логин подключения. По
  /// умолчанию пусто — действия выключены; любая смена входа запись снимает.
  final Map<String, String> roleActions;

  /// Помощники: дуэт или соло, кто основной, стили, «вы»/«ты», эмодзи.
  final PersonaSettings personas;

  /// Выбор расширений и ролей для [ExtensionRegistry.apply].
  ExtensionChoice get extensionChoice => ExtensionChoice(
        disabled: disabledExtensions,
        enabled: enabledExtensions,
        disabledRoles: disabledRoles,
        enabledRoles: enabledRoles,
        roleOwners: roleOwners,
        roleActions: roleActions,
      );

  /// Настройки с выбором расширений и ролей [choice]; остальное — как было.
  AppSettings withChoice(ExtensionChoice choice) => copyWith(
        disabledExtensions: choice.disabled,
        enabledExtensions: choice.enabled,
        disabledRoles: choice.disabledRoles,
        enabledRoles: choice.enabledRoles,
        roleOwners: choice.roleOwners,
        roleActions: choice.roleActions,
      );

  /// Служебное: день, когда второй помощник уже написал о просроченных
  /// задачах (`2026-11-06`). Не чаще раза в день, и смена настроек
  /// помощников не повторяет сообщение.
  final String? noticeDay;

  /// Служебное (навык «Пароли», раздел 4.1): самая новая версия файла
  /// хранилища, которую открывали на этом устройстве. Файл с меньшей
  /// версией — повод предупредить об откате; это не защита от вредоноса,
  /// который перепишет и этот файл.
  final int? passwordsSeenRev;

  /// Служебное (D28): хранилище на этом устройстве уже создавали. Если
  /// файла нет — «не найдено на устройстве», а не «не создано». Только
  /// да/нет: ни названий, ни числа записей.
  final bool passwordsVaultExisted;

  /// Служебное (5.8): с какого дня можно снова спросить о тренировке
  /// памяти паролей (`2026-11-12`). Только дата: ни названий, ни числа
  /// записей. Не чаще раза в день и трёх раз в неделю.
  final String? passwordsTrainingDue;

  /// Служебное: первый день с Tridot (`2026-10-15`) — для «Вместе N
  /// дней» в «Мой Связной». Записывается один раз: самая ранняя дата из
  /// задач и сессий или день первого запуска. «Очистить историю» его не
  /// трогает.
  final String? firstSeenDay;

  /// Сколько раз выбирали команду из «+» и «Найти команду» (ADR-020):
  /// id команды → число. Только id: ни текста, ни времени. По нему
  /// «Шаблоны команд» показывают самые нужные.
  final Map<String, int> commandUsage;

  /// Голосовой ввод (ADR-023) включён. По умолчанию выключен: модель
  /// распознавания (~44 МБ) скачивается, только когда его включают.
  final bool voiceInput;

  /// «Отправлять сразу»: распознанный текст уходит без правки. По
  /// умолчанию выключено — текст попадает в поле ввода. Похожее на пароль
  /// сразу не отправляется никогда.
  final bool voiceSendImmediately;

  /// Зачем нужен микрофон, уже объяснено (перед первым запросом доступа).
  final bool voiceMicExplained;

  /// Выбранное распознавание ([VoiceEngineChoice]).
  final VoiceEngineChoice voiceEngine;

  /// Зачем нужны уведомления, уже объяснено (ADR-029): лист «Напоминания
  /// вовремя» показан хотя бы раз.
  final bool notifyExplained;

  /// День последнего «Не сейчас» в листе об уведомлениях (`2026-11-15`):
  /// в этот день он больше сам не появляется. Только дата.
  final String? notifyDismissedDay;

  /// Напоминать о задачах на день без времени (в [notifyDateOnlyHour]).
  /// По умолчанию включено.
  final bool notifyDateOnly;

  /// Час напоминания о задаче на день без времени: 9 по умолчанию.
  final int notifyDateOnlyHour;

  /// «Вход в приложение по отпечатку / Face ID» (ADR-025). По умолчанию
  /// выключен. Это проверка в интерфейсе, а не шифрование.
  final bool appLock;

  /// Через сколько секунд в фоне снова спрашивать ([appLockAfterChoices]).
  final int appLockAfter;

  /// Последний выбор в карточках расширений (ADR-026): поле → значение,
  /// например `converter.audio_kbps` → `320`. Новая карточка берёт его,
  /// если во фразе не сказано другое. Только коды, без файлов и путей.
  final Map<String, String> formDefaults;

  /// Виджеты рабочего стола (ADR-034) показывают названия задач и
  /// последнюю запись. Выключено — только число дел. По умолчанию
  /// включено; при входе по отпечатку ([appLock]) текст не показывается
  /// в любом случае.
  final bool homeScreenShowText;

  /// Уровень модели понимания (ADR-045): выбран в «Понимание фраз».
  /// Выбранный, но ещё не скачанный уровень заработает после загрузки.
  final IntentTier intentTier;

  /// «Учиться на моих ответах»: «Да» и «Нет» на догадку — личные примеры
  /// на устройстве. По умолчанию включено.
  final bool intentLearning;

  /// «Собирать непонятые фразы»: локальный журнал. По умолчанию включено.
  final bool intentLogging;

  /// Предложение включить нейромодуль уже показано: больше само не появляется.
  final bool intentOffered;

  /// «Продвинутая» (ADR-046) включена: модель скачивается по выбору
  /// пользователя. По умолчанию выключено.
  final bool genEnabled;

  /// «Расширения» в меню раскрыты: как оставил человек, между открытиями
  /// меню и запусками. Впервые — раскрыты.
  final bool drawerExtensionsOpen;

  /// Текст задач уходит на виджет: включён показ и нет входа по отпечатку.
  bool get homeScreenText => homeScreenShowText && !appLock;

  AppSettings copyWith({
    AppAppearance? appearance,
    bool? reduceMotion,
    bool? showTimestamps,
    Set<String>? disabledExtensions,
    Set<String>? enabledExtensions,
    Set<String>? disabledRoles,
    Set<String>? enabledRoles,
    Map<String, String>? roleOwners,
    Map<String, String>? roleActions,
    PersonaSettings? personas,
    String? noticeDay,
    int? passwordsSeenRev,
    bool? passwordsVaultExisted,
    String? passwordsTrainingDue,
    String? firstSeenDay,
    Map<String, int>? commandUsage,
    bool? voiceInput,
    bool? voiceSendImmediately,
    bool? voiceMicExplained,
    VoiceEngineChoice? voiceEngine,
    bool? notifyExplained,
    String? notifyDismissedDay,
    bool? notifyDateOnly,
    int? notifyDateOnlyHour,
    bool? appLock,
    int? appLockAfter,
    Map<String, String>? formDefaults,
    bool? homeScreenShowText,
    IntentTier? intentTier,
    bool? intentLearning,
    bool? intentLogging,
    bool? intentOffered,
    bool? genEnabled,
    bool? drawerExtensionsOpen,
  }) =>
      AppSettings(
        appearance: appearance ?? this.appearance,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        showTimestamps: showTimestamps ?? this.showTimestamps,
        disabledExtensions: disabledExtensions ?? this.disabledExtensions,
        enabledExtensions: enabledExtensions ?? this.enabledExtensions,
        disabledRoles: disabledRoles ?? this.disabledRoles,
        enabledRoles: enabledRoles ?? this.enabledRoles,
        roleOwners: roleOwners ?? this.roleOwners,
        roleActions: roleActions ?? this.roleActions,
        personas: personas ?? this.personas,
        noticeDay: noticeDay ?? this.noticeDay,
        passwordsSeenRev: passwordsSeenRev ?? this.passwordsSeenRev,
        passwordsVaultExisted:
            passwordsVaultExisted ?? this.passwordsVaultExisted,
        passwordsTrainingDue: passwordsTrainingDue ?? this.passwordsTrainingDue,
        firstSeenDay: firstSeenDay ?? this.firstSeenDay,
        commandUsage: commandUsage ?? this.commandUsage,
        voiceInput: voiceInput ?? this.voiceInput,
        voiceSendImmediately: voiceSendImmediately ?? this.voiceSendImmediately,
        voiceMicExplained: voiceMicExplained ?? this.voiceMicExplained,
        voiceEngine: voiceEngine ?? this.voiceEngine,
        notifyExplained: notifyExplained ?? this.notifyExplained,
        notifyDismissedDay: notifyDismissedDay ?? this.notifyDismissedDay,
        notifyDateOnly: notifyDateOnly ?? this.notifyDateOnly,
        notifyDateOnlyHour: notifyDateOnlyHour ?? this.notifyDateOnlyHour,
        appLock: appLock ?? this.appLock,
        appLockAfter: appLockAfter ?? this.appLockAfter,
        formDefaults: formDefaults ?? this.formDefaults,
        homeScreenShowText: homeScreenShowText ?? this.homeScreenShowText,
        intentTier: intentTier ?? this.intentTier,
        intentLearning: intentLearning ?? this.intentLearning,
        intentLogging: intentLogging ?? this.intentLogging,
        intentOffered: intentOffered ?? this.intentOffered,
        genEnabled: genEnabled ?? this.genEnabled,
        drawerExtensionsOpen: drawerExtensionsOpen ?? this.drawerExtensionsOpen,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (appearance != AppAppearance.system) 'appearance': appearance.id,
        'reduce_motion': reduceMotion,
        // `show_timestamps` — для прежних версий после отката.
        'show_timestamps': showTimestamps,
        'message_times': showTimestamps,
        'disabled_extensions': disabledExtensions.toList()..sort(),
        'enabled_extensions': enabledExtensions.toList()..sort(),
        'disabled_roles': disabledRoles.toList()..sort(),
        'enabled_roles': enabledRoles.toList()..sort(),
        // Списки ролей пишутся всегда: по ним видно, что файл уже знает
        // роли, и перенос из enabled_extensions не повторяется.
        if (roleOwners.isNotEmpty)
          'role_owners': <String, String>{
            for (final id in roleOwners.keys.toList()..sort())
              id: roleOwners[id]!,
          },
        if (roleActions.isNotEmpty)
          'role_actions': <String, String>{
            for (final id in roleActions.keys.toList()..sort())
              id: roleActions[id]!,
          },
        ...personas.toJson(),
        if (noticeDay != null) 'notice_day': noticeDay,
        if (passwordsSeenRev != null) 'passwords.seen_rev': passwordsSeenRev,
        if (passwordsVaultExisted) 'passwords.vault_existed': true,
        if (passwordsTrainingDue != null)
          'passwords.training_due': passwordsTrainingDue,
        if (firstSeenDay != null) 'first_seen_day': firstSeenDay,
        if (commandUsage.isNotEmpty)
          'command_usage': <String, int>{
            for (final id in commandUsage.keys.toList()..sort())
              id: commandUsage[id]!,
          },
        if (voiceInput) 'voice.enabled': true,
        if (voiceSendImmediately) 'voice.send_now': true,
        if (voiceMicExplained) 'voice.mic_explained': true,
        if (voiceEngine != VoiceEngineChoice.auto)
          'voice.engine': voiceEngine.name,
        if (notifyExplained) 'notify.explained': true,
        if (notifyDismissedDay != null)
          'notify.dismissed_day': notifyDismissedDay,
        if (!notifyDateOnly) 'notify.date_only': false,
        if (notifyDateOnlyHour != defaultDateOnlyHour)
          'notify.date_only_hour': notifyDateOnlyHour,
        if (appLock) 'security.app_lock': true,
        if (appLockAfter != 60) 'security.app_lock_after': appLockAfter,
        if (formDefaults.isNotEmpty)
          'form_defaults': <String, String>{
            for (final key in formDefaults.keys.toList()..sort())
              key: formDefaults[key]!,
          },
        if (!homeScreenShowText) 'widgets.show_text': false,
        if (intentTier != IntentTier.off) 'intent.tier': intentTier.id,
        if (!intentLearning) 'intent.learning': false,
        if (!intentLogging) 'intent.logging': false,
        if (intentOffered) 'intent.offered': true,
        if (genEnabled) 'gen.enabled': true,
        if (!drawerExtensionsOpen) 'ui.drawer_extensions_open': false,
      };
}

abstract interface class SettingsStore {
  Future<AppSettings> load();

  Future<void> save(AppSettings settings);
}

final class InMemorySettingsStore implements SettingsStore {
  AppSettings _value = const AppSettings();

  @override
  Future<AppSettings> load() async => _value;

  @override
  Future<void> save(AppSettings settings) async => _value = settings;
}

/// Настройки в JSON рядом с задачами. Повреждённый файл не мешает запуску:
/// используются значения по умолчанию.
final class JsonSettingsStore implements SettingsStore {
  JsonSettingsStore(this.filePath);

  final String filePath;
  Future<void> _writes = Future<void>.value();

  @override
  Future<AppSettings> load() async {
    final file = File(filePath);
    if (!await file.exists()) return const AppSettings();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return AppSettings.fromJson(decoded);
    } on Object {
      // Повреждённый или нечитаемый файл: перезапишется при сохранении.
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) {
    final write = _writes.then((_) => _write(settings));
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> _write(AppSettings settings) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final temporary = File('$filePath.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    await temporary.rename(filePath);
  }
}
