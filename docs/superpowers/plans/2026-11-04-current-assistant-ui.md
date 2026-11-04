# Current Assistant UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перенести согласованный монохромный макет диалога и документа во Flutter без изменения сценариев и хранилища.

**Architecture:** `HomePage` продолжает владеть состоянием. Визуальные компоненты выделяются в `lib/app/widgets`; `TaskService`, `TaskRepository` и `AssistantController` сохраняют public interfaces. Документ остаётся демонстрационным редактором без выдуманного backend.

**Tech Stack:** Dart, Flutter Material, `flutter_test`; новых зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-11-03-chat-ui-design.md` и финальный макет `.superpowers/brainstorm/31861-1793798980/content/assistant-message-timestamps.html`.

## Global Constraints

- Монохромная тёмная тема, Inter для текста, monospace для метаданных.
- Общий composer; одинаковая высота областей; история справа; куб в отдельном левом слое.
- Не добавлять LLM, сервер, телеметрию, облачную синхронизацию или state management.
- Не имитировать сохранение форматированного документа или реальные голосовые функции.
- Обычный push запускает только существующий verify workflow.

## Review Focus

- Пустой список задач: навигация и composer остаются доступны; widget test в Task 1.
- Переключение режимов во время ввода: текст не теряется; widget test в Task 1.
- Длинная история: последний ответ и composer доступны без увеличения страницы; widget test в Task 1.
- Отсутствие реальных документов: редактирование честно обозначено как демонстрационное; widget test в Task 1.

---

### Task 1: Текущий интерфейс и поведение

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/app/home_page.dart`
- Create: `lib/app/assistant_theme.dart`
- Create: `lib/app/widgets/command_composer.dart`
- Create: `lib/app/widgets/status_cube.dart`
- Create: `lib/app/widgets/history_rail.dart`
- Create: `lib/app/widgets/document_view.dart`
- Test: `test/home_page_test.dart`

**Interfaces:**
- `AssistantTheme.dark() → ThemeData`.
- `CommandComposer` принимает существующий controller, режим и callbacks.
- `StatusCube` принимает состояние и учитывает `MediaQuery.disableAnimations`.
- `HistoryRail` отображает версии и preview без записи пользовательских данных.

- [ ] **Step 1:** Написать widget tests: отображаются sidebar, общий composer, куб и история; текст сохраняется между Диалогом и Документом; выбор полосы показывает сообщения версии; документ обозначает демонстрационное сохранение; существующая команда `Покажи задачи` проходит через контроллер.
- [ ] **Step 2:** Запустить `flutter test test/home_page_test.dart` и подтвердить RED на отсутствующих keys.
- [ ] **Step 3:** Реализовать layout и компоненты по финальному макету, подключить существующие создание, список, выбор, перенос и завершение без изменения backend.
- [ ] **Step 4:** Запустить targeted test, `dart format`, `flutter analyze`, `flutter test`; подтвердить GREEN.

### Task 2: Проверка и публикация

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-11-03-chat-ui-design.md`

- [ ] **Step 1:** Запустить macOS, проверить основной сценарий, оба режима, preview истории, переполнение и перезапуск JSON.
- [ ] **Step 2:** Обновить README фактическими результатами и ограничениями демонстрационных функций.
- [ ] **Step 3:** Повторить format/analyze/test, проверить `git diff` и отсутствие временных файлов.
- [ ] **Step 4:** Создать commit и отправить `main` в `origin`; проверить, что Actions запускает только verify.
