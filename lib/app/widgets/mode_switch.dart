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

  /// Ширина обеих подписей при текущем шрифте и его масштабе.
  static double labelsWidth(BuildContext context) {
    var total = 0.0;
    for (final label in const <String>['Диалог', 'Документ']) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.merge(
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      total += painter.width;
      painter.dispose();
    }
    return total;
  }

  /// Помещаются ли подписи целиком в нижнюю строку поля ввода ширины
  /// [rowWidth]: «+» и отправка по 44, зазоры, у каждого сегмента поля
  /// 12 + иконка 17 + зазор 6 + подпись по её реальной ширине + 12.
  static bool labelsFit(BuildContext context, double rowWidth) =>
      rowWidth >= 2 * 44 + 16 + 2 * (24 + 17 + 6) + labelsWidth(context);

  @override
  Widget build(BuildContext context) {
    // Видимая капсула — 44 (сегменты 40), а цель нажатия у каждого
    // сегмента — 48 (`AppSize.minTap`): дорожка рисуется позади.
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          child: Container(
            height: 44,
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
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _button(
                context,
                'Диалог',
                Icons.chat_bubble_outline,
                AssistantViewMode.dialogue,
                'mode-dialogue',
              ),
              _button(
                context,
                'Документ',
                Icons.edit_document,
                AssistantViewMode.document,
                'mode-document',
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSize.minTap,
              minWidth: AppSize.minTap,
            ),
            child: Center(
              widthFactor: 1,
              child: _segment(context, label, icon, active, color),
            ),
          ),
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    String label,
    IconData icon,
    bool active,
    Color color,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      constraints: const BoxConstraints(minHeight: 40, minWidth: 44),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: labels ? 12 : 8),
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
          Icon(icon, size: 17, color: color),
          if (labels) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
