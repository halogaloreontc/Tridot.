import 'package:flutter/material.dart';

final class AssistantTheme {
  const AssistantTheme._();

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      surface: Color(0xFF151715),
      onSurface: Color(0xFFC9CECA),
      primary: Color(0xFFC4C9C5),
      onPrimary: Color(0xFF171917),
      outline: Color(0xFF303431),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0D0F0E),
      canvasColor: const Color(0xFF151715),
      fontFamily: 'Inter',
      dividerTheme: const DividerThemeData(
        color: Color(0xFF242824),
        thickness: .5,
        space: 0,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14, height: 1.55),
        bodySmall: TextStyle(fontSize: 11, height: 1.45),
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
      ),
      iconTheme: const IconThemeData(color: Color(0xFF858C87), size: 18),
      snackBarTheme: const SnackBarThemeData(
        // Плавающее уведомление не прячет под собой поле ввода целиком.
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xFF242824),
        contentTextStyle: TextStyle(color: Color(0xFFC9CECA)),
      ),
    );
  }
}

/// Палитра тёмной темы. Экраны берут цвета отсюда, а не задают свои.
abstract final class AssistantColors {
  static const background = Color(0xFF0D0F0E);
  static const sidebar = Color(0xFF000000);
  static const workspace = Color(0xFF151715);
  static const panel = Color(0xFF101210);
  static const raised = Color(0xFF1C1F1C);
  static const bubble = Color(0xFF292D29);
  static const border = Color(0xFF3B403B);
  static const borderSoft = Color(0xFF2A2E2A);
  static const text = Color(0xFFC9CECA);
  static const textStrong = Color(0xFFE5E7E6);

  /// Приглушённый текст: контраст около 6:1 на [workspace].
  static const muted = Color(0xFF9AA19C);
  static const success = Color(0xFF86A98E);
  static const warning = Color(0xFFB8A47C);
  static const danger = Color(0xFFC98C8C);
}

/// Метаданные: время, пути, подписи. 11 px — минимум для читаемости.
const technicalTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 11,
  height: 1.45,
  color: AssistantColors.muted,
);
