import 'package:flutter/material.dart';

import '../core/personas/persona_palette.dart';

/// Тема приложения из токенов [AssistantColors] (палитра «П1», ADR-015).
final class AssistantTheme {
  const AssistantTheme._();

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      surface: AssistantColors.workspace,
      onSurface: AssistantColors.text,
      primary: AssistantColors.primary,
      onPrimary: AssistantColors.onPrimary,
      secondary: AssistantColors.textStrong,
      onSecondary: AssistantColors.onPrimary,
      error: AssistantColors.danger,
      onError: AssistantColors.onPrimary,
      outline: AssistantColors.border,
      outlineVariant: AssistantColors.borderSoft,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AssistantColors.background,
      canvasColor: AssistantColors.workspace,
      fontFamily: 'Inter',
      dividerTheme: const DividerThemeData(
        color: AssistantColors.divider,
        thickness: 1,
        space: 0,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14, height: 1.55),
        bodySmall: TextStyle(fontSize: 11, height: 1.45),
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
      ),
      iconTheme: const IconThemeData(color: AssistantColors.icon, size: 18),
      drawerTheme: const DrawerThemeData(
        scrimColor: AssistantColors.scrim,
        shape: RoundedRectangleBorder(),
        endShape: RoundedRectangleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AssistantColors.workspace
              : AssistantColors.icon,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AssistantColors.success
              : AssistantColors.raised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AssistantColors.success
              : AssistantColors.border,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        // Плавающее уведомление не прячет под собой поле ввода целиком.
        behavior: SnackBarBehavior.floating,
        backgroundColor: AssistantColors.divider,
        contentTextStyle: TextStyle(color: AssistantColors.text),
      ),
    );
  }
}

/// Палитра «П1» тёмной темы — единственный источник цветов. Экраны берут
/// цвета отсюда, а не задают свои.
abstract final class AssistantColors {
  /// Фон окна под колонками (совпадает с [panel]).
  static const background = Color(0xFF0F1110);
  static const sidebar = Color(0xFF0B0C0C);
  static const workspace = Color(0xFF131514);
  static const panel = Color(0xFF0F1110);
  static const raised = Color(0xFF1C1F1E);
  static const bubble = Color(0xFF2A2F2D);
  static const border = Color(0xFF46504B);
  static const borderSoft = Color(0xFF303633);

  /// Подложка хроники команд поверх ленты: [panel] с непрозрачностью
  /// около 0,85 — полосы читаются поверх сообщений.
  static const railPill = Color(0xD90F1110);

  /// Рамка поля в фокусе (раскрытый поиск по сессиям).
  static const borderFocus = Color(0xFF8A9390);

  /// Тонкие разделители: шапка, края колонок.
  static const divider = Color(0xFF262A28);
  static const text = Color(0xFFDDE2DF);
  static const textStrong = Color(0xFFF5F7F6);

  /// Приглушённый текст: контраст около 8:1 на [workspace].
  static const muted = Color(0xFFAEB6B1);

  /// Иконки по умолчанию.
  static const icon = Color(0xFFA0A9A3);

  /// Ещё тише [muted]: рамки галочек, «нет связи», подписи хроники.
  static const faint = Color(0xFF838C86);

  /// Кубик состояния в покое.
  static const cubeIdle = Color(0xFF8A9390);

  /// Главная кнопка («+» — новая сессия, отправка).
  static const primary = Color(0xFFF5F7F6);
  static const onPrimary = Color(0xFF111312);

  /// «На связи», выполнено.
  static const success = Color(0xFF4FD18B);
  static const warning = Color(0xFFB8A47C);

  /// Просрочено, ошибка.
  static const danger = Color(0xFFFF6B6B);

  /// Связной: акцент и фон знака. Третий акцент П1, фиолетовый (ADR-016).
  static const sado = Color(PersonaPalette.sado);
  static const sadoBg = Color(PersonaPalette.sadoBg);

  /// Связной на светлом фоне: светлой темы пока нет (ADR-016).
  static const sadoOnLight = Color(PersonaPalette.sadoOnLight);

  /// Лиорио: акцент и фон знака.
  static const liorio = Color(PersonaPalette.liorio);
  static const liorioBg = Color(PersonaPalette.liorioBg);

  /// Нода: акцент и фон знака.
  static const noda = Color(PersonaPalette.noda);
  static const nodaBg = Color(PersonaPalette.nodaBg);

  /// Совпадение в результатах поиска — цвета Ноды, как `mark` в макете
  /// D-Phone-Menu-Search.
  static const mark = noda;
  static const markBg = nodaBg;

  /// Уровни сетки активности: нет, мало, средне, много.
  static const heat0 = Color(0xFF262A28);
  static const heat1 = Color(0xFF256E47);
  static const heat2 = Color(0xFF33A267);
  static const heat3 = Color(0xFF4FD18B);

  /// Затемнение под выдвижной панелью.
  static const scrim = Color(0x9E000000);

  /// Подсветка команды (ADR-021): слово команды, срок и числа, метки.
  /// Мягкие, чтобы фраза читалась целиком; контраст на пузыре и поле
  /// ввода не ниже 7:1.
  static const commandVerb = Color(0xFFA8DCC0);
  static const commandValue = Color(0xFFE3D3A6);
  static const commandTag = Color(0xFFB4CBEA);
  static const commandAddress = Color(0xFFCDBEF2);

  /// Лёгкое затемнение под меню действий с сессией (макет «Ж2»).
  static const scrimLight = Color(0x4D000000);

  /// Тень всплывающих меню и «поднятой» строки.
  static const shadow = Color(0x99000000);
}

/// Шрифты приложения (ADR-021). Основной — Inter (тема); моноширинный
/// JetBrains Mono — только пароли и распознанные части команды;
/// Cormorant Unicase SemiBold — название «Tridot» и названия проектов.
abstract final class AppFonts {
  static const String text = 'Inter';
  static const String mono = 'JetBrains Mono';
  static const String display = 'Cormorant Unicase';
}

/// Метаданные: время, счётчики, версия, подписи. Inter с табличными
/// цифрами — числа в столбик не прыгают. 11 px — минимум для читаемости.
const metaTextStyle = TextStyle(
  fontFamily: AppFonts.text,
  fontSize: 12,
  height: 1.45,
  color: AssistantColors.muted,
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);

/// Моноширинный текст: значения паролей, вывод генератора, маска «••••».
/// Больше нигде (ADR-021).
const monoTextStyle = TextStyle(
  fontFamily: AppFonts.mono,
  fontFamilyFallback: <String>['monospace'],
);

/// Название приложения и проектов: Cormorant Unicase SemiBold. Буквы у
/// него одной высоты и мельче Inter того же кегля — размер задаёт место.
const displayTextStyle = TextStyle(
  fontFamily: AppFonts.display,
  fontFamilyFallback: <String>[AppFonts.text],
  fontWeight: FontWeight.w600,
  color: AssistantColors.textStrong,
);

/// Название проекта-папки в списках и меню ([displayTextStyle]).
TextStyle projectNameStyle({double fontSize = 17, Color? color}) =>
    displayTextStyle.copyWith(
      fontSize: fontSize,
      height: 1.2,
      color: color ?? AssistantColors.textStrong,
    );
