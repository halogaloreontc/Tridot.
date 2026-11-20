import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import '../network_status.dart';

/// Капсула состояния сети над полем ввода (ADR-040): видна только без
/// связи со складом и ещё ~2 с после того, как связь вернулась.
///
/// Плашка-«таблетка» заливкой `raised`, без рамки (S3), янтарная точка
/// (`tileAmber` / `warning`), мелкий текст. Появляется и прячется плавно ([AnimatedSize]):
/// поле ввода не прыгает. Длинная фраза не помещается в строку — короткая.
final class NetworkCapsule extends StatelessWidget {
  const NetworkCapsule({super.key, required this.status});

  final NetworkStatus status;

  /// Нет связи — полная фраза.
  static const String offlineText =
      'Нет сети — склад не ответит, задачи и проекты сохранятся и уйдут позже';

  /// Нет связи — на узкой ширине.
  static const String offlineShort = 'Нет сети — сохранится и уйдёт позже';

  /// Связь вернулась: «Сеть есть» и сколько отложенного ушло.
  static String backText(int sent) =>
      sent > 0 ? 'Сеть есть · отправлено $sent' : 'Сеть есть';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: status,
        builder: (BuildContext context, Widget? _) {
          final still = MediaQuery.of(context).disableAnimations;
          final sent = status.sent;
          return AnimatedSize(
            duration: still ? Duration.zero : const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: !status.visible
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.xs),
                    child: _Pill(
                      offline: status.offline,
                      back: status.offline || sent == null
                          ? null
                          : backText(sent),
                    ),
                  ),
          );
        },
      );
}

final class _Pill extends StatelessWidget {
  const _Pill({required this.offline, required this.back});

  final bool offline;
  final String? back;

  static const double _dot = 8;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = TextStyle(
      fontSize: 13,
      height: 1.3,
      color: offline ? colors.text : colors.muted,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints size) {
        const chrome = AppSpace.s * 2 + _dot + AppSpace.xs;
        final room = size.maxWidth - chrome;
        final String label;
        if (!offline) {
          label = back ?? '';
        } else {
          final painter = TextPainter(
            text: TextSpan(text: NetworkCapsule.offlineText, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          label = painter.width <= room
              ? NetworkCapsule.offlineText
              : NetworkCapsule.offlineShort;
          painter.dispose();
        }
        return Align(
          alignment: Alignment.center,
          child: Semantics(
            key: const Key('network-capsule'),
            liveRegion: true,
            container: true,
            label: label,
            excludeSemantics: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.raised,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: _dot,
                      height: _dot,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // Янтарная: в светлой `warning` — тёмная, для текста; точке
                        // нужна плитка `tileAmber`.
                        color: !offline
                            ? colors.success
                            : colors.isLight
                                ? colors.tileAmber
                                : colors.warning,
                      ),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Flexible(
                      child: Text(
                        label,
                        key: const Key('network-capsule-text'),
                        style: style,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
