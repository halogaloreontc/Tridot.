import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/csv_import.dart';
import '../../core/passwords/import_rules.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_facade.dart';
import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';
import 'entry_screens.dart';
import 'passwords_files.dart';
import 'passwords_kit.dart';
import 'recall_views.dart';
import 'vault_confirm.dart';

enum _Step { pick, encoding, mapping, preview, done }

/// «Импорт из браузера» (5.6): CSV из Chrome, Edge, Яндекса, Firefox,
/// Safari, Bitwarden, KeePassXC. Предпросмотр с галочками и статусами
/// «новая / дубль / с другим паролем»; хранилище меняется одной записью
/// только после подтверждения. Пароли из файла на экран не выводятся;
/// при ручном сопоставлении примеры колонок — в маске.
class CsvImportScreen extends StatefulWidget {
  const CsvImportScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  PasswordsKit get kit => widget.kit;

  _Step _step = _Step.pick;
  bool _busy = false;
  String? _message;

  PickedFile? _file;
  CsvEncoding _encoding = CsvEncoding.utf8;
  List<CsvColumnInfo> _columns = const <CsvColumnInfo>[];
  CsvColumns? _suggested;
  final Map<String, int?> _roles = <String, int?>{
    'service': null,
    'url': null,
    'login': null,
    'password': null,
    'note': null,
  };

  CsvPlan? _plan;
  List<ImportMatch> _matches = const <ImportMatch>[];
  List<ImportChoice> _choices = const <ImportChoice>[];
  ImportResult? _result;
  bool _excel = false;
  bool _deleted = false;

  @override
  void initState() {
    super.initState();
    kit.addListener(_onKit);
  }

  @override
  void dispose() {
    kit.removeListener(_onKit);
    _wipe();
    super.dispose();
  }

  void _onKit() {
    if (!mounted) return;
    if (!kit.isUnlocked) {
      _wipe();
      closeVaultRoute(context);
      return;
    }
    setState(() {});
  }

  void _wipe() {
    final raw = _file?.bytes;
    raw?.fillRange(0, raw.length, 0);
    _plan?.wipe();
    _plan = null;
  }

  Future<void> _pick() async {
    setState(() => _message = null);
    final PickedFile? file;
    try {
      file = await kit.files.open(
        context,
        title: 'CSV-файл с паролями',
        extensions: const <String>['csv', 'txt'],
        maxBytes: CsvReader.maxBytes,
      );
    } on FileTooLarge {
      setState(
        () => _message = 'Файл больше 5 МБ — так много за раз не '
            'импортировать. Разделите его на части.',
      );
      return;
    } on Object {
      setState(() => _message = 'Файл не открылся.');
      return;
    }
    if (file == null || !mounted) return;
    _wipe();
    _file = file;
    _encoding = CsvEncoding.utf8;
    _analyze();
  }

  void _analyze({CsvColumns? mapping, bool manual = false}) {
    final file = _file;
    if (file == null) return;
    _plan?.wipe();
    _plan = null;
    final CsvAnalysis analysis;
    try {
      analysis = kit.analyzeCsv(
        file.bytes,
        encoding: _encoding,
        mapping: mapping,
        manual: manual,
      );
    } on CsvException catch (error) {
      setState(() {
        _step = _Step.pick;
        _message = switch (error.failure) {
          CsvFailure.tooMany => 'В файле ${error.count} записей, за раз можно '
              'до 10 000. Разделите файл на части.',
          CsvFailure.tooLarge => 'Файл больше 5 МБ.',
          CsvFailure.malformed => 'Файл не похож на CSV: незакрытая кавычка '
              'или слишком много колонок.',
          CsvFailure.empty => 'В файле нет записей.',
        };
      });
      return;
    } on Object {
      setState(() => _message = 'Не удалось разобрать файл.');
      return;
    }
    switch (analysis) {
      case CsvNeedsEncoding(:final columns):
        setState(() {
          _columns = columns;
          _step = _Step.encoding;
        });
      case CsvNeedsMapping(:final columns, :final suggested):
        setState(() {
          _columns = columns;
          _suggested = suggested;
          _roles
            ..['service'] = suggested?.service
            ..['url'] = suggested?.url
            ..['login'] = suggested?.login
            ..['password'] = suggested?.password
            ..['note'] = suggested?.note;
          _step = _Step.mapping;
        });
      case CsvRejected(:final reason):
        final text = switch (reason) {
          CsvRejection.passwordInService => 'Похоже, в колонке «Название» '
              'лежат пароли. Выберите колонки заново.',
          CsvRejection.passwordInLogin => 'Похоже, в колонке «Логин» лежат '
              'пароли. Выберите колонки заново.',
          CsvRejection.noPassword => 'Выберите колонку с паролем.',
          CsvRejection.noService => 'Выберите колонку с названием или '
              'адресом.',
          CsvRejection.sameColumn => 'Одна колонка выбрана дважды.',
        };
        if (mapping == null) {
          // Узнанный формат, но пароли не там: — ручной выбор.
          _analyze(manual: true);
        }
        setState(() {
          _message = text;
          _step = _Step.mapping;
        });
      case final CsvPlan plan:
        final items = <ImportItem>[for (final r in plan.records) r.item];
        setState(() {
          _plan = plan;
          _matches = kit.matchImport(items);
          _choices = <ImportChoice>[for (final m in _matches) m.defaultChoice];
          _message = null;
          _step = _Step.preview;
        });
    }
  }

  void _applyMapping() {
    final password = _roles['password'];
    if (password == null) {
      setState(() => _message = 'Выберите колонку с паролем.');
      return;
    }
    final s = _suggested;
    _analyze(
      mapping: CsvColumns(
        password: password,
        service: _roles['service'],
        url: _roles['url'],
        login: _roles['login'],
        note: _roles['note'],
        changed: s?.changed,
        changedMs: s?.changedMs ?? false,
        otp: s?.otp,
        type: s?.type,
        group: s?.group,
      ),
    );
  }

  void _variant(int index, int variant) {
    final record = _plan!.records[index];
    record.selected = variant;
    final match = kit.matchImport(<ImportItem>[record.item]).single;
    setState(() {
      _matches = <ImportMatch>[..._matches]..[index] = match;
      _choices = <ImportChoice>[..._choices]..[index] = match.defaultChoice;
    });
  }

  Future<void> _import() async {
    final plan = _plan;
    if (plan == null || _busy) return;
    final decisions = <ImportDecision>[
      for (var i = 0; i < plan.records.length; i++)
        ImportDecision(plan.records[i].item, _matches[i], _choices[i]),
    ];
    // «Заменить» важную запись — правка, как в редакторе (15.2).
    if (kit.importNeedsConfirm(decisions)) {
      final ok = await askVaultConfirm(
        context,
        kit: kit,
        title: 'Заменить важные записи',
        text: 'Замену важной записи нужно подтвердить.',
        check: kit.confirmProof,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final result = await kit.applyImport(decisions, fromBackup: false);
      // Пароли из файла больше не нужны — затереть сразу.
      _excel = plan.excelWarning;
      plan.wipe();
      _plan = null;
      final raw = _file?.bytes;
      raw?.fillRange(0, raw.length, 0);
      if (!mounted) return;
      setState(() {
        _result = result;
        _step = _Step.done;
      });
    } on VaultError catch (error) {
      if (mounted) setState(() => _message = vaultErrorText(error.code));
    } on Object {
      if (mounted) {
        setState(
          () => _message = 'Импорт не получился. Сейф не '
              'изменён.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteFile() async {
    final file = _file;
    if (file == null) return;
    final ok = await kit.files.delete(file.path);
    if (mounted) {
      setState(() {
        _deleted = ok;
        if (!ok) _message = 'Файл удалить не вышло — удалите его вручную.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (_step) {
      _Step.pick => _pickView(),
      _Step.encoding => _encodingView(),
      _Step.mapping => _mappingView(),
      _Step.preview => _previewView(),
      _Step.done => _doneView(),
    };
    return Scaffold(
      backgroundColor: context.colors.workspace,
      appBar: AppBar(
        backgroundColor: context.colors.workspace,
        title: const Text('Импорт из браузера'),
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _page(List<Widget> children) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          ...children,
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _message!,
                key: const ValueKey<String>('import-message'),
                style: TextStyle(color: context.colors.danger),
              ),
            ),
        ],
      );

  Widget _pickView() => _page(<Widget>[
        Text(
          'Сохраните пароли из браузера или менеджера паролей в файл CSV:',
          style: TextStyle(color: context.colors.textStrong),
        ),
        const SizedBox(height: 8),
        const _Hint(
          'Chrome, Edge, Яндекс: Настройки → Пароли (Менеджер паролей) → '
          '«Экспорт паролей».',
        ),
        const _Hint(
          'Firefox: Пароли (about:logins) → «…» → «Экспортировать пароли».',
        ),
        const _Hint('Bitwarden, KeePassXC, Safari — «Экспорт» в формате CSV.'),
        const SizedBox(height: 8),
        Text(
          'Файл CSV — открытый текст. После импорта его лучше удалить.',
          style: TextStyle(color: context.colors.warning),
        ),
        const SizedBox(height: 4),
        Text(
          kit.files.placeNote,
          style: TextStyle(color: context.colors.muted),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey<String>('import-pick'),
          onPressed: () => unawaited(_pick()),
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: const Text('Выбрать CSV-файл'),
        ),
      ]);

  Widget _columnsTable() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final c in _columns)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${c.title}: ${c.sample}',
                style: TextStyle(color: context.colors.text),
              ),
            ),
        ],
      );

  Widget _encodingView() => _page(<Widget>[
        Text(
          'Файл не в UTF-8. Прочитать как Windows-1251?',
          style: TextStyle(color: context.colors.textStrong),
        ),
        const SizedBox(height: 6),
        Text(
          'Так бывает, если файл пересохраняли в Excel. Колонки (примеры — '
          'в маске, у пароля — без примера):',
          style: TextStyle(color: context.colors.muted),
        ),
        const SizedBox(height: 8),
        _columnsTable(),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              key: const ValueKey<String>('import-cp1251'),
              onPressed: () {
                _encoding = CsvEncoding.windows1251;
                _analyze();
              },
              child: const Text('Да, Windows-1251'),
            ),
            TextButton(
              onPressed: () => setState(() => _step = _Step.pick),
              child: const Text('Другой файл'),
            ),
          ],
        ),
      ]);

  static const Map<String, String> _roleTitles = <String, String>{
    'password': 'Пароль',
    'service': 'Название',
    'url': 'Адрес',
    'login': 'Логин',
    'note': 'Заметка',
  };

  Widget _mappingView() => _page(<Widget>[
        Text(
          'Какая колонка что значит? Примеры показаны в маске.',
          style: TextStyle(color: context.colors.textStrong),
        ),
        const SizedBox(height: 4),
        Text(
          'Подсказки и отметку «Важный» из файла не берём.',
          style: TextStyle(color: context.colors.muted),
        ),
        const SizedBox(height: 12),
        for (final MapEntry(key: role, value: title) in _roleTitles.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // Подпись над списком, а не в узкой колонке слева: при крупном
            // шрифте слова не рвутся посередине («Назван/ие»).
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(color: context.colors.text),
                ),
                DropdownButton<int?>(
                  key: ValueKey<String>('import-role-$role'),
                  isExpanded: true,
                  value: _roles[role],
                  dropdownColor: context.colors.raised,
                  items: <DropdownMenuItem<int?>>[
                    const DropdownMenuItem<int?>(child: Text('— нет —')),
                    for (var i = 0; i < _columns.length; i++)
                      DropdownMenuItem<int?>(
                        value: i,
                        child: Text(
                          '${_columns[i].title} (${_columns[i].sample})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (int? value) =>
                      setState(() => _roles[role] = value),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey<String>('import-mapping-next'),
          onPressed: _applyMapping,
          child: const Text('Дальше'),
        ),
      ]);

  Widget _previewView() {
    final plan = _plan!;
    var fresh = 0;
    var same = 0;
    var conflict = 0;
    for (final m in _matches) {
      switch (m.status) {
        case ImportStatus.fresh:
          fresh++;
        case ImportStatus.same:
          same++;
        case ImportStatus.conflict:
          conflict++;
      }
    }
    final chosen = _choices.where((ImportChoice c) => c != ImportChoice.skip);
    final skipped = plan.skipped;
    // Итог и замечания прокручиваются вместе со списком: на маленьком
    // экране или при крупном шрифте они не выталкивают записи и кнопку
    // «Импортировать» за край.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Нашёл ${plan.records.length}: новых $fresh, дублей $same, '
            'с другим паролем $conflict.',
            key: const ValueKey<String>('import-summary'),
            style: TextStyle(color: context.colors.textStrong),
          ),
          if (plan.skippedTotal > 0)
            Text(
              'Пропущено ${plan.skippedTotal}: без пароля '
              '${skipped[CsvSkip.noPassword]}, служебные '
              '${skipped[CsvSkip.service]}, с ошибками '
              '${skipped[CsvSkip.invalid]}.',
              style: TextStyle(color: context.colors.muted),
            ),
          if (plan.merged > 0)
            Text(
              'Одинаковых строк склеено: ${plan.merged}.',
              style: TextStyle(color: context.colors.muted),
            ),
          if (plan.otpDropped > 0)
            Text(
              'Одноразовые коды (${plan.otpDropped}) не переносятся — '
              'они остаются в прежнем приложении.',
              style: TextStyle(color: context.colors.warning),
            ),
          if (plan.badUrls > 0)
            Text(
              'Отброшено адресов с недопустимой схемой: ${plan.badUrls}.',
              style: TextStyle(color: context.colors.warning),
            ),
          if (plan.excelWarning)
            Text(
              'Если файл открывали в Excel, часть паролей могла '
              'измениться; проверьте важные через «Проверить себя».',
              style: TextStyle(color: context.colors.warning),
            ),
          if (plan.errors.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Строки с замечаниями (${plan.errors.length})',
                style: TextStyle(color: context.colors.text),
              ),
              children: <Widget>[
                for (final e in plan.errors)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      e,
                      style: TextStyle(
                        color: context.colors.muted,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            key: const ValueKey<String>('import-preview-list'),
            itemCount: plan.records.length + 1,
            itemBuilder: (BuildContext context, int i) =>
                i == 0 ? header : _row(plan, i - 1),
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _message!,
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            key: const ValueKey<String>('import-confirm'),
            onPressed:
                _busy || chosen.isEmpty ? null : () => unawaited(_import()),
            child: Text(
              _busy ? 'Импортирую…' : 'Импортировать ${chosen.length}',
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(CsvPlan plan, int i) {
    final record = plan.records[i];
    final item = record.item;
    final match = _matches[i];
    final host =
        item.urls.isEmpty ? null : ImportRules.displayHost(item.urls.first);
    final local = host != null &&
        ImportRules.isLocal(ImportRules.hostOf(item.urls.first));
    final status = switch (match.status) {
      ImportStatus.fresh => 'новая',
      ImportStatus.same => 'дубль',
      ImportStatus.conflict => 'дубль с другим паролем',
    };
    final details = <String>[
      if (host != null) local ? '$host (локальный адрес)' : host,
      if (item.login.isNotEmpty) VaultFacade.maskLogin(item.login),
      status,
    ].join(' · ');
    return Padding(
      key: ValueKey<String>('import-row-$i'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CheckboxListTile(
            value: _choices[i] != ImportChoice.skip,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(
              item.service,
              style: TextStyle(color: context.colors.textStrong),
            ),
            subtitle: Text(
              details,
              style: TextStyle(
                color: match.status == ImportStatus.conflict
                    ? context.colors.warning
                    : context.colors.muted,
              ),
            ),
            onChanged: (bool? on) => setState(() {
              _choices = <ImportChoice>[..._choices]..[i] =
                  (on ?? false) ? ImportChoice.keepBoth : ImportChoice.skip;
            }),
          ),
          if (match.status == ImportStatus.conflict)
            Padding(
              padding: const EdgeInsets.only(left: 56, bottom: 4),
              child: DropdownButton<ImportChoice>(
                key: ValueKey<String>('import-choice-$i'),
                isExpanded: true,
                value: _choices[i],
                dropdownColor: context.colors.raised,
                items: const <DropdownMenuItem<ImportChoice>>[
                  DropdownMenuItem<ImportChoice>(
                    value: ImportChoice.keepBoth,
                    child: Text('Оставить обе'),
                  ),
                  DropdownMenuItem<ImportChoice>(
                    value: ImportChoice.replace,
                    child: Text('Заменить'),
                  ),
                  DropdownMenuItem<ImportChoice>(
                    value: ImportChoice.skip,
                    child: Text('Пропустить'),
                  ),
                ],
                onChanged: (ImportChoice? value) {
                  if (value == null) return;
                  setState(
                    () => _choices = <ImportChoice>[..._choices]..[i] = value,
                  );
                },
              ),
            ),
          if (record.needsChoice)
            Padding(
              padding: const EdgeInsets.only(left: 56, bottom: 4),
              child: DropdownButton<int>(
                key: ValueKey<String>('import-variant-$i'),
                isExpanded: true,
                value: record.selected,
                dropdownColor: context.colors.raised,
                items: <DropdownMenuItem<int>>[
                  for (var v = 0; v < record.variants.length; v++)
                    DropdownMenuItem<int>(
                      value: v,
                      child: Text(
                        importVariantTitle(
                          record.variants.length,
                          v,
                          record.variants[v].changed,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (int? v) {
                  if (v != null) _variant(i, v);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _doneView() {
    final result = _result!;
    return _page(<Widget>[
      Text(
        'Импортировано: новых ${result.added}, заменено ${result.replaced}.',
        key: const ValueKey<String>('import-done'),
        style: TextStyle(color: context.colors.textStrong, fontSize: 17),
      ),
      if (_excel)
        Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Если файл открывали в Excel, часть паролей могла измениться; '
            'проверьте важные через «Проверить себя».',
            style: TextStyle(color: context.colors.warning),
          ),
        ),
      const SizedBox(height: 12),
      Text(
        'Дальше: проверьте надёжность, отметьте важные записи и добавьте '
        'к ним подсказки — в списке «Пароли».',
        style: TextStyle(color: context.colors.text),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey<String>('import-check'),
        onPressed: () => unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => CheckScreen(kit: kit),
            ),
          ),
        ),
        icon: const Icon(Icons.shield_outlined, size: 18),
        label: const Text('Проверить пароли'),
      ),
      const SizedBox(height: 16),
      Text(
        'Файл CSV лежит открытым текстом. Удалим его?',
        style: TextStyle(color: context.colors.warning),
      ),
      const SizedBox(height: 6),
      if (_deleted)
        Text(
          'Файл удалён. Честно: на SSD удалённое иногда можно восстановить '
          'специальными программами.',
          key: ValueKey<String>('import-deleted'),
          style: TextStyle(color: context.colors.muted),
        )
      else if (kit.files.canDelete)
        OutlinedButton.icon(
          key: const ValueKey<String>('import-delete-csv'),
          onPressed: () => unawaited(_deleteFile()),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Удалить CSV-файл'),
        )
      else
        Text(
          'Удалите файл в «Файлах» (или в файловом менеджере), а также из '
          '«Загрузок» браузера и корзины. На флеш-памяти удалённое иногда '
          'восстановимо.',
          style: TextStyle(color: context.colors.muted),
        ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Готово'),
      ),
    ]);
  }
}

/// Пункт выбора пароля среди нескольких в файле: «Вариант 1 из 5 · дата
/// неизвестна» — коротко (влезает в строку) и без склонения числа.
String importVariantTitle(int count, int v, DateTime? date) {
  final when = date == null
      ? 'дата неизвестна'
      : 'изменён ${date.toLocal().toIso8601String().substring(0, 10)}';
  return 'Вариант ${v + 1} из $count · $when';
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: WholeWordText(
          '• $text',
          style: TextStyle(color: context.colors.text),
        ),
      );
}
