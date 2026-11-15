// Палитра «П2» (ADR-027): тёмная и светлая темы. Единственное место, где
// заданы цвета интерфейса; экраны берут их через `context.colors`.
import 'package:flutter/material.dart';

import '../core/personas/persona.dart';
import '../core/personas/persona_palette.dart';

/// Цвета темы. Поля называются так же, как прежние токены П1; тёмная и
/// светлая версии — [dark] и [light]. Тема кладёт палитру в
/// `ThemeData.extensions`, экраны читают её через [AppPaletteX.colors]:
/// смена темы перекрашивает экран без потери состояния.
@immutable
final class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.background,
    required this.sidebar,
    required this.panel,
    required this.workspace,
    required this.raised,
    required this.bubble,
    required this.fieldOnRaised,
    required this.divider,
    required this.borderSoft,
    required this.border,
    required this.textStrong,
    required this.text,
    required this.muted,
    required this.faint,
    required this.icon,
    required this.cubeIdle,
    required this.accent,
    required this.onAccent,
    required this.primary,
    required this.onPrimary,
    required this.cmdTint,
    required this.success,
    required this.warning,
    required this.danger,
    required this.sado,
    required this.sadoBg,
    required this.sadoOnLight,
    required this.liorio,
    required this.liorioBg,
    required this.noda,
    required this.nodaBg,
    required this.mark,
    required this.markBg,
    required this.heat0,
    required this.heat1,
    required this.heat2,
    required this.heat3,
    required this.tileGray,
    required this.tileViolet,
    required this.tileGreen,
    required this.tileBlue,
    required this.tileRed,
    required this.tileAmber,
    required this.scrim,
    required this.scrimLight,
    required this.shadow,
    required this.selection,
    required this.segmentSelected,
  });

  /// Яркость палитры: светлая или тёмная.
  final Brightness brightness;

  /// Фон сгруппированных экранов и окна: настройки, Сейф, панель, списки.
  final Color background;

  /// Фон выдвижной панели (совпадает с [background]).
  final Color sidebar;

  /// Фон колонок вокруг ленты (совпадает с [background]).
  final Color panel;

  /// «Лист» чата и документа, ячейки групп, диалоги, шторки, меню.
  final Color workspace;

  /// Карточки и поля на [workspace]: карточки в ленте, поле ввода, поиск.
  final Color raised;

  /// Пузырь пользователя, чипы, выключенный свитч, выбранная строка.
  final Color bubble;

  /// Поле и выпадающий список внутри карточки на [raised].
  final Color fieldOnRaised;

  /// Разделитель «вставкой» 0,5 логического пикселя.
  final Color divider;

  /// Остаточные мягкие контуры (пин-пад в фокусе, дорожка прогресса).
  final Color borderSoft;

  /// Контур неотмеченной галочки или радио (нетекстовый, ≥3:1).
  final Color border;

  /// Самый контрастный текст: заголовки, пузырь пользователя.
  final Color textStrong;

  /// Основной текст.
  final Color text;

  /// Вторичный текст: подписи, время, подзаголовки.
  final Color muted;

  /// Ещё тише [muted]: подсказки в полях. Не на [bubble] и [fieldOnRaised].
  final Color faint;

  /// Иконки по умолчанию.
  final Color icon;

  /// Кубик состояния в покое.
  final Color cubeIdle;

  /// Единственный акцент: ссылки, выбранное, свитч, основное действие.
  final Color accent;

  /// Текст и глиф на [accent].
  final Color onAccent;

  /// Нейтральная главная кнопка, где акцент неуместен.
  final Color primary;

  /// Текст на [primary].
  final Color onPrimary;

  /// Распознанный глагол в поле ввода во время набора.
  final Color cmdTint;

  /// «На связи», выполнено, готово.
  final Color success;

  /// Предупреждение.
  final Color warning;

  /// Просрочено, ошибка, опасное действие.
  final Color danger;

  /// Связной: цвет имени и знака.
  final Color sado;

  /// Связной: фон знака.
  final Color sadoBg;

  /// Связной на светлом фоне в любой теме.
  final Color sadoOnLight;

  /// Лиорио: цвет имени и знака.
  final Color liorio;

  /// Лиорио: фон знака.
  final Color liorioBg;

  /// Нода: цвет имени и знака.
  final Color noda;

  /// Нода: фон знака.
  final Color nodaBg;

  /// Текст совпадения в поиске.
  final Color mark;

  /// Фон совпадения в поиске.
  final Color markBg;

  /// Сетка активности: нет.
  final Color heat0;

  /// Сетка активности: мало.
  final Color heat1;

  /// Сетка активности: средне.
  final Color heat2;

  /// Сетка активности: много.
  final Color heat3;

  /// Плитка иконки в строке: серая.
  final Color tileGray;

  /// Плитка: фиолетовая.
  final Color tileViolet;

  /// Плитка: зелёная.
  final Color tileGreen;

  /// Плитка: синяя.
  final Color tileBlue;

  /// Плитка: красная.
  final Color tileRed;

  /// Плитка: янтарная.
  final Color tileAmber;

  /// Затемнение под выдвижной панелью.
  final Color scrim;

  /// Лёгкое затемнение под меню действий.
  final Color scrimLight;

  /// Тень всплывающих меню и «поднятой» строки.
  final Color shadow;

  /// Заливка выбранной строки навигации (раздел, проект, сессия): мягче
  /// [bubble], видна и на фоне панели, и на группе.
  final Color selection;

  /// «Бегунок» выбранного сегмента в переключателе вкладок.
  final Color segmentSelected;

  /// Тёмная тема П2: чёрный фон, лист чата #1C1C1E.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    background: Color(0xFF000000),
    sidebar: Color(0xFF000000),
    panel: Color(0xFF000000),
    workspace: Color(0xFF1C1C1E),
    raised: Color(0xFF2C2C2E),
    bubble: Color(0xFF3A3A3C),
    fieldOnRaised: Color(0xFF3A3A3C),
    divider: Color(0xFF38383A),
    borderSoft: Color(0xFF38383A),
    border: Color(0xFF7C7C80),
    textStrong: Color(0xFFFFFFFF),
    text: Color(0xFFEBEBF0),
    muted: Color(0xFFAEAEB2),
    faint: Color(0xFF98989F),
    icon: Color(0xFFA1A1A6),
    cubeIdle: Color(0xFF8E8E93),
    accent: Color(PersonaPalette.sado),
    onAccent: Color(0xFF1C1C1E),
    primary: Color(0xFFFFFFFF),
    onPrimary: Color(0xFF1C1C1E),
    cmdTint: Color(0xFFC9B8FF),
    success: Color(0xFF5DD39A),
    warning: Color(0xFFE0B85C),
    danger: Color(0xFFFF8A80),
    sado: Color(PersonaPalette.sado),
    sadoBg: Color(PersonaPalette.sadoBg),
    sadoOnLight: Color(PersonaPalette.sadoOnLight),
    liorio: Color(PersonaPalette.liorio),
    liorioBg: Color(PersonaPalette.liorioBg),
    noda: Color(PersonaPalette.noda),
    nodaBg: Color(PersonaPalette.nodaBg),
    mark: Color(PersonaPalette.noda),
    markBg: Color(PersonaPalette.nodaBg),
    heat0: Color(0xFF2C2C2E),
    heat1: Color(0xFF3D2F6B),
    heat2: Color(0xFF6A51C2),
    heat3: Color(0xFF9D7BFF),
    tileGray: Color(0xFF636366),
    tileViolet: Color(0xFF6A4FC4),
    tileGreen: Color(0xFF2E7D4F),
    tileBlue: Color(0xFF2F6FCF),
    tileRed: Color(0xFFD23B32),
    tileAmber: Color(0xFFB07800),
    scrim: Color(0x9E000000),
    scrimLight: Color(0x4D000000),
    shadow: Color(0x99000000),
    selection: Color(0xFF2C2C2E),
    segmentSelected: Color(0xFF636366),
  );

  /// Светлая тема П2: серый фон #F2F2F7, белый лист.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xFFF2F2F7),
    sidebar: Color(0xFFF2F2F7),
    panel: Color(0xFFF2F2F7),
    workspace: Color(0xFFFFFFFF),
    raised: Color(0xFFF2F2F7),
    bubble: Color(0xFFE9E9ED),
    fieldOnRaised: Color(0xFFFFFFFF),
    divider: Color(0xFFC6C6C8),
    borderSoft: Color(0xFFD1D1D6),
    border: Color(0xFF86868B),
    textStrong: Color(0xFF000000),
    text: Color(0xFF1C1C1E),
    muted: Color(0xFF5E5E63),
    faint: Color(0xFF636368),
    icon: Color(0xFF636368),
    cubeIdle: Color(0xFF7C7C80),
    accent: Color(PersonaPalette.sadoOnLight),
    onAccent: Color(0xFFFFFFFF),
    primary: Color(0xFF1C1C1E),
    onPrimary: Color(0xFFFFFFFF),
    cmdTint: Color(0xFF5B33C6),
    success: Color(0xFF17703F),
    warning: Color(0xFF7A5000),
    danger: Color(0xFFB3202A),
    sado: Color(PersonaPalette.sadoOnLight),
    sadoBg: Color(PersonaPalette.sadoBgOnLight),
    sadoOnLight: Color(PersonaPalette.sadoOnLight),
    liorio: Color(PersonaPalette.liorioOnLight),
    liorioBg: Color(PersonaPalette.liorioBgOnLight),
    noda: Color(PersonaPalette.nodaOnLight),
    nodaBg: Color(PersonaPalette.nodaBgOnLight),
    mark: Color(0xFF1C1C1E),
    markBg: Color(0xFFFFE08A),
    heat0: Color(0xFFE9E9ED),
    heat1: Color(0xFFD6CCFA),
    heat2: Color(0xFFA68EF0),
    heat3: Color(PersonaPalette.sadoOnLight),
    tileGray: Color(0xFF636366),
    tileViolet: Color(0xFF6A4FC4),
    tileGreen: Color(0xFF2E7D4F),
    tileBlue: Color(0xFF2F6FCF),
    tileRed: Color(0xFFD23B32),
    tileAmber: Color(0xFFB07800),
    scrim: Color(0x66000000),
    scrimLight: Color(0x33000000),
    shadow: Color(0x1F000000),
    selection: Color(0xFFE5E5EA),
    segmentSelected: Color(0xFFFFFFFF),
  );

  /// Палитра для яркости [brightness].
  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  bool get isLight => brightness == Brightness.light;

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? background,
    Color? sidebar,
    Color? panel,
    Color? workspace,
    Color? raised,
    Color? bubble,
    Color? fieldOnRaised,
    Color? divider,
    Color? borderSoft,
    Color? border,
    Color? textStrong,
    Color? text,
    Color? muted,
    Color? faint,
    Color? icon,
    Color? cubeIdle,
    Color? accent,
    Color? onAccent,
    Color? primary,
    Color? onPrimary,
    Color? cmdTint,
    Color? success,
    Color? warning,
    Color? danger,
    Color? sado,
    Color? sadoBg,
    Color? sadoOnLight,
    Color? liorio,
    Color? liorioBg,
    Color? noda,
    Color? nodaBg,
    Color? mark,
    Color? markBg,
    Color? heat0,
    Color? heat1,
    Color? heat2,
    Color? heat3,
    Color? tileGray,
    Color? tileViolet,
    Color? tileGreen,
    Color? tileBlue,
    Color? tileRed,
    Color? tileAmber,
    Color? scrim,
    Color? scrimLight,
    Color? shadow,
    Color? selection,
    Color? segmentSelected,
  }) =>
      AppPalette(
        brightness: brightness ?? this.brightness,
        background: background ?? this.background,
        sidebar: sidebar ?? this.sidebar,
        panel: panel ?? this.panel,
        workspace: workspace ?? this.workspace,
        raised: raised ?? this.raised,
        bubble: bubble ?? this.bubble,
        fieldOnRaised: fieldOnRaised ?? this.fieldOnRaised,
        divider: divider ?? this.divider,
        borderSoft: borderSoft ?? this.borderSoft,
        border: border ?? this.border,
        textStrong: textStrong ?? this.textStrong,
        text: text ?? this.text,
        muted: muted ?? this.muted,
        faint: faint ?? this.faint,
        icon: icon ?? this.icon,
        cubeIdle: cubeIdle ?? this.cubeIdle,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        primary: primary ?? this.primary,
        onPrimary: onPrimary ?? this.onPrimary,
        cmdTint: cmdTint ?? this.cmdTint,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        sado: sado ?? this.sado,
        sadoBg: sadoBg ?? this.sadoBg,
        sadoOnLight: sadoOnLight ?? this.sadoOnLight,
        liorio: liorio ?? this.liorio,
        liorioBg: liorioBg ?? this.liorioBg,
        noda: noda ?? this.noda,
        nodaBg: nodaBg ?? this.nodaBg,
        mark: mark ?? this.mark,
        markBg: markBg ?? this.markBg,
        heat0: heat0 ?? this.heat0,
        heat1: heat1 ?? this.heat1,
        heat2: heat2 ?? this.heat2,
        heat3: heat3 ?? this.heat3,
        tileGray: tileGray ?? this.tileGray,
        tileViolet: tileViolet ?? this.tileViolet,
        tileGreen: tileGreen ?? this.tileGreen,
        tileBlue: tileBlue ?? this.tileBlue,
        tileRed: tileRed ?? this.tileRed,
        tileAmber: tileAmber ?? this.tileAmber,
        scrim: scrim ?? this.scrim,
        scrimLight: scrimLight ?? this.scrimLight,
        shadow: shadow ?? this.shadow,
        selection: selection ?? this.selection,
        segmentSelected: segmentSelected ?? this.segmentSelected,
      );

  @override
  AppPalette lerp(covariant ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      background: mix(background, other.background),
      sidebar: mix(sidebar, other.sidebar),
      panel: mix(panel, other.panel),
      workspace: mix(workspace, other.workspace),
      raised: mix(raised, other.raised),
      bubble: mix(bubble, other.bubble),
      fieldOnRaised: mix(fieldOnRaised, other.fieldOnRaised),
      divider: mix(divider, other.divider),
      borderSoft: mix(borderSoft, other.borderSoft),
      border: mix(border, other.border),
      textStrong: mix(textStrong, other.textStrong),
      text: mix(text, other.text),
      muted: mix(muted, other.muted),
      faint: mix(faint, other.faint),
      icon: mix(icon, other.icon),
      cubeIdle: mix(cubeIdle, other.cubeIdle),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      primary: mix(primary, other.primary),
      onPrimary: mix(onPrimary, other.onPrimary),
      cmdTint: mix(cmdTint, other.cmdTint),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      sado: mix(sado, other.sado),
      sadoBg: mix(sadoBg, other.sadoBg),
      sadoOnLight: mix(sadoOnLight, other.sadoOnLight),
      liorio: mix(liorio, other.liorio),
      liorioBg: mix(liorioBg, other.liorioBg),
      noda: mix(noda, other.noda),
      nodaBg: mix(nodaBg, other.nodaBg),
      mark: mix(mark, other.mark),
      markBg: mix(markBg, other.markBg),
      heat0: mix(heat0, other.heat0),
      heat1: mix(heat1, other.heat1),
      heat2: mix(heat2, other.heat2),
      heat3: mix(heat3, other.heat3),
      tileGray: mix(tileGray, other.tileGray),
      tileViolet: mix(tileViolet, other.tileViolet),
      tileGreen: mix(tileGreen, other.tileGreen),
      tileBlue: mix(tileBlue, other.tileBlue),
      tileRed: mix(tileRed, other.tileRed),
      tileAmber: mix(tileAmber, other.tileAmber),
      scrim: mix(scrim, other.scrim),
      scrimLight: mix(scrimLight, other.scrimLight),
      shadow: mix(shadow, other.shadow),
      selection: mix(selection, other.selection),
      segmentSelected: mix(segmentSelected, other.segmentSelected),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPalette &&
      other.brightness == brightness &&
      other.background == background &&
      other.sidebar == sidebar &&
      other.panel == panel &&
      other.workspace == workspace &&
      other.raised == raised &&
      other.bubble == bubble &&
      other.fieldOnRaised == fieldOnRaised &&
      other.divider == divider &&
      other.borderSoft == borderSoft &&
      other.border == border &&
      other.textStrong == textStrong &&
      other.text == text &&
      other.muted == muted &&
      other.faint == faint &&
      other.icon == icon &&
      other.cubeIdle == cubeIdle &&
      other.accent == accent &&
      other.onAccent == onAccent &&
      other.primary == primary &&
      other.onPrimary == onPrimary &&
      other.cmdTint == cmdTint &&
      other.success == success &&
      other.warning == warning &&
      other.danger == danger &&
      other.sado == sado &&
      other.sadoBg == sadoBg &&
      other.sadoOnLight == sadoOnLight &&
      other.liorio == liorio &&
      other.liorioBg == liorioBg &&
      other.noda == noda &&
      other.nodaBg == nodaBg &&
      other.mark == mark &&
      other.markBg == markBg &&
      other.heat0 == heat0 &&
      other.heat1 == heat1 &&
      other.heat2 == heat2 &&
      other.heat3 == heat3 &&
      other.tileGray == tileGray &&
      other.tileViolet == tileViolet &&
      other.tileGreen == tileGreen &&
      other.tileBlue == tileBlue &&
      other.tileRed == tileRed &&
      other.tileAmber == tileAmber &&
      other.scrim == scrim &&
      other.scrimLight == scrimLight &&
      other.shadow == shadow &&
      other.selection == selection &&
      other.segmentSelected == segmentSelected;

  @override
  int get hashCode => Object.hashAll(<Object>[
        brightness,
        background,
        sidebar,
        panel,
        workspace,
        raised,
        bubble,
        fieldOnRaised,
        divider,
        borderSoft,
        border,
        textStrong,
        text,
        muted,
        faint,
        icon,
        cubeIdle,
        accent,
        onAccent,
        primary,
        onPrimary,
        cmdTint,
        success,
        warning,
        danger,
        sado,
        sadoBg,
        sadoOnLight,
        liorio,
        liorioBg,
        noda,
        nodaBg,
        mark,
        markBg,
        heat0,
        heat1,
        heat2,
        heat3,
        tileGray,
        tileViolet,
        tileGreen,
        tileBlue,
        tileRed,
        tileAmber,
        scrim,
        scrimLight,
        shadow,
        selection,
        segmentSelected,
      ]);
}

/// Палитра текущей темы: `context.colors.text`.
extension AppPaletteX on BuildContext {
  /// Палитра темы; без неё (виджет вне темы приложения) — тёмная П2.
  AppPalette get colors =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
}

/// Цвета помощника в текущей теме: акцент (имя, знак) и фон знака. Ядро
/// хранит оба набора числами, здесь выбирается нужный по яркости темы.
abstract final class PersonaColors {
  static (Color, Color) of(Persona persona, BuildContext context) =>
      ofBrightness(persona, context.colors.brightness);

  static (Color, Color) ofBrightness(Persona persona, Brightness brightness) =>
      brightness == Brightness.light
          ? (
              Color(persona.accentColorOnLight),
              Color(persona.accentBackgroundOnLight),
            )
          : (Color(persona.accentColor), Color(persona.accentBackground));
}
