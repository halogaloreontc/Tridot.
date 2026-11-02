# Android-only Release CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Сохранить проверки каждого изменения и запускать Android Release только для версионных тегов и ручных запусков, отключив остальные release-jobs.

**Architecture:** Один workflow продолжает запускать `verify` на каждый `push` и pull request. Job `android` зависит от `verify` и дополнительно фильтруется событием: тег `v*` или `workflow_dispatch`. Platform runners остаются в проекте; меняются только CI и документация.

**Tech Stack:** GitHub Actions YAML, Flutter stable, Ruby/Psych для локального разбора YAML, GitHub CLI для проверки удалённого run.

**Spec:** `docs/superpowers/specs/2026-11-02-android-ci-design.md`

## Global Constraints

- Не менять код приложения, зависимости или public interfaces.
- Не удалять Android/Windows/Linux/macOS runners.
- Не создавать тег и не запускать release job только для проверки.
- Сохранить `needs: verify` и artifact `assistant-android-apk`.
- Не заявлять tag/manual условия фактически выполненными без реального события.

## Review Focus

- Обычный `push` ветки: только `verify`; проверяется удалённым run после интеграции.
- Pull request: только `verify`; проверяется статическим условием job, отдельный PR не создаётся ради теста.
- Тег `refs/tags/v...`: `verify` и `android`; проверяется точным `if`, тег не создаётся ради теста.
- `workflow_dispatch`: `verify` и `android`; проверяется точным `if`, ручной run не запускается ради теста.
- Тег не с префиксом `v`: только `verify`; проверяется тем же условием `startsWith`.

---

### Task 1: Ограничить release CI и задокументировать правила

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`
- Create: `docs/superpowers/specs/2026-11-02-android-ci-design.md`
- Create: `docs/superpowers/plans/2026-11-02-android-ci.md`

**Interfaces:**
- Consumes: существующие `verify` и `android` jobs, `origin/main`.
- Produces: `verify` на всех прежних событиях; `android` только при `startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch'`.

- [ ] **Step 1: Изменить только триггеры и состав release-jobs**

Оставить `push`, `pull_request`, добавить `workflow_dispatch`. Добавить к `android` job-level условие `startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch'`, сохранив `needs: verify` и все его шаги. Удалить jobs `windows`, `linux`, `macos`; другие файлы runners не трогать.

- [ ] **Step 2: Обновить README**

Описать дешёвые проверки на каждом `push`/PR и Android APK по тегам `v*` либо через Actions → Run workflow. Зафиксировать успешный первый полный CI run как исторический результат, но указать новую активную схему без Windows/Linux/macOS jobs.

- [ ] **Step 3: Проверить конфигурацию и проект**

Run:

```bash
/opt/homebrew/opt/ruby/bin/ruby -e "require 'yaml'; YAML.load_file('.github/workflows/ci.yml', aliases: true); puts 'Workflow YAML: OK'"
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

Expected: YAML разобран; format — 0 изменений; analyze — No issues; tests — 12/12. Diff подтверждает отсутствие трёх release-jobs и наличие точного Android `if`.

- [ ] **Step 4: Зафиксировать и отправить изменение**

```bash
git add .github/workflows/ci.yml README.md docs/superpowers
git commit -m "Limit release CI to Android milestones"
git push origin main
```

Expected: новый commit создан и отправлен без force; `main` и `origin/main` совпадают.

- [ ] **Step 5: Проверить фактический GitHub Actions run**

Найти run нового commit через `gh run list` и дождаться через `gh run watch --exit-status`.

Expected: conclusion `success`; присутствует только job `verify`; `android`, `windows`, `linux`, `macos` не запущены и минуты release-сборок не потрачены. Tag/manual поведение остаётся статически проверенным, но фактически не запускалось.
