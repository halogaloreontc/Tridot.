import 'package:flutter/material.dart';

import 'app_palette.dart';

export 'app_palette.dart';

/// Тема приложения из палитры [AppPalette] («П2», ADR-027): тёмная и
/// светлая, шкала текста 17/15/13 (ADR-021, ADR-027). Поверхности
/// разделяет заливка, а не линия: поля, кнопки, чипы и диалоги без рамок.
final class AssistantTheme {
  const AssistantTheme._();

  /// Тёмная тема: чёрный фон, лист чата #1C1C1E.
  static ThemeData dark() => build(AppPalette.dark);

  /// Светлая тема: фон #F2F2F7, белый лист.
  static ThemeData light() => build(AppPalette.light);

  /// Шкала текста (ADR-027, ADR-021): Golos Text 17/15/13. Цвет в стилях
  /// не задан — он приходит из `DefaultTextStyle` или палитры; только у
  /// [TextTheme.bodySmall] и [TextTheme.labelMedium] по умолчанию
  /// приглушённый. Семейство задано в каждом стиле: `styleFrom(textStyle:)`
  /// иначе теряет шрифт приложения. Межбуквенный интервал у Golos мягче,
  /// чем был у Inter: −0,1 у основного, 0 у второстепенного, +0,1 у подписей,
  /// −0,2…−0,3 у заголовков.
  static TextTheme textTheme(AppPalette p) => TextTheme(
        displayLarge: _text(34, 1.18, FontWeight.w700, -0.3),
        displayMedium: _text(32, 1.18, FontWeight.w700, -0.3),
        displaySmall: _text(30, 1.2, FontWeight.w700, -0.3),
        headlineLarge: _text(30, 1.2, FontWeight.w700, -0.3),
        headlineMedium: _text(28, 1.2, FontWeight.w700, -0.3),
        headlineSmall: _text(22, 1.25, FontWeight.w600, -0.2),
        titleLarge: _text(22, 1.25, FontWeight.w600, -0.2),
        titleMedium: _text(17, 1.29, FontWeight.w600, -0.1),
        titleSmall: _text(15, 1.33, FontWeight.w600, 0),
        bodyLarge: _text(17, 1.45, FontWeight.w400, -0.1),
        bodyMedium: _text(15, 1.4, FontWeight.w400, 0),
        // Без табличных цифр: пропорциональные ровнее в тексте. Табличные —
        // только у [metaNumTextStyle] (время и счётчики в столбик).
        bodySmall: _text(13, 1.38, FontWeight.w400, 0.1).copyWith(
          color: p.muted,
        ),
        labelLarge: _text(17, 1.29, FontWeight.w600, -0.1),
        labelMedium: _text(15, 1.33, FontWeight.w600, 0).copyWith(
          color: p.muted,
        ),
        labelSmall: _text(13, 1.38, FontWeight.w500, 0.1),
      );

  static TextStyle _text(
    double size,
    double height,
    FontWeight weight,
    double spacing,
  ) =>
      TextStyle(
        fontFamily: AppFonts.text,
        fontSize: size,
        height: height,
        fontWeight: weight,
        letterSpacing: spacing,
      );

  /// Тема из палитры [p]. Все компонентные темы — здесь: экраны не
  /// рисуют свои рамки и заливки полей, кнопок, чипов и диалогов.
  static ThemeData build(AppPalette p) {
    final light = p.isLight;
    final text = textTheme(p).apply(
      bodyColor: p.text,
      displayColor: p.textStrong,
    );
    // `apply` перекрашивает и приглушённые стили — возвращаем им цвет.
    final texts = text.copyWith(
      bodySmall: text.bodySmall!.copyWith(color: p.muted),
      labelMedium: text.labelMedium!.copyWith(color: p.muted),
    );
    final scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.sadoBg,
      onPrimaryContainer: p.accent,
      secondary: p.accent,
      onSecondary: p.onAccent,
      secondaryContainer: p.bubble,
      onSecondaryContainer: p.textStrong,
      tertiary: p.liorio,
      onTertiary: p.onAccent,
      error: p.danger,
      onError: light ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E),
      surface: p.workspace,
      onSurface: p.text,
      onSurfaceVariant: p.muted,
      surfaceContainerLowest: p.workspace,
      surfaceContainerLow: p.workspace,
      surfaceContainer: p.workspace,
      surfaceContainerHigh: p.raised,
      surfaceContainerHighest: p.bubble,
      surfaceTint: const Color(0x00000000),
      outline: p.border,
      outlineVariant: p.divider,
      shadow: p.shadow,
      scrim: p.scrim,
      inverseSurface: light ? const Color(0xFF2C2C2E) : p.bubble,
      onInverseSurface: light ? const Color(0xFFFFFFFF) : p.text,
      inversePrimary: light ? AppPalette.dark.accent : AppPalette.light.accent,
    );
    const field = BorderRadius.all(Radius.circular(12));
    final noBorder = WidgetStatePropertyAll<BorderSide>(BorderSide.none);
    final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(
      const RoundedRectangleBorder(borderRadius: field),
    );
    final label = texts.labelLarge!;
    final popover = light ? p.workspace : p.raised;
    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[p],
      scaffoldBackgroundColor: p.background,
      canvasColor: p.workspace,
      cardColor: p.workspace,
      dividerColor: p.divider,
      hintColor: p.faint,
      disabledColor: p.faint,
      fontFamily: AppFonts.text,
      textTheme: texts,
      primaryTextTheme: texts,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: InkRipple.splashFactory,
      dividerTheme: DividerThemeData(
        color: p.divider,
        thickness: 0.5,
        space: 0,
      ),
      iconTheme: IconThemeData(color: p.icon, size: 22),
      listTileTheme: ListTileThemeData(
        minTileHeight: 52,
        iconColor: p.icon,
        textColor: p.text,
        titleTextStyle: texts.bodyLarge!.copyWith(color: p.textStrong),
        subtitleTextStyle: texts.bodyMedium!.copyWith(color: p.muted),
        leadingAndTrailingTextStyle: texts.bodyLarge!.copyWith(color: p.muted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: const Color(0x00000000),
        centerTitle: false,
        titleTextStyle: texts.titleMedium!.copyWith(color: p.textStrong),
        iconTheme: IconThemeData(color: p.accent, size: 24),
        actionsIconTheme: IconThemeData(color: p.accent, size: 24),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: p.background,
        surfaceTintColor: const Color(0x00000000),
        scrimColor: p.scrim,
        elevation: 0,
        shape: const RoundedRectangleBorder(),
        endShape: const RoundedRectangleBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.raised,
        isDense: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: texts.bodyLarge!.copyWith(color: p.faint),
        labelStyle: texts.bodyMedium!.copyWith(color: p.muted),
        // Поднятая подпись рисуется в 0.75 от своего размера: 17.5 даёт
        // 13 px — не мельче минимума (ADR-027). Подпись — внутри заливки,
        // а не в разрыве контура: [FilledFieldBorder] не контурная.
        floatingLabelStyle: texts.bodyMedium!.copyWith(
          color: p.muted,
          fontSize: kFloatingLabelSize,
        ),
        helperStyle: texts.bodySmall!.copyWith(color: p.muted),
        errorStyle: texts.bodySmall!.copyWith(color: p.danger),
        prefixIconColor: p.icon,
        suffixIconColor: p.icon,
        border: const FilledFieldBorder(),
        enabledBorder: const FilledFieldBorder(),
        disabledBorder: const FilledFieldBorder(),
        focusedBorder: FilledFieldBorder(
          borderSide: BorderSide(color: p.accent, width: 1.5),
        ),
        errorBorder: FilledFieldBorder(
          borderSide: BorderSide(color: p.danger, width: 1.5),
        ),
        focusedErrorBorder: FilledFieldBorder(
          borderSide: BorderSide(color: p.danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.disabled) ? p.bubble : p.accent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.disabled) ? p.muted : p.onAccent,
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(label),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(64, 48)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          shape: buttonShape,
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      // Второстепенная кнопка — «тональная»: заливка без рамки.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) => s.contains(WidgetState.disabled)
                ? p.bubble.withValues(alpha: 0.5)
                : p.bubble,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.disabled) ? p.muted : p.accent,
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(label),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 48)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          side: noBorder,
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.disabled) ? p.muted : p.accent,
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(label),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 48)),
          shape: buttonShape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(p.bubble),
          foregroundColor: WidgetStatePropertyAll<Color>(p.accent),
          textStyle: WidgetStatePropertyAll<TextStyle>(label),
          elevation: const WidgetStatePropertyAll<double>(0),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 48)),
          shape: buttonShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 48)),
          iconSize: const WidgetStatePropertyAll<double>(22),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: p.workspace,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: field),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.bubble,
        selectedColor: p.accent.withValues(alpha: 0.15),
        disabledColor: p.bubble.withValues(alpha: 0.5),
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
        labelStyle: texts.bodyMedium!.copyWith(color: p.text),
        secondaryLabelStyle: texts.bodyMedium!.copyWith(color: p.accent),
        checkmarkColor: p.accent,
        iconTheme: IconThemeData(color: p.icon, size: 18),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        showCheckmark: false,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.background,
        modalBackgroundColor: p.background,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        modalElevation: 0,
        shadowColor: light ? p.shadow : const Color(0x00000000),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        dragHandleColor: p.faint.withValues(alpha: 0.4),
        dragHandleSize: const Size(36, 5),
      ),
      // Диалоги на телефоне — почти во всю ширину (поля 16, а не 40):
      // с крупным шрифтом заголовок и кнопки не рвут слова (ADR-021).
      dialogTheme: DialogThemeData(
        backgroundColor: p.workspace,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        titleTextStyle: texts.titleMedium!.copyWith(color: p.textStrong),
        contentTextStyle: texts.bodyMedium!.copyWith(color: p.text),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      ),
      // Поповер: в светлой — белый с тенью, в тёмной — на уровень светлее
      // листа чата (#2C2C2E), иначе меню сливается с лентой (§1.1).
      popupMenuTheme: PopupMenuThemeData(
        color: popover,
        surfaceTintColor: const Color(0x00000000),
        elevation: light ? 8 : 0,
        shadowColor: p.shadow,
        shape: const RoundedRectangleBorder(borderRadius: field),
        textStyle: texts.bodyLarge!.copyWith(color: p.text),
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          texts.bodyLarge!.copyWith(color: p.text),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(popover),
          surfaceTintColor:
              const WidgetStatePropertyAll<Color>(Color(0x00000000)),
          elevation: WidgetStatePropertyAll<double>(light ? 8 : 0),
          shadowColor: WidgetStatePropertyAll<Color>(p.shadow),
          side: noBorder,
          shape: buttonShape,
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: texts.bodyLarge!.copyWith(color: p.textStrong),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(popover),
          surfaceTintColor:
              const WidgetStatePropertyAll<Color>(Color(0x00000000)),
          side: noBorder,
          shape: buttonShape,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? p.onAccent : p.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? p.accent : p.bubble,
        ),
        trackOutlineColor:
            const WidgetStatePropertyAll<Color>(Color(0x00000000)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) => s.contains(WidgetState.selected)
              ? p.accent
              : const Color(0x00000000),
        ),
        checkColor: WidgetStatePropertyAll<Color>(p.onAccent),
        side: BorderSide(color: p.border, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? p.accent : p.border,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.selected) ? p.workspace : p.bubble,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (Set<WidgetState> s) =>
                s.contains(WidgetState.selected) ? p.textStrong : p.text,
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(texts.bodyMedium!),
          side: noBorder,
          minimumSize: const WidgetStatePropertyAll<Size>(Size(48, 44)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.accent,
        unselectedLabelColor: p.muted,
        indicatorColor: p.accent,
        dividerColor: const Color(0x00000000),
        labelStyle: texts.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: texts.bodyMedium,
      ),
      // Полоса прогресса: акцент на мягкой дорожке.
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.bubble,
        circularTrackColor: const Color(0x00000000),
        linearMinHeight: 4,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.bubble,
        thumbColor: p.accent,
        overlayColor: p.accent.withValues(alpha: 0.12),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withValues(alpha: 0.3),
        selectionHandleColor: p.accent,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: light ? const Color(0xFF2C2C2E) : p.bubble,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        textStyle: texts.bodySmall!.copyWith(
          color: light ? const Color(0xFFFFFFFF) : p.text,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        // Плавающее уведомление не прячет под собой поле ввода целиком.
        behavior: SnackBarBehavior.floating,
        backgroundColor: light ? const Color(0xFF2C2C2E) : p.bubble,
        actionTextColor: light ? AppPalette.dark.accent : p.accent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: field),
        // Шрифт явно: без него SnackBar берёт системный (Roboto), а не
        // шрифт приложения (ADR-021).
        contentTextStyle: texts.bodyMedium!.copyWith(
          fontFamily: AppFonts.text,
          color: light ? const Color(0xFFFFFFFF) : p.text,
        ),
      ),
    );
  }
}

/// Размер поднятой подписи поля до масштаба 0.75 Material: 13 px на экране.
const double kFloatingLabelSize = 17.5;

/// Рамка залитого поля (§4.1): скруглённая заливка без контура; контур
/// 1.5 — только в фокусе и при ошибке. В отличие от
/// [OutlineInputBorder] не контурная ([isOutline] — `false`): поднятая
/// подпись стоит внутри заливки, без «выреза» в линии.
class FilledFieldBorder extends OutlineInputBorder {
  const FilledFieldBorder({
    super.borderSide = BorderSide.none,
    super.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  bool get isOutline => false;

  @override
  FilledFieldBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) =>
      FilledFieldBorder(
        borderSide: borderSide ?? this.borderSide,
        borderRadius: borderRadius ?? this.borderRadius,
      );

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  FilledFieldBorder scale(double t) => FilledFieldBorder(
        borderSide: borderSide.scale(t),
        borderRadius: borderRadius * t,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is FilledFieldBorder) {
      return FilledFieldBorder(
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is FilledFieldBorder) {
      return FilledFieldBorder(
        borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
        borderRadius: BorderRadius.lerp(borderRadius, b.borderRadius, t)!,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none || borderSide.width == 0) {
      return;
    }
    final outer = borderRadius.toRRect(rect);
    canvas.drawRRect(
      outer.deflate(borderSide.strokeInset),
      borderSide.toPaint(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FilledFieldBorder &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(borderSide, borderRadius);
}

/// Шрифты приложения (ADR-021, ADR-027). Основной — Golos Text (тема);
/// моноширинный JetBrains Mono — только пароли и коды восстановления;
/// Cormorant Unicase SemiBold — название «Tridot» и названия проектов.
abstract final class AppFonts {
  static const String text = 'Golos Text';
  static const String mono = 'JetBrains Mono';
  static const String display = 'Cormorant Unicase';
}

/// Метаданные: подписи, футеры, версия. 13 — минимум (ADR-027).
/// Цвета нет: он из палитры (`colors.muted`) или `bodySmall`. Табличных
/// цифр нет: в подписи пропорциональные ровнее.
const metaTextStyle = TextStyle(
  fontFamily: AppFonts.text,
  fontSize: 13,
  height: 1.38,
  letterSpacing: 0.1,
);

/// [metaTextStyle] с табличными цифрами — только время и счётчики, где
/// числа стоят в столбик и не должны прыгать.
const metaNumTextStyle = TextStyle(
  fontFamily: AppFonts.text,
  fontSize: 13,
  height: 1.38,
  letterSpacing: 0.1,
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);

/// Моноширинный текст: значения паролей, вывод генератора, маска «••••»,
/// код восстановления. Больше нигде (ADR-021, ADR-027).
const monoTextStyle = TextStyle(
  fontFamily: AppFonts.mono,
  fontFamilyFallback: <String>['monospace'],
);

/// Название приложения и проектов: Cormorant Unicase SemiBold. Буквы у
/// него одной высоты и мельче Golos Text того же кегля — размер задаёт место.
/// Цвета нет — он из палитры.
const displayTextStyle = TextStyle(
  fontFamily: AppFonts.display,
  fontFamilyFallback: <String>[AppFonts.text],
  fontWeight: FontWeight.w600,
);

/// Название проекта-папки в списках и меню ([displayTextStyle]).
TextStyle projectNameStyle({double fontSize = 17, required Color color}) =>
    displayTextStyle.copyWith(fontSize: fontSize, height: 1.2, color: color);

/// [metaTextStyle] приглушённым цветом текущей темы — время, счётчики,
/// подписи.
TextStyle metaStyle(BuildContext context) =>
    metaTextStyle.copyWith(color: context.colors.muted);

/// [metaNumTextStyle] приглушённым цветом — время и счётчики.
TextStyle metaNumStyle(BuildContext context) =>
    metaNumTextStyle.copyWith(color: context.colors.muted);
