import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/scenario/route_policy.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_phrases.dart';

import '../../tool/route_phrases.dart';

ConnectorMatch _m(
  String id,
  double confidence, {
  bool implicit = false,
  bool fallback = false,
}) =>
    ConnectorMatch(
      connectorId: id,
      commandId: '$id.cmd',
      confidence: confidence,
      implicit: implicit,
      fallback: fallback,
    );

/// Выбор, каким он был до общей функции (копия из корпусного теста и
/// tool/route_phrases.dart): совпадения по убыванию уверенности.
String? _legacy(List<ConnectorMatch> sorted) {
  if (sorted.isEmpty) return null;
  var firm = sorted;
  if (firm.any((ConnectorMatch m) => !m.fallback)) {
    firm = firm.where((ConnectorMatch m) => !m.fallback).toList();
  }
  if (firm.any((ConnectorMatch m) => !m.implicit)) {
    firm = firm.where((ConnectorMatch m) => !m.implicit).toList();
  }
  if (firm.any(
    (ConnectorMatch m) => m.connectorId == 'passwords' && !m.implicit,
  )) {
    return 'passwords';
  }
  final best = firm.first;
  for (final other in firm.skip(1)) {
    if (other.connectorId == best.connectorId) continue;
    if (best.confidence >= 0.5 &&
        other.confidence >= 0.5 &&
        best.confidence - other.confidence <= 0.15) {
      return 'ambiguous';
    }
    break;
  }
  return best.connectorId;
}

String? _picked(RouteDecision decision) =>
    decision.isAmbiguous ? 'ambiguous' : decision.winner?.connectorId;

void main() {
  group('RoutePolicy.pick', () {
    test('никого — none', () {
      final decision = RoutePolicy.pick(const <ConnectorMatch>[]);
      expect(decision.winner, isNull);
      expect(decision.isAmbiguous, isFalse);
      expect(decision.likely, isNull);
    });

    test('уверенность 0 не участвует', () {
      expect(RoutePolicy.pick(<ConnectorMatch>[_m('a', 0)]).winner, isNull);
    });

    test('крайний случай уступает, без маркера — явному', () {
      final decision = RoutePolicy.pick(<ConnectorMatch>[
        _m('talk', 0.99, fallback: true),
        _m('tasks', 0.9, implicit: true),
        _m('calc', 0.6),
      ]);
      expect(decision.winner!.connectorId, 'calc');
    });

    test('явная фраза о паролях — у навыка «Пароли»', () {
      final decision = RoutePolicy.pick(<ConnectorMatch>[
        _m('tasks', 0.95),
        _m('passwords', 0.6),
      ]);
      expect(decision.winner!.connectorId, 'passwords');
    });

    test('близкая уверенность — спор; без контекста — переспрос', () {
      final decision = RoutePolicy.pick(<ConnectorMatch>[
        _m('a', 0.8),
        _m('b', 0.75),
      ]);
      expect(decision.isAmbiguous, isTrue);
      expect(decision.first!.connectorId, 'a');
      expect(decision.second!.connectorId, 'b');
      expect(decision.likely!.connectorId, 'a');
    });

    test('в споре выигрывает коннектор из контекста сессии', () {
      final matches = <ConnectorMatch>[_m('a', 0.8), _m('b', 0.75)];
      expect(
        RoutePolicy.pick(matches, recentConnectorId: 'b').winner!.connectorId,
        'b',
      );
      expect(
        RoutePolicy.pick(matches, recentConnectorId: 'a').winner!.connectorId,
        'a',
      );
      // Чужой контекст спор не решает.
      expect(
        RoutePolicy.pick(matches, recentConnectorId: 'c').isAmbiguous,
        isTrue,
      );
    });

    test('контекст не отменяет явного победителя', () {
      final decision = RoutePolicy.pick(
        <ConnectorMatch>[_m('a', 0.95), _m('b', 0.6)],
        recentConnectorId: 'b',
      );
      expect(decision.winner!.connectorId, 'a');
    });

    test('при равной уверенности — раньше подключённый', () {
      final decision = RoutePolicy.pick(<ConnectorMatch>[
        _m('a', 0.4),
        _m('b', 0.4),
      ]);
      expect(decision.winner!.connectorId, 'a');
    });
  });

  /// Строки корпуса без контекста сессии: id, текст, «сейчас», ожидаемый
  /// коннектор.
  List<(String, String, DateTime, String)> corpus() {
    final now = DateTime(2026, 11, 2, 16, 30);
    final rows = <(String, String, DateTime, String)>[];
    for (final file in Directory('test/corpus').listSync().whereType<File>()) {
      if (!file.path.endsWith('.jsonl')) continue;
      for (final line in file.readAsLinesSync()) {
        final text = line.trim();
        if (text.isEmpty || text.startsWith('//')) continue;
        final json = jsonDecode(text) as Map<String, dynamic>;
        // Строки с контекстом сессии выбирают с ним — сравнивать без него
        // нечего.
        if (json.containsKey('after')) continue;
        final when = json['now'] as String?;
        final row = (
          json['id'] as String,
          json['text'] as String,
          when == null ? now : DateTime.parse(when),
          json['connector'] as String? ?? 'tasks',
        );
        rows.add(row);
      }
    }
    return rows;
  }

  List<ConnectorMatch> matchesOf(
    List<Connector> connectors,
    String text,
    DateTime at,
  ) {
    final utterance = Utterance.analyze(text, now: at);
    final hidden = PasswordPhrases.looksLike(utterance);
    return <ConnectorMatch>[
      for (final connector in connectors)
        if (!(hidden && connector.info.requiresNetwork))
          if (connector.match(utterance) case final ConnectorMatch m)
            if (m.confidence > 0) m,
    ];
  }

  test('на всём корпусе выбор — как прежний (без контекста)', () {
    final now = DateTime(2026, 11, 2, 16, 30);
    final connectors = appConnectors(now)
        .where((Connector c) => c.info.id != DataConnector.id)
        .toList();
    final differences = <String>[];
    final rows = corpus();
    for (final (id, text, at, _) in rows) {
      final matches = matchesOf(connectors, text, at);
      final sorted = matches.indexed.toList()
        ..sort((a, b) {
          final byConfidence = b.$2.confidence.compareTo(a.$2.confidence);
          return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
        });
      final legacy = _legacy(<ConnectorMatch>[for (final (_, m) in sorted) m]);
      final picked = _picked(RoutePolicy.pick(matches));
      if (legacy != picked) differences.add('$id: было $legacy, стало $picked');
    }
    expect(rows.length, greaterThan(2000));
    expect(differences, isEmpty);
  });

  test('«Данные» меняют выбор только в своих строках корпуса', () {
    final now = DateTime(2026, 11, 2, 16, 30);
    final all = appConnectors(now);
    final without =
        all.where((Connector c) => c.info.id != DataConnector.id).toList();
    final changed = <String>[];
    for (final (id, text, at, expected) in corpus()) {
      final before = _picked(RoutePolicy.pick(matchesOf(without, text, at)));
      final after = _picked(RoutePolicy.pick(matchesOf(all, text, at)));
      if (before != after && expected != DataConnector.id) {
        changed.add('$id «$text»: $before → $after');
      }
    }
    expect(changed, isEmpty);
  });
}
