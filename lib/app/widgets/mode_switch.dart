import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'grouped.dart' show segmentThumbShadow;

/// Вид рабочей области: переписка или документ.
enum AssistantViewMode { dialogue, document }

/// Компактный переключатель «Диалог / Документ»: капсула из двух иконок,
/// на широком поле — с подписями справа от иконок.
final class ModeSwitch extends StatelessWidget {
  const ModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
    required this.labels,
  });

  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onChanged;
  final bool labels;

  static const List<String> _labels = <String>['Диалог', 'Документ'];

  static const TextStyle _labelStyle =
      TextStyle(fontSize: 14, fontWeight: FontWeight.w500);

  /// Ширина подписи [label] при текущем шрифте и его масштабе.
  static double _labelWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(_labelStyle),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Ширина обеих подписей при текущем шрифте и его масштабе.
  static double labelsWidth(BuildContext context) =>
      _labels.fold(0.0, (sum, l) => sum + _labelWidth(context, l));

  /// Сегменты одной ширины — по длинной подписи: бегунок не меняет размер.
  static double _segmentWidth(BuildContext context, bool labels) {
    // Без подписей — по цели нажатия: бегунок 48×40.
    if (!labels) return AppSize.minTap;
    final longest = _labels
        .map((l) => _labelWidth(context, l))
        .reduce((a, b) => a > b ? a : b);
    return (2 * _pad + _icon + _gap + longest).ceilToDouble();
  }

  static const double _track = 44;
  static const double _inset = 2;
  static const double _segment = _track - 2 * _inset;
  static const double _pad = 10;
  static const double _icon = 17;
  static const double _gap = 6;

  /// Помещаются ли подписи целиком в нижнюю строку поля ввода ширины
  /// [rowWidth]: «+» и отправка по 44, зазоры, два сегмента по длинной
  /// подписи и отступы дорожки.
  static bool labelsFit(BuildContext context, double rowWidth) =>
      rowWidth >= 2 * 44 + 16 + 2 * _segmentWidth(context, true) + 2 * _inset;

  @override
  Widget build(BuildContext context) {
    final width = _segmentWidth(context, labels);
    // Дорожка 44, бегунок 40: отступ 2 со всех сторон. Цель нажатия по
    // высоте — 48 (`AppSize.minTap`), дорожка рисуется позади.
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          child: Container(
            height: _track,
            // Сегменты заливкой, без рамок (ADR-027). Дорожка — внутри
            // панели поля: чуть темнее её, выбранный сегмент — светлее.
            decoration: BoxDecoration(
              color: context.colors.brightness == Brightness.dark
                  ? context.colors.workspace
                  : context.colors.bubble,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _inset),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _button(
                context,
                'Диалог',
                Icons.chat_bubble_outline,
                AssistantViewMode.dialogue,
                'mode-dialogue',
                width,
              ),
              _button(
                context,
                'Документ',
                Icons.edit_document,
                AssistantViewMode.document,
                'mode-document',
                width,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _button(
    BuildContext context,
    String label,
    IconData icon,
    AssistantViewMode value,
    String key,
    double width,
  ) {
    final active = mode == value;
    final color = active ? context.colors.textStrong : context.colors.muted;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: active,
        label: 'Режим: $label',
        onTap: () => onChanged(value),
        excludeSemantics: true,
        child: InkWell(
          key: Key(key),
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            width: width,
            height: AppSize.minTap,
            child: Center(child: _thumb(context, label, icon, active, color)),
          ),
        ),
      ),
    );
  }

  Widget _thumb(
    BuildContext context,
    String label,
    IconData icon,
    bool active,
    Color color,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: _segment,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Выбранный сегмент — «бегунок», как у вкладок «Мой Связной»: тот
        // же цвет и, в светлой теме, лёгкая тень (ADR-027).
        color: active ? context.colors.segmentSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        boxShadow: active ? segmentThumbShadow(context) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: _icon, color: color),
          if (labels) ...<Widget>[
            const SizedBox(width: _gap),
            // Вес один у обоих: выбор меняет только цвет, текст не
            // сдвигается.
            Text(label, style: _labelStyle.copyWith(color: color)),
          ],
        ],
      ),
    );
  }
}
