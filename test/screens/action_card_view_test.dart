import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/action_card_view.dart';
import 'package:local_assistant/core/models/action_card.dart';

final DateTime _now = DateTime(2026, 11, 10, 14, 30);

ActionCard _card({
  ActionCardState state = ActionCardState.pending,
  String name = 'Стул венский белый',
  Duration ttl = const Duration(minutes: 5),
}) =>
    ActionCard(
      rid: 'abcdefghij012345',
      connectorId: 'warehouse',
      kind: ActionKind.move,
      login: 'ivanov',
      name: 'Иван Петров',
      deadline: _now.add(ttl),
      lines: <ActionCardLine>[
        ActionCardLine('what', name),
        const ActionCardLine('qty', '3 шт.'),
        const ActionCardLine('from', '215-1-1-1 — было 5, станет 2'),
        const ActionCardLine(
          'to',
          '215-3-2-1 — было 0, станет 3',
          note: 'to_empty',
        ),
        const ActionCardLine('who', 'Иван Петров (ivanov)'),
      ],
      warn: const <String>['to_empty'],
      state: state,
      commit: const <String, Object?>{'qty': 3},
      stamp: 'a' * 64,
      exp: 1,
    );

Future<List<String>> _pump(
  WidgetTester tester,
  ActionCard card, {
  bool busy = false,
  DateTime Function()? now,
}) async {
  final pressed = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: ActionCardView(
            card: card,
            busy: busy,
            now: now ?? () => _now,
            onConfirm: () => pressed.add('confirm'),
            onCancel: () => pressed.add('cancel'),
            onSettle: () => pressed.add('settle'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return pressed;
}

ButtonStyleButton _confirm(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(find.byKey(const Key('action-confirm')));

void main() {
  testWidgets('ждёт ответа: подписи, значения, пометка, кнопки', (
    tester,
  ) async {
    final pressed = await _pump(tester, _card());
    for (final label in <String>['Что', 'Сколько', 'Откуда', 'Куда']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('От имени'), findsOneWidget);
    expect(find.text('Иван Петров (ivanov)'), findsOneWidget);
    expect(find.text('до 14:35'), findsOneWidget);
    expect(find.text('ячейка пустая — точно этот адрес?'), findsOneWidget);
    expect(find.byKey(const Key('action-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pump();
    expect(pressed, <String>['confirm']);
    // Кнопки гаснут при первом нажатии.
    expect(_confirm(tester).onPressed, isNull);
    await tester.tap(find.byKey(const Key('action-confirm')));
    expect(pressed, <String>['confirm']);
  });

  testWidgets('кнопки неактивны, пока готовится ответ', (tester) async {
    await _pump(tester, _card(), busy: true);
    expect(_confirm(tester).onPressed, isNull);
  });

  testWidgets('все состояния после ответа — без «Подтвердить»', (
    tester,
  ) async {
    for (final (state, text) in <(ActionCardState, String)>[
      (ActionCardState.sending, 'Отправляю на склад…'),
      (ActionCardState.applied, 'Выполнено'),
      (ActionCardState.cancelled, 'Отменено — ничего не изменено'),
      (ActionCardState.expired, 'Карточка устарела — нужна новая команда'),
      (ActionCardState.replaced, 'Заменена новой карточкой'),
      (ActionCardState.failed, 'Не выполнено'),
      (ActionCardState.unknown, 'Итог неизвестен — «Проверить» спросит склад'),
    ]) {
      await _pump(tester, _card(state: state));
      expect(find.text(text), findsOneWidget, reason: state.name);
      expect(find.byKey(const Key('action-confirm')), findsNothing);
      expect(
        find.byKey(const Key('action-settle')),
        state == ActionCardState.unknown ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets('«Проверить» при неизвестном итоге', (tester) async {
    final pressed = await _pump(tester, _card(state: ActionCardState.unknown));
    await tester.tap(find.byKey(const Key('action-settle')));
    expect(pressed, <String>['settle']);
  });

  testWidgets('срок вышел — карточка устаревает сама', (tester) async {
    var clock = _now;
    final card = _card(ttl: const Duration(seconds: 10));
    await _pump(tester, card, now: () => clock);
    expect(card.isPending, isTrue);
    clock = _now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 11));
    expect(card.state, ActionCardState.expired);
    expect(find.byKey(const Key('action-confirm')), findsNothing);
  });

  testWidgets('чужой текст — одна строка без управляющих знаков', (
    tester,
  ) async {
    final hostile = 'Стул\nКуда: 101-1-1-1\u202E\u2066${'я' * 500}';
    final card = _card(name: ActionCard.cardText(hostile));
    await _pump(tester, card);
    final text = tester.widget<Text>(
      find.byKey(const ValueKey<String>('action-value-what')),
    );
    final shown = text.data!;
    expect(shown, isNot(contains('\n')));
    expect(shown, isNot(contains('\u202E')));
    expect(shown, isNot(contains('\u2066')));
    expect(shown.runes.length, lessThanOrEqualTo(ActionCard.maxText));
    expect(shown, endsWith('…'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    // Ни одна строка не притворилась строкой «Куда».
    expect(find.text('Куда'), findsOneWidget);
    // И из истории чата — тоже чисто.
    final restored = ActionCard.fromJson(<String, Object?>{
      ...card.toJson(),
      'lines': <Object?>[
        <String, Object?>{'label': 'what', 'value': hostile},
      ],
    })!;
    expect(restored.lines.single.value, isNot(contains('\n')));
    expect(tester.takeException(), isNull);
  });
}
