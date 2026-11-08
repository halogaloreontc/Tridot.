import '../connectors/verb_forms.dart';
import '../models/task.dart';
import '../storage/task_repository.dart';
import 'clock.dart';

/// Задача, найденная нечётким поиском, и доля совпавших слов запроса.
final class TaskSearchHit {
  const TaskSearchHit(this.task, this.score);

  final Task task;
  final double score;
}

final class TaskService {
  TaskService({required TaskRepository repository, required Clock clock})
      : _repository = repository,
        _clock = clock;

  final TaskRepository _repository;
  final Clock _clock;
  int _sequence = 0;

  Future<Task> create({
    required String title,
    DateTime? dueAt,
    DuePrecision duePrecision = DuePrecision.dateTime,
    TaskPriority priority = TaskPriority.normal,
    List<String> tags = const <String>[],
  }) async {
    final normalizedTitle = _validTitle(title);
    final now = _clock.now();
    final task = Task(
      id: 'task_${now.microsecondsSinceEpoch}_${_sequence++}',
      title: normalizedTitle,
      status: dueAt == null ? TaskStatus.inbox : TaskStatus.planned,
      priority: priority,
      dueAt: dueAt,
      duePrecision: duePrecision,
      tags: _normalizeTags(tags),
      createdAt: now,
      updatedAt: now,
    );
    await _repository.save(task);
    return task;
  }

  Future<List<Task>> listActive() async {
    final tasks = (await _repository.list())
        .where((Task task) => task.isActive)
        .toList(growable: false);
    tasks.sort((Task a, Task b) {
      final aDue = a.dueAt;
      final bDue = b.dueAt;
      if (aDue == null && bDue != null) return 1;
      if (aDue != null && bDue == null) return -1;
      if (aDue != null && bDue != null) {
        final byDate = aDue.compareTo(bDue);
        if (byDate != 0) return byDate;
      }
      final byPriority = b.priority.index.compareTo(a.priority.index);
      if (byPriority != 0) return byPriority;
      final byCreated = a.createdAt.compareTo(b.createdAt);
      if (byCreated != 0) return byCreated;
      return a.id.compareTo(b.id);
    });
    return tasks;
  }

  /// Активные задачи с таким названием без учёта регистра и «ё».
  Future<List<Task>> findActiveByTitle(String title) async {
    final wanted = _titleKey(title);
    return (await listActive())
        .where((Task task) => _titleKey(task.title) == wanted)
        .toList(growable: false);
  }

  /// Нечёткий поиск активных задач по словам запроса, лучшие сверху.
  ///
  /// Слова сравниваются по основе: первые `min(5, длина)` букв, причём для
  /// пары слов берётся меньшая длина — «хлеб» совпадает с «хлеба», «отчёт»
  /// с «отчёта». Короткие слова совпадают и с другим падежным окончанием
  /// (одна-две гласные после общей основы от трёх букв): «мама» с «маму»,
  /// «плана» с «плане» — так задача «Маму поздравить» находится по запросу
  /// «Мама», а старая «Встречу» — по новому «Встреча». Слова короче трёх букв и числа совпадают только целиком:
  /// «ип» не совпадает с «ипотеку», «2» — с «2027». Служебные слова («в»,
  /// «на», «задачу») не учитываются. Оценка — доля совпавших слов запроса.
  /// В результат попадают задачи с оценкой не ниже 0.5 и хотя бы одним
  /// совпавшим словом от трёх букв.
  ///
  /// С [verbForms] запрос — сообщение о сделанном («купил хлеб», «отчёт
  /// сдал»): глаголы сравниваются по основе без окончаний «-л», «-ла»,
  /// «-ли», «-ло», «-ть», «-ти» — первые `min(4, длина)` букв, так что
  /// «купил» совпадает с «купить», а «сдал» — со «сдать». Если в запросе
  /// есть не только глаголы, должно совпасть хотя бы одно из остальных
  /// слов: «купил хлеб» не находит «Купить молоко». Если глаголы есть и
  /// в запросе, и в названии, должен совпасть и глагол: «купил хлеб» не
  /// находит «Испечь хлеб». Глаголом считается только то, что
  /// [VerbForms.stem] признаёт глаголом: «кровать», «новость», «часть» —
  /// предметы.
  Future<List<TaskSearchHit>> searchActive(
    String query, {
    bool verbForms = false,
  }) async {
    final wanted = _searchWords(query);
    if (wanted.isEmpty) return const <TaskSearchHit>[];
    final objects = verbForms
        ? wanted.where((String w) => VerbForms.stem(w) == null).toSet()
        : null;
    final queryHasVerb = verbForms && objects!.length < wanted.length;
    final hits = <TaskSearchHit>[];
    for (final task in await listActive()) {
      final words = _searchWords(task.title);
      var matched = 0;
      var hasLong = false;
      var objectMatched = false;
      var verbMatched = false;
      for (final word in wanted) {
        final match = words.where(
          (String other) =>
              _sameStem(word, other) ||
              (verbForms && _sameVerbStem(word, other)),
        );
        if (match.isNotEmpty) {
          matched++;
          if (match.any((String other) => other.length >= 3) &&
              word.length >= 3) {
            hasLong = true;
          }
          if (objects != null) {
            if (objects.contains(word)) {
              objectMatched = true;
            } else {
              verbMatched = true;
            }
          }
        }
      }
      if (objects != null && objects.isNotEmpty && !objectMatched) continue;
      if (queryHasVerb &&
          !verbMatched &&
          words.any((String w) => VerbForms.stem(w) != null)) {
        continue;
      }
      final score = matched / wanted.length;
      if (score >= 0.5 && hasLong) hits.add(TaskSearchHit(task, score));
    }
    // Сортировка устойчива: при равной оценке сохраняется порядок listActive.
    final indexed = hits.indexed.toList()
      ..sort(((int, TaskSearchHit) a, (int, TaskSearchHit) b) {
        final byScore = b.$2.score.compareTo(a.$2.score);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return indexed
        .map(((int, TaskSearchHit) e) => e.$2)
        .toList(growable: false);
  }

  static const Set<String> _searchStopWords = <String>{
    'в',
    'во',
    'на',
    'к',
    'ко',
    'и',
    'а',
    'с',
    'со',
    'по',
    'до',
    'о',
    'об',
    'от',
    'у',
    'за',
    'из',
    'для',
    'про',
    'задачу',
    'задача',
    'задачи',
  };

  static final RegExp _searchWord = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  static List<String> _searchWords(String text) => _searchWord
      .allMatches(text.toLowerCase().replaceAll('ё', 'е'))
      .map((Match m) => m.group(0)!)
      .where((String w) => !_searchStopWords.contains(w))
      .toList(growable: false);

  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  static bool _sameStem(String a, String b) {
    if (a.length < 3 ||
        b.length < 3 ||
        _digitsOnly.hasMatch(a) ||
        _digitsOnly.hasMatch(b)) {
      return a == b;
    }
    var length = a.length < b.length ? a.length : b.length;
    if (length > 5) length = 5;
    if (a.substring(0, length) == b.substring(0, length)) return true;
    return _sameInflected(a, b);
  }

  /// Падежные окончания, которыми могут различаться короткие слова.
  static const Set<String> _caseEndings = <String>{
    'а',
    'я',
    'у',
    'ю',
    'е',
    'и',
    'ы',
    'о',
    'ой',
    'ей',
    'ом',
    'ем',
  };

  /// «маму» и «мама», «плана» и «плане»: общая основа — всё, кроме
  /// окончания, и оба окончания — падежные.
  static bool _sameInflected(String a, String b) {
    for (final stemLength in <int>[a.length - 1, a.length - 2]) {
      if (stemLength < 3 || stemLength > b.length) continue;
      if (a.substring(0, stemLength) != b.substring(0, stemLength)) continue;
      final left = a.substring(stemLength);
      final right = b.substring(stemLength);
      if (_caseEndings.contains(left) &&
          (right.isEmpty || _caseEndings.contains(right))) {
        return true;
      }
    }
    return false;
  }

  static bool _sameVerbStem(String a, String b) {
    final left = VerbForms.stem(a);
    final right = VerbForms.stem(b);
    if (left == null || right == null) return false;
    var length = left.length < right.length ? left.length : right.length;
    if (length > 4) length = 4;
    return left.substring(0, length) == right.substring(0, length);
  }

  static String _titleKey(String title) => title
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'\s+'), ' ');

  Future<Task> complete(String id) async {
    final task = await _requireTask(id);
    if (task.status == TaskStatus.done) return task;
    final now = _clock.now();
    final updated = task.copyWith(
      status: TaskStatus.done,
      completedAt: now,
      updatedAt: now,
    );
    await _repository.save(updated);
    return updated;
  }

  Future<Task> reschedule(
    String id,
    DateTime dueAt,
    DuePrecision precision,
  ) async {
    final task = await _requireTask(id);
    final updated = task.copyWith(
      dueAt: dueAt,
      duePrecision: precision,
      status: TaskStatus.planned,
      clearCompletedAt: true,
      updatedAt: _clock.now(),
    );
    await _repository.save(updated);
    return updated;
  }

  /// Возвращает задаче прежнее состояние [snapshot] (срок, точность,
  /// статус, отметку о завершении) — отмена массового изменения. Только
  /// если с тех пор задачу не меняли: её [Task.updatedAt] всё ещё
  /// [ifUpdatedAt]. Иначе (правили, удалили) — `null`, задача не трогается.
  Future<Task?> restore(Task snapshot, {required DateTime ifUpdatedAt}) async {
    final current = await _repository.get(snapshot.id);
    if (current == null ||
        current.deletedAt != null ||
        current.updatedAt != ifUpdatedAt) {
      return null;
    }
    final restored = Task(
      id: current.id,
      title: current.title,
      description: current.description,
      status: snapshot.status,
      priority: current.priority,
      dueAt: snapshot.dueAt,
      duePrecision: snapshot.duePrecision,
      tags: current.tags,
      createdAt: current.createdAt,
      updatedAt: _clock.now(),
      completedAt: snapshot.completedAt,
    );
    await _repository.save(restored);
    return restored;
  }

  /// Все задачи, кроме удалённых: и активные, и завершённые.
  Future<List<Task>> listAll() async => (await _repository.list())
      .where((Task task) => task.deletedAt == null)
      .toList(growable: false);

  /// Завершённые задачи, свежие сверху.
  Future<List<Task>> listCompleted() async {
    final done = (await listAll())
        .where((Task task) => task.status == TaskStatus.done)
        .toList();
    done.sort(
      (Task a, Task b) => (b.completedAt ?? b.updatedAt)
          .compareTo(a.completedAt ?? a.updatedAt),
    );
    return done;
  }

  /// Правка из документа задачи. Пустой [project] убирает проект.
  Future<Task> updateDetails(
    String id, {
    String? title,
    String? description,
    String? project,
  }) async {
    final task = await _requireTask(id);
    var tags = task.tags;
    if (project != null) {
      final normalized = _normalizeTags(<String>[project]);
      tags = <String>[...normalized, ...task.tags.skip(1)];
      if (normalized.isEmpty) tags = task.tags.skip(1).toList();
    }
    final updated = task.copyWith(
      title: title == null ? null : _validTitle(title),
      description: description,
      tags: tags,
      updatedAt: _clock.now(),
    );
    await _repository.save(updated);
    return updated;
  }

  /// Возвращает завершённую задачу в работу.
  Future<Task> reopen(String id) async {
    final task = await _requireTask(id);
    if (task.status != TaskStatus.done) return task;
    final updated = task.copyWith(
      status: task.dueAt == null ? TaskStatus.inbox : TaskStatus.planned,
      clearCompletedAt: true,
      updatedAt: _clock.now(),
    );
    await _repository.save(updated);
    return updated;
  }

  String _validTitle(String title) {
    final normalized = title.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Название задачи не может быть пустым',
      );
    }
    if (normalized.length > 500) {
      throw ArgumentError.value(
        title,
        'title',
        'Название задачи длиннее 500 символов',
      );
    }
    return normalized;
  }

  /// Метки без «#», в нижнем регистре, без пустых и повторов.
  static List<String> _normalizeTags(List<String> tags) {
    final result = <String>[];
    for (final raw in tags) {
      final tag = raw.trim().replaceFirst(RegExp('^#+'), '').toLowerCase();
      if (tag.isNotEmpty && !result.contains(tag)) result.add(tag);
    }
    return result;
  }

  Future<Task> _requireTask(String id) async {
    final task = await _repository.get(id);
    if (task == null || task.deletedAt != null) {
      throw StateError('Задача не найдена');
    }
    return task;
  }
}
