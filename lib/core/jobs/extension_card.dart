/// Карточка-форма расширения в чате (docs/PLANS.md, «Карточки-формы»):
/// поля → «Запустить» → ход работы и «Отмена» → «Открыть» / «Открыть
/// папку» или ошибка с «Повторить». Одна общая модель для всех расширений,
/// которые работают с файлами: архиватор, позже конвертер и загрузчик.
///
/// Схему полей карточка не хранит — её строит ядро по [extensionId]
/// ([ExtensionForms]); в истории чата лежат только значения полей и
/// состояние. Ход работы ([progress], [stage]) живёт только в памяти.
library;

import '../models/action_card.dart';
import '../skills/ytdl/ytdl_formats.dart';
import 'extension_forms.dart';
import 'job_placement.dart';

export 'extension_forms.dart';

/// Состояние карточки.
enum CardState {
  /// Поля заполняются, «Запустить».
  form,

  /// Задача идёт: ход работы и «Отмена».
  running,

  /// Готово: «Открыть», «Открыть папку».
  done,

  /// Ошибка ([ExtensionCard.errorCode]) и «Повторить».
  failed,

  /// Отменено пользователем.
  cancelled,

  /// Приложение закрыли посреди работы: после перезапуска — «Прервано».
  interrupted;

  static CardState? parse(Object? value) =>
      CardState.values.where((CardState s) => s.name == value).firstOrNull;

  /// Задача закончилась так или иначе: можно «Повторить».
  bool get retryable =>
      this == failed || this == cancelled || this == interrupted;
}

/// Файл в поле карточки: с диска (абсолютный путь) или вложение сессии
/// (путь относительно папки чатов, `files/<сессия>/<файл>`).
final class JobFile {
  const JobFile({
    required this.path,
    required this.name,
    this.attachment = false,
    this.folder = false,
  });

  /// Абсолютный путь или путь вложения ([attachment]).
  final String path;

  /// Имя для показа и для записи в архиве.
  final String name;

  /// Вложение сессии (ADR-019), а не файл с диска.
  final bool attachment;

  /// Папка целиком (только с диска на компьютере).
  final bool folder;

  /// Архив ZIP по имени.
  bool get isZip => name.toLowerCase().endsWith('.zip');

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'name': name,
        if (attachment) 'att': true,
        if (folder) 'dir': true,
      };

  /// Повреждённая запись — `null`.
  static JobFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final name = json['name'];
    if (path is! String || name is! String) return null;
    final cleanPath = ExtensionCard.cleanPath(path);
    if (cleanPath == null) return null;
    final shown = ActionCard.cardText(name, max: 200);
    if (shown.isEmpty) return null;
    return JobFile(
      path: cleanPath,
      name: shown,
      attachment: json['att'] == true,
      folder: json['dir'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JobFile &&
      other.path == path &&
      other.attachment == attachment &&
      other.folder == folder &&
      other.name == name;

  @override
  int get hashCode => Object.hash(path, name, attachment, folder);
}

/// Карточка расширения. Один объект на карточку: его держат сообщение
/// чата и исполнитель задачи; состояние меняется на месте, после смены
/// состояния чат сохраняется (`ChatBook.touch`).
final class ExtensionCard {
  ExtensionCard({
    required this.id,
    required this.extensionId,
    required this.updatedAt,
    this.schema = currentSchema,
    Map<String, Object?>? values,
    this.state = CardState.form,
    List<String>? outputs,
    this.outputDir,
    this.errorCode,
    List<String>? cleanup,
    List<String>? listing,
    this.listingMore = 0,
  })  : values = values ?? <String, Object?>{},
        outputs = outputs ?? <String>[],
        cleanup = cleanup ?? <String>[],
        listing = listing ?? <String>[];

  /// Версия формы.
  static const int currentSchema = 1;

  /// Сколько строк содержимого архива хранит карточка.
  static const int listingLimit = 200;

  /// Самый длинный путь, который карточка принимает из файла чата.
  static const int pathLimit = 4096;

  /// `j<микросекунды>_<номер>`: он же имя папки результата в сессии
  /// (`files/<сессия>/out/<id>`).
  final String id;

  /// `archiver`, `converter`, `ytdl`.
  final String extensionId;

  final int schema;

  /// Код поля → значение: строка, список [JobFile].
  final Map<String, Object?> values;

  CardState state;

  /// 0..1 или `null` (неизвестно). Только в памяти.
  double? progress;

  /// «Сжатие», «Распаковка». Только в памяти.
  String? stage;

  /// Абсолютные пути результатов.
  List<String> outputs;

  /// Папка результата — для «Открыть папку».
  String? outputDir;

  /// Код ошибки ([JobCodes]).
  String? errorCode;

  /// Временные пути (`.part`, временные папки): убираются, если задачу
  /// прервали.
  List<String> cleanup;

  /// Содержимое архива («Посмотреть содержимое»): первые [listingLimit]
  /// строк.
  List<String> listing;

  /// Сколько строк не поместилось в [listing].
  int listingMore;

  DateTime updatedAt;

  /// Расширение этой сборки знает карточку: иначе она только для чтения
  /// («Расширение недоступно»).
  bool get known => ExtensionForms.of(extensionId) != null;

  /// Значение поля-выбора [code].
  String? choice(String code) {
    final value = values[code];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Файлы поля [code].
  List<JobFile> files([String code = 'files']) {
    final value = values[code];
    return value is List ? value.whereType<JobFile>().toList() : <JobFile>[];
  }

  /// Новые значения поля: задача ещё не идёт.
  void setValue(String code, Object? value) {
    if (value == null) {
      values.remove(code);
    } else {
      values[code] = value;
    }
  }

  /// «Повторить»: снова форма с теми же значениями.
  void reset(DateTime now) {
    state = CardState.form;
    progress = null;
    stage = null;
    errorCode = null;
    outputs = <String>[];
    outputDir = null;
    listing = <String>[];
    listingMore = 0;
    updatedAt = now;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'ext': extensionId,
        'schema': schema,
        'values': <String, Object?>{
          for (final MapEntry(:key, :value) in values.entries)
            if (value is String)
              key: value
            else if (value is List)
              key: <Object?>[
                for (final item in value)
                  if (item is JobFile)
                    item.toJson()
                  else if (item is String)
                    item,
              ],
        },
        'state': state.name,
        if (outputs.isNotEmpty) 'outputs': outputs,
        if (outputDir != null) 'out_dir': outputDir,
        if (errorCode != null) 'error': errorCode,
        if (cleanup.isNotEmpty) 'cleanup': cleanup,
        if (listing.isNotEmpty) 'listing': listing,
        if (listingMore > 0) 'listing_more': listingMore,
        'updated_at': updatedAt.toIso8601String(),
      };

  /// Карточка из истории чата. Задача, которая шла, — «Прервано»: после
  /// перезапуска её уже нет. Повреждённая запись — `null`.
  static ExtensionCard? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final ext = json['ext'];
    final updated = DateTime.tryParse('${json['updated_at']}');
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
        ext is! String ||
        !RegExp(r'^[a-z0-9_-]{1,40}$').hasMatch(ext) ||
        updated == null) {
      return null;
    }
    final schema = json['schema'];
    final rawValues = json['values'];
    final values = <String, Object?>{};
    if (rawValues is Map) {
      for (final MapEntry(:key, :value) in rawValues.entries) {
        if (key is! String || !RegExp(r'^[a-z_]{1,32}$').hasMatch(key)) {
          continue;
        }
        if (value is String) {
          // Ссылка загрузчика бывает длинной; остальное — короткие коды.
          values[key] = ActionCard.cardText(
            value,
            max: key == 'url' ? YtdlUrl.maxLength : 300,
          );
        } else if (value is List) {
          values[key] = <JobFile>[
            for (final item in value)
              if (JobFile.fromJson(item) case final JobFile file) file,
          ];
        }
      }
    }
    final state = CardState.parse(json['state']) ?? CardState.form;
    final error = json['error'];
    final outDir = json['out_dir'];
    final more = json['listing_more'];
    return ExtensionCard(
      id: id,
      extensionId: ext,
      schema: schema is int ? schema : currentSchema,
      values: values,
      state: state == CardState.running ? CardState.interrupted : state,
      outputs: _paths(json['outputs']),
      outputDir: outDir is String ? cleanPath(outDir) : null,
      errorCode: error is String && RegExp(r'^[A-Za-z]{1,24}$').hasMatch(error)
          ? error
          : null,
      // Уборка удаляет эти пути: из файла чата берутся только временные
      // пути этой карточки (`.<имя>.<id>.part`, `.<имя>.tmp-<id>`,
      // `.tridot-<id>.tmp`), а не любой путь, вписанный в файл.
      cleanup: <String>[
        for (final path in _paths(json['cleanup']))
          if (JobPlacement.isTempFor(path, id)) path,
      ],
      listing: <String>[
        if (json['listing'] case final List<Object?> lines)
          for (final line in lines.take(listingLimit))
            if (line is String) ActionCard.cardText(line, max: 300),
      ],
      listingMore: more is int && more > 0 ? more : 0,
      updatedAt: updated,
    );
  }

  static List<String> _paths(Object? json) => <String>[
        if (json is List)
          for (final item in json)
            if (item is String)
              if (cleanPath(item) case final String path) path,
      ];

  /// Путь из файла чата: без управляющих и bidi-знаков, не пустой и не
  /// длиннее [pathLimit]. Иначе — `null` (путь пропускается).
  static String? cleanPath(String path) {
    if (path.isEmpty || path.length > pathLimit) return null;
    return _unsafe.hasMatch(path) ? null : path;
  }

  static final RegExp _unsafe = RegExp(
    '[\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e'
    '\\u2066-\\u2069]',
  );
}
