import 'package:flutter/material.dart';

import '../../core/models/assistant_types.dart';
import '../assistant_theme.dart';

/// Что сейчас показывает кубик.
enum CubeState {
  /// Покой: серые клетки, никакой анимации.
  idle,

  /// Команда обрабатывается: клетки разлетаются.
  working,

  /// Короткая реакция на результат, потом хозяин возвращает [idle].
  completed,
  clarification,
  failed,
}

CubeState cubeStateFor(AssistantStatus status) => switch (status) {
      AssistantStatus.completed => CubeState.completed,
      AssistantStatus.needsClarification => CubeState.clarification,
      AssistantStatus.failed => CubeState.failed,
      AssistantStatus.noAction => CubeState.idle,
    };

/// Кубик 3×3 — индикатор состояния помощника. Сообщает о событии и
/// замирает: в покое не тратит кадры.
final class StatusCube extends StatelessWidget {
  const StatusCube({
    super.key,
    required this.state,
    this.reduceMotion = false,
    this.size = 32,
  });

  final CubeState state;
  final bool reduceMotion;

  /// Сторона кубика: 16 у ответа в чате, 32 — крупный вариант.
  final double size;

  static const _scatter = <Offset>[
    Offset(-2, -2),
    Offset(0, -3),
    Offset(2, -2),
    Offset(-3, 0),
    Offset.zero,
    Offset(3, 0),
    Offset(-2, 2),
    Offset(0, 3),
    Offset(2, 2),
  ];
  static const _success = <int>{2, 3, 4, 6};
  static const _failure = <int>{0, 2, 4, 6, 8};
  static const _clarification = <int>{0, 1, 2, 4, 5, 7, 8};

  static String label(CubeState state) => switch (state) {
        CubeState.idle => 'Помощник ждёт команду',
        CubeState.working => 'Команда обрабатывается',
        CubeState.completed => 'Выполнено',
        CubeState.clarification => 'Нужно уточнение',
        CubeState.failed => 'Ошибка',
      };

  Color _cellColor(BuildContext context, int index) {
    switch (state) {
      case CubeState.completed when _success.contains(index):
        return context.colors.success;
      case CubeState.failed when _failure.contains(index):
        return context.colors.danger;
      case CubeState.clarification when _clarification.contains(index):
        return context.colors.warning;
      case CubeState.working:
        return context.colors.cubeIdle;
      default:
        return context.colors.borderSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    final still = reduceMotion || MediaQuery.of(context).disableAnimations;
    final duration = Duration(milliseconds: still ? 0 : 360);
    return Semantics(
      label: label(state),
      liveRegion: true,
      child: Tooltip(
        message: label(state),
        excludeFromSemantics: true,
        child: SizedBox(
          key: const Key('status-cube'),
          width: size,
          height: size,
          child: Column(
            children: <Widget>[
              for (var row = 0; row < 3; row++) ...<Widget>[
                if (row > 0) SizedBox(height: size * .06),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      for (var column = 0; column < 3; column++) ...<Widget>[
                        if (column > 0) SizedBox(width: size * .06),
                        Expanded(
                          child: _cell(
                            context,
                            row * 3 + column,
                            still,
                            duration,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    int index,
    bool still,
    Duration duration,
  ) {
    final offset =
        state == CubeState.working && !still ? _scatter[index] : Offset.zero;
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(offset.dx, offset.dy, 0),
      color: _cellColor(context, index),
    );
  }
}
