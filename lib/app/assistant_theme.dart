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
        backgroundColor: Color(0xFF242824),
        contentTextStyle: TextStyle(color: Color(0xFFC9CECA)),
      ),
    );
  }
}

const technicalTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 10,
  height: 1.45,
  color: Color(0xFF858C87),
);
