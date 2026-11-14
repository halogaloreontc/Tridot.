// Проекты-папки (ADR-018): проект, его сессии, перенос в проект и из
// него, «Новая сессия в проекте», удаление проекта обоими способами,
// хранение в chats/projects/projects.json и перенос старых данных без потерь.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_projects.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:path/path.dart' as p;

final class _Clock implements Clock {
  DateTime value = DateTime(2026, 11, 4, 12);

  @override
  DateTime now() => value;
}

ChatMessage _say(ChatBook book, String text, DateTime at, {bool user = true}) =>
    ChatMessage(
      id: book.newMessageId(),
      author: user ? ChatAuthor.user : ChatAuthor.persona,
      personaId: user ? null : 'sado',
      text: text,
      timestamp: at,
    );

void main() {
  late _Clock clock;
  late InMemoryChatStore store;

  setUp(() {
    clock = _Clock();
    store = InMemoryChatStore();
  });

  Future<ChatBook> book([ChatStore? on]) async {
    final b = ChatBook(store: on ?? store, clock: clock);
    await b.load();
    return b;
  }

  /// Сессия с одной командой: открыта новая пустая, в неё — [text].
  Future<String> session(ChatBook b, String text) async {
    await b.newSession();
    final id = b.currentId;
    b.append(id, _say(b, text, clock.value));
    clock.value = clock.value.add(const Duration(minutes: 1));
    return id;
  }

  group('ChatProject', () {
    test('JSON туда и обратно; битые записи и повторы пропускаются', () {
      final project = ChatProject(
        id: 'project:1_a',
        name: 'Ремонт',
        description: 'Кухня',
        taskTag: 'дом',
        createdAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 2),
        pinnedAt: DateTime.utc(2026, 11, 3),
      );
      final text = ChatProjectCodec.encode(<ChatProject>[project]);
      final back = ChatProjectCodec.decode(text)!.single;
      expect(back.id, project.id);
      expect(back.name, 'Ремонт');
      expect(back.description, 'Кухня');
      expect(back.taskTag, 'дом');
      expect(back.pinned, isTrue);
      expect(back.updatedAt, project.updatedAt);

      final mixed = jsonEncode(<String, Object?>{
        'schema_version': 1,
        'projects': <Object?>[
          project.toJson(),
          project.toJson(),
          <String, Object?>{'id': 'чужое', 'name': 'x', 'created_at': '1'},
          <String, Object?>{
            'id': 'project:2',
            'name': '   ',
            'created_at': '2026-11-01T00:00:00Z',
          },
          <String, Object?>{
            'id': 'project:3',
            'name': 'Отпуск',
            'created_at': '2026-11-01T00:00:00Z',
            'description': 5,
            'task_tag': 'два слова',
          },
          42,
        ],
      });
      final list = ChatProjectCodec.decode(mixed)!;
      expect(list.map((ChatProject p) => p.id), <String>[
        'project:1_a',
        'project:3',
      ]);
      expect(list.last.description, isNull);
      expect(list.last.taskTag, isNull);
      expect(list.last.updatedAt, list.last.createdAt);
      expect(ChatProjectCodec.decode('не json'), isNull);
      expect(
        ChatProjectCodec.decode('{"schema_version":99,"projects":[]}'),
        isNull,
      );
    });

    test('метка: без «#», в нижнем регистре, одно слово', () {
      expect(ChatProject.normalizeTag('#Работа'), 'работа');
      expect(ChatProject.normalizeTag('  дом '), 'дом');
      expect(ChatProject.normalizeTag('два слова'), isNull);
      expect(ChatProject.normalizeTag('#'), isNull);
    });
  });

  group('ChatBook: проекты', () {
    test('создать, переименовать, описание, метка, закрепить', () async {
      final b = await book();
      expect(b.createProject('   '), isNull);
      final project = b.createProject(
        '  Ремонт   кухни ',
        description: '  Плитка  ',
        taskTag: '#Дом',
      )!;
      expect(project.id, startsWith(ChatProject.prefix));
      expect(project.name, 'Ремонт кухни');
      expect(project.description, 'Плитка');
      expect(project.taskTag, 'дом');
      expect(b.projectForTag('#ДОМ')?.id, project.id);

      expect(b.renameProject(project.id, ''), isFalse);
      expect(b.renameProject(project.id, 'Кухня'), isTrue);
      expect(b.setProjectDescription(project.id, ''), isTrue);
      expect(b.project(project.id)!.description, isNull);
      expect(b.linkProjectTag(project.id, 'два слова'), isFalse);
      expect(b.project(project.id)!.taskTag, 'дом');
      expect(b.linkProjectTag(project.id, null), isTrue);
      expect(b.project(project.id)!.taskTag, isNull);

      clock.value = clock.value.add(const Duration(minutes: 5));
      final later = b.createProject('Отпуск')!;
      expect(b.projects().map((ChatProject p) => p.id), <String>[
        later.id,
        project.id,
      ]);
      b.setProjectPinned(project.id, true);
      expect(b.projects().first.id, project.id);

      // После перезапуска — то же.
      final again = await book();
      expect(again.project(project.id)!.name, 'Кухня');
      expect(again.project(project.id)!.pinned, isTrue);
      expect(again.projects().map((ChatProject p) => p.id), <String>[
        project.id,
        later.id,
      ]);
    });

    test('перенос сессии в проект и из него; sessionsOf, счётчик', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'купить плитку');
      final c = await session(b, 'позвонить мастеру');
      expect(b.moveToProject(a, 'project:нет'), isFalse);
      expect(b.moveToProject(a, project.id), isTrue);
      expect(b.projectOf(a)?.id, project.id);
      expect(b.projectSessionCount(project.id), 1);
      expect(b.moveToProject(c, project.id), isTrue);
      b.setPinned(a, true);
      expect(b.sessionsOf(project.id).map((ChatThread t) => t.id), <String>[
        a,
        c,
      ]);

      // Перезапуск: сессии в проекте; сохранено сразу, без новых сообщений.
      final again = await book();
      expect(again.thread(a)!.projectId, project.id);
      expect(again.projectSessionCount(project.id), 2);

      expect(again.moveToProject(a, null), isTrue);
      final third = await book();
      expect(third.thread(a)!.projectId, isNull);
      expect(third.projectSessionCount(project.id), 1);
    });

    test('«Новая сессия в проекте» и «+» — в обе стороны', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      // Пустая общая → новая в проекте: та же пустая, но уже в проекте.
      final empty = b.currentId;
      final inProject = await b.newSession(projectId: project.id);
      expect(inProject.id, empty);
      expect(inProject.projectId, project.id);
      expect(
        b.sessionsOf(project.id).map((ChatThread t) => t.id),
        contains(empty),
      );
      expect(b.projectSessionCount(project.id), 0, reason: 'пустая не в счёте');

      // Пустая проектная → «+» → сессия вне проекта.
      final plain = await b.newSession();
      expect(plain.id, empty);
      expect(plain.projectId, isNull);

      // Новая в проекте после сессии с сообщениями: команда — в проекте.
      await b.newSession(projectId: project.id);
      final id = b.currentId;
      b.append(id, _say(b, 'план работ', clock.value));
      expect(b.projectSessionCount(project.id), 1);
      await b.flush();
      final again = await book();
      expect(again.thread(id)!.projectId, project.id);

      // Чужой id проекта — сессия вне проектов.
      final unknown = await again.newSession(projectId: 'project:нет');
      expect(unknown.projectId, isNull);
    });

    test(
        'оставленная пустая проектная сессия при повторном открытии — '
        'вне проекта', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'вне проекта');
      await b.newSession(projectId: project.id);
      final empty = b.currentId;
      expect(b.current.projectId, project.id);
      // Ушли в другую сессию и удалили её: открыта оставленная пустая —
      // уже без проекта (новую в проекте открывают с экрана проекта).
      await b.open(a);
      expect(await b.remove(a), isTrue);
      expect(b.currentId, empty);
      expect(b.current.projectId, isNull);
    });

    test('задача из сессии проекта — её чат в том же проекте', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      await b.newSession(projectId: project.id);
      final id = b.currentId;
      final command = _say(b, 'добавь задачу плитка', clock.value);
      final reply = _say(b, 'Добавил', clock.value, user: false);
      b
        ..append(id, command)
        ..append(id, reply);
      final chat = b.onTaskCreated(
        't1',
        fromChatId: id,
        command: command,
        reply: reply,
      );
      expect(chat.projectId, project.id);
      // Только копия команды — в сессиях проекта чата задачи нет.
      expect(
        b.sessionsOf(project.id).map((ChatThread t) => t.id),
        isNot(contains(chat.id)),
      );
    });

    test('удалить проект: вынести сессии', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      final wasCurrent =
          await b.deleteProject(project.id, deleteSessions: false);
      expect(wasCurrent, isFalse);
      expect(b.project(project.id), isNull);
      expect(b.thread(a), isNotNull);
      expect(b.thread(a)!.projectId, isNull);
      final again = await book();
      expect(again.projects(), isEmpty);
      expect(again.thread(a)!.projectId, isNull);
    });

    test('удалить проект вместе с сессиями; открытая — пустая сессия',
        () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final keep = await session(b, 'вне проекта');
      final a = await session(b, 'плитка');
      final c = await session(b, 'мастер');
      b
        ..moveToProject(a, project.id)
        ..moveToProject(c, project.id);
      expect(b.currentId, c);
      final wasCurrent =
          await b.deleteProject(project.id, deleteSessions: true);
      expect(wasCurrent, isTrue);
      expect(b.thread(a), isNull);
      expect(b.thread(c), isNull);
      expect(b.current.messageCount, 0);
      expect(b.current.projectId, isNull);
      expect(b.thread(keep), isNotNull);
      await b.flush();
      expect(store.chatIds, <String>[keep]);
      final again = await book();
      expect(again.projects(), isEmpty);
    });

    test('поиск: подпись проекта и фильтр по проекту', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'купить плитку');
      final c = await session(b, 'плитка для дачи');
      b.moveToProject(a, project.id);
      final all = await b.search('плитк');
      expect(all.map((h) => h.chatId).toSet(), <String>{a, c});
      expect(all.firstWhere((h) => h.chatId == a).projectName, 'Ремонт');
      expect(all.firstWhere((h) => h.chatId == c).projectName, isNull);
      final only = await b.search('плитк', projectId: project.id);
      expect(only.map((h) => h.chatId), <String>[a]);
    });

    test('ссылка на проект, которого нет, — сессия вне проектов', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      await b.flush();
      // projects.json потерян (другая версия, ручная правка).
      store.projectsFile = null;
      final again = await book();
      expect(again.thread(a)!.projectId, isNull);
      expect(again.projects(), isEmpty);
    });

    test('«Очистить историю»: папки остаются пустыми', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      await b.clearAll();
      expect(b.project(project.id), isNotNull);
      expect(b.projectSessionCount(project.id), 0);
      final again = await book();
      expect(again.project(project.id)?.name, 'Ремонт');
      expect(
        again.threads.where((ChatThread t) => t.messageCount > 0),
        isEmpty,
      );
    });
  });

  group('файл проектов не прочитался (ошибка файловой системы)', () {
    test('папки не затираются, ссылки сессий целы', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      await b.flush();
      final saved = store.projectsFile;

      // Файл заблокирован при запуске и при каждой попытке записи.
      final locked = _FlakyProjects(store, failures: 1000);
      final again = await book(locked);
      expect(again.projectsUnreadable, isTrue);
      expect(again.projects(), isEmpty);
      // Ссылка на папку не сброшена: при следующем запуске она найдётся.
      expect(again.thread(a)!.projectId, project.id);
      again.createProject('Дача');
      await again.flush();
      await Future<void>.delayed(Duration.zero);
      expect(store.projectsFile, saved, reason: 'файл не перезаписан');

      final third = await book();
      expect(third.project(project.id)?.name, 'Ремонт');
      expect(third.thread(a)!.projectId, project.id);
    });

    test('при записи файл прочитался — папки сливаются', () async {
      final b = await book();
      final project = b.createProject('Ремонт')!;
      await b.flush();

      final flaky = _FlakyProjects(store, failures: 1);
      final again = await book(flaky);
      expect(again.projects(), isEmpty);
      again.createProject('Дача');
      await again.flush();
      await Future<void>.delayed(Duration.zero);
      expect(again.projectsUnreadable, isFalse);

      final third = await book();
      expect(
        third.projects().map((ChatProject x) => x.name),
        containsAll(<String>['Ремонт', 'Дача']),
      );
      expect(third.project(project.id), isNotNull);
    });
  });

  group('JsonChatStore: projects.json', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('chat_projects_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    String projectsFile() => p.join(dir.path, 'projects', 'projects.json');

    JsonChatStore json() => JsonChatStore(
          dir.path,
          debounce: Duration.zero,
          clock: clock,
        );

    test('перезапуск: проекты и project_id на месте', () async {
      final b = await book(json());
      final project = b.createProject('Ремонт', taskTag: 'дом')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      await b.flush();
      expect(File(projectsFile()).existsSync(), isTrue);
      // Не в самой папке чатов: старая версия приняла бы его за чат.
      expect(File(p.join(dir.path, 'projects.json')).existsSync(), isFalse);

      final again = await book(json());
      expect(again.project(project.id)!.taskTag, 'дом');
      expect(again.thread(a)!.projectId, project.id);
    });

    test('без папок projects.json не создаётся; старые данные читаются',
        () async {
      final b = await book(json());
      await session(b, 'плитка');
      await b.flush();
      expect(File(projectsFile()).existsSync(), isFalse);
      final again = await book(json());
      expect(again.projects(), isEmpty);
      expect(
        again.threads.where((ChatThread t) => t.messageCount > 0),
        hasLength(1),
      );
    });

    test('битый projects.json — в сторону, чаты читаются', () async {
      final b = await book(json());
      final a = await session(b, 'плитка');
      await b.flush();
      await File(projectsFile()).create(recursive: true);
      await File(projectsFile()).writeAsString('{битый');
      final again = await book(json());
      expect(again.projects(), isEmpty);
      expect(again.thread(a), isNotNull);
      expect(File('${projectsFile()}.broken').existsSync(), isTrue);
    });

    test('index.json потерян: пересборка не трогает projects.json', () async {
      final b = await book(json());
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      await b.flush();
      await File(p.join(dir.path, 'index.json')).delete();
      final again = await book(json());
      expect(again.project(project.id), isNotNull);
      expect(again.thread(a)!.projectId, project.id);
      expect(
        File(p.join(dir.path, 'projects.json.broken')).existsSync(),
        isFalse,
      );
    });

    test(
        'откат на старую версию: её пересборка index.json не видит папки, '
        'а отложенный ею projects.json.broken возвращается', () async {
      final b = await book(json());
      final project = b.createProject('Ремонт')!;
      final a = await session(b, 'плитка');
      b.moveToProject(a, project.id);
      await b.flush();
      // Сборка, писавшая projects.json в папку чатов, после отката: старая
      // версия отложила его в .broken. Нового файла ещё нет.
      final content = await File(projectsFile()).readAsString();
      await File(projectsFile()).delete();
      await File(p.join(dir.path, 'projects.json.broken'))
          .writeAsString(content);
      final again = await book(json());
      expect(again.project(project.id)?.name, 'Ремонт');
      expect(again.thread(a)!.projectId, project.id);
      // Следующая запись — уже в подпапку.
      again.createProject('Дача');
      await again.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final third = await book(json());
      expect(
        third.projects().map((ChatProject x) => x.name),
        containsAll(<String>['Ремонт', 'Дача']),
      );
    });

    test('projects.json прежнего места читается, пока нового нет', () async {
      final b = await book(json());
      final project = b.createProject('Ремонт')!;
      await b.flush();
      final content = await File(projectsFile()).readAsString();
      await Directory(p.dirname(projectsFile())).delete(recursive: true);
      await File(p.join(dir.path, 'projects.json')).writeAsString(content);
      final again = await book(json());
      expect(again.project(project.id)?.name, 'Ремонт');
    });

    test('clearAll оставляет projects.json', () async {
      final b = await book(json());
      final project = b.createProject('Ремонт')!;
      await session(b, 'плитка');
      await b.flush();
      await b.clearAll();
      await b.flush();
      final again = await book(json());
      expect(again.project(project.id), isNotNull);
      expect(
        again.threads.where((ChatThread t) => t.messageCount > 0),
        isEmpty,
      );
    });
  });
}

/// Хранилище, у которого чтение файла проектов первые [failures] раз
/// падает, как у заблокированного файла.
final class _FlakyProjects implements ChatStore {
  _FlakyProjects(this._inner, {required int failures}) : _left = failures;

  final InMemoryChatStore _inner;
  int _left;

  @override
  Future<List<ChatThread>> loadIndex() => _inner.loadIndex();

  @override
  Future<List<ChatMessage>> loadMessages(String chatId) =>
      _inner.loadMessages(chatId);

  @override
  Future<void> save(ChatThread thread) => _inner.save(thread);

  @override
  Future<void> delete(String chatId) => _inner.delete(chatId);

  @override
  Future<void> erase(String chatId) => _inner.erase(chatId);

  @override
  Future<void> clearAll() => _inner.clearAll();

  @override
  Future<List<ChatProject>> loadProjects() {
    if (_left > 0) {
      _left--;
      throw const FileSystemException('файл занят');
    }
    return _inner.loadProjects();
  }

  @override
  Future<void> saveProjects(List<ChatProject> projects) =>
      _inner.saveProjects(projects);

  @override
  AttachmentStore get attachments => _inner.attachments;

  @override
  Future<void> flush() => _inner.flush();
}
