import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../assistant_theme.dart';

/// [text] стилем [base], а название приложения внутри («Мой Tridot») —
/// шрифтом названия ([displayTextStyle], ADR-021). Cormorant Unicase мельче
/// Inter того же кегля, поэтому название чуть крупнее соседних слов.
TextSpan appNameSpan(String text, TextStyle base) {
  final at = text.indexOf(AppInfo.name);
  if (at < 0) return TextSpan(text: text, style: base);
  final size = (base.fontSize ?? 14) * displayScale;
  return TextSpan(
    style: base,
    children: <InlineSpan>[
      if (at > 0) TextSpan(text: text.substring(0, at)),
      TextSpan(
        text: AppInfo.name,
        style: displayTextStyle.copyWith(
          fontSize: size,
          color: base.color,
          height: base.height,
        ),
      ),
      if (at + AppInfo.name.length < text.length)
        TextSpan(text: text.substring(at + AppInfo.name.length)),
    ],
  );
}

/// Во сколько раз название шрифтом [displayTextStyle] крупнее текста Inter
/// рядом: так высота букв почти совпадает.
const double displayScale = 1.18;
