import 'manifest_format.dart';
import 'manifest_text.dart';

/// Ссылка из ответа: что это за вещь и её код. Как открыть, решает
/// коннектор; пока ссылки показываются текстом.
final class ManifestLink {
  const ManifestLink({required this.kind, required this.id, this.label = ''});

  final String kind;
  final String id;
  final String label;
}

/// Строка ответа; у строки может быть свой вложенный список.
final class ManifestRow {
  const ManifestRow({
    this.title = '',
    this.text = '',
    this.note = '',
    this.badge = '',
    this.link,
    this.rows = const <ManifestRow>[],
    this.rest = false,
  });

  final String title;
  final String text;
  final String note;
  final String badge;
  final ManifestLink? link;
  final List<ManifestRow> rows;

  /// Свёрнутый хвост «и ещё N».
  final bool rest;
}

/// Что показать по ответу сервера: порт `askView` из core.mjs.
final class ManifestView {
  const ManifestView({
    required this.empty,
    required this.say,
    this.rows = const <ManifestRow>[],
    this.more = '',
    this.links = const <ManifestLink>[],
  });

  /// Ответ сервера → вид по шаблонам `answer` команды [command].
  factory ManifestView.of(
    ManifestCommand command,
    Map<String, Object?> response,
    Map<String, String> slots,
    ManifestVars vars,
  ) {
    final a = command.answer;
    final ctx = <Object?>[response, slots];
    ManifestLink? link(Object? spec, List<Object?> chain) {
      if (spec is! Map || !_truthy(spec['kind'])) return null;
      final condition = spec['if'];
      if (_truthy(condition) &&
          !_truthy(askGet(chain.first, jsString(condition)))) {
        return null;
      }
      final id = askFill(spec['id'] ?? absent, chain, vars);
      if (id.isEmpty) return null;
      return ManifestLink(
        kind: jsString(spec['kind']),
        id: id,
        label: _truthy(spec['label'])
            ? askTidy(askFill(spec['label'], chain, vars))
            : '',
      );
    }

    List<ManifestRow> rows(Object? spec, Object? list, List<Object?> up) {
      if (spec is! Map || list is! List) return const <ManifestRow>[];
      final rawMax = spec['max'];
      final max = rawMax is num && rawMax > 0 ? rawMax.toInt() : list.length;
      final out = <ManifestRow>[
        for (final row in list.take(max))
          () {
            final chain = <Object?>[row, ...up];
            String fill(String key) =>
                askTidy(askFill(spec[key] ?? absent, chain, vars));
            return ManifestRow(
              title: fill('title'),
              text: fill('text'),
              note: fill('note'),
              badge: fill('badge'),
              link: link(spec['link'], chain),
              rows: _truthy(spec['list'])
                  ? rows(
                      spec['item'],
                      askGet(row, jsString(spec['list'])),
                      chain,
                    )
                  : const <ManifestRow>[],
            );
          }(),
      ];
      if (list.length > max) {
        out.add(
          ManifestRow(text: 'и ещё ${askNum(list.length - max)}', rest: true),
        );
      }
      return out;
    }

    final listPath = a['list'];
    final list =
        _truthy(listPath) ? askGet(response, jsString(listPath)) : null;
    final empty = _truthy(listPath) && (list is! List || list.isEmpty);
    final morePath = a['more'];
    final rawLinks = a['links'];
    return ManifestView(
      empty: empty,
      say: askTidy(
        askFill(
          empty && _truthy(a['empty']) ? a['empty'] : a['say'] ?? absent,
          ctx,
          vars,
        ),
      ),
      rows: empty ? const <ManifestRow>[] : rows(a['item'], list, ctx),
      more: _truthy(morePath) && _truthy(askGet(response, jsString(morePath)))
          ? askTidy(
              askFill(
                a['moreText'] ?? 'Показаны не все — уточните запрос',
                ctx,
                vars,
              ),
            )
          : '',
      links: empty || rawLinks is! List
          ? const <ManifestLink>[]
          : <ManifestLink>[
              for (final spec in rawLinks)
                if (link(spec, ctx) case final ManifestLink l) l,
            ],
    );
  }

  final bool empty;
  final String say;
  final List<ManifestRow> rows;

  /// Пометка «показаны не все»; пусто — показано всё.
  final String more;
  final List<ManifestLink> links;

  /// Сколько строк первого уровня показывать в чате.
  static const int chatRows = 8;

  /// Строки текстом для чата: «• 64115 — Стул венский — 12 шт.», вложенные
  /// с отступом, лишнее — «и ещё N». Пусто — строк нет.
  List<String> lines({int maxRows = chatRows}) {
    final out = <String>[];
    void add(List<ManifestRow> list, int depth, int limit) {
      var shown = 0;
      var hidden = 0;
      for (final row in list) {
        if (row.rest) {
          final count = int.tryParse(
                row.text.replaceAll(RegExp(r'\D'), ''),
              ) ??
              0;
          hidden += count;
          continue;
        }
        if (shown >= limit) {
          hidden++;
          continue;
        }
        shown++;
        out.add('${depth == 0 ? '• ' : '   – '}${_line(row)}');
        if (row.rows.isNotEmpty) add(row.rows, depth + 1, 1 << 30);
      }
      if (hidden > 0) {
        out.add('${depth == 0 ? '' : '   '}и ещё ${askNum(hidden)}');
      }
    }

    add(rows, 0, maxRows);
    return out;
  }

  static String _line(ManifestRow row) {
    final head = <String>[
      for (final part in <String>[row.title, row.text])
        if (part.isNotEmpty) part,
    ].join(' — ');
    final badge = row.badge.isEmpty ? '' : ' — ${row.badge}';
    final note = row.note.isEmpty ? '' : ' (${row.note})';
    return '${head.isEmpty ? row.badge : '$head$badge'}$note'.trim();
  }

  static bool _truthy(Object? value) {
    if (value == null || identical(value, absent)) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    return true;
  }
}
