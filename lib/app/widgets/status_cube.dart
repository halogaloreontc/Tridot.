import 'package:flutter/material.dart';

import '../../core/models/assistant_types.dart';

final class StatusCube extends StatefulWidget {
  const StatusCube({
    super.key,
    required this.status,
    required this.moving,
  });

  final AssistantStatus status;
  final bool moving;

  @override
  State<StatusCube> createState() => _StatusCubeState();
}

final class _StatusCubeState extends State<StatusCube>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave;

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

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4800),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant StatusCube oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != AssistantStatus.completed || widget.moving) {
      _wave.stop();
    } else {
      _wave.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.of(context).disableAnimations;
    if (disabled && _wave.isAnimating) _wave.stop();
    return SizedBox(
      key: const Key('status-cube'),
      width: 32,
      height: 32,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 1.92,
          crossAxisSpacing: 1.92,
        ),
        itemCount: 9,
        itemBuilder: (context, index) {
          final offset =
              widget.moving && !disabled ? _scatter[index] : Offset.zero;
          return AnimatedContainer(
            duration: Duration(milliseconds: disabled ? 0 : 360),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(offset.dx, offset.dy, 0),
            child: _Cell(
              index: index,
              wave: _wave,
              status: widget.status,
            ),
          );
        },
      ),
    );
  }
}

final class _Cell extends AnimatedWidget {
  const _Cell({
    required this.index,
    required Animation<double> wave,
    required this.status,
  }) : super(listenable: wave);

  final int index;
  final AssistantStatus status;

  Color? get reactionColor {
    if (status == AssistantStatus.completed &&
        _StatusCubeState._success.contains(index)) {
      return const Color(0xFF86A98E);
    }
    if (status == AssistantStatus.failed &&
        _StatusCubeState._failure.contains(index)) {
      return const Color(0xFFB98080);
    }
    if (status == AssistantStatus.needsClarification &&
        _StatusCubeState._clarification.contains(index)) {
      return const Color(0xFFB8A47C);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final wave = listenable as Animation<double>;
    final reaction = reactionColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: reaction ??
            Color.lerp(
              const Color(0xFF34393E),
              const Color(0xFF62686D),
              wave.value * .55,
            ),
      ),
    );
  }
}
