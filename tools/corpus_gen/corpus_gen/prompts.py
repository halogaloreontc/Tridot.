"""Промпты и JSON-схемы генерации и разметки.

Разметчик описывает, как фразу ДОЛЖЕН понять помощник, а не как её понимает
текущий парсер. Расхождение с парсером — это и есть найденный пробел.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

INTENTS = ["createTask", "listTasks", "completeTask", "rescheduleTask", "unknown"]
ISSUES = ["none", "inPast", "invalidDate", "invalidTime", "conflictingDays", "conflictingTimes"]
TITLE_ISSUES = ["none", "unbalancedQuotes", "multipleTitles"]
PRECISIONS = ["date", "dateTime"]

WEEKDAYS = ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"]

TOPICS: dict[str, str] = {
    "create": "создание задачи с названием в кавычках и разными сроками: сегодня, завтра, "
    "послезавтра, ДД.ММ, ДД.ММ.ГГГГ, время ЧЧ:ММ и «в ЧЧ.ММ», без срока",
    "reschedule": "перенос задачи: «её», выбранной или названной в кавычках; на день, дату, "
    "время; формы «перенеси», «перенести», «сдвинь», «отложи», «с … на …»",
    "complete": "завершение задачи: повелительные и прошедшие формы, «готово», «сделано», "
    "а также похожие фразы, которые НЕ являются командой: вопросы и отрицания",
    "list": "просьбы показать список задач или планы, и похожие фразы не про задачи",
    "unknown": "фразы, не относящиеся к задачам: приветствия, вопросы о погоде, болтовня",
    "tricky": "трудные случаи: слова-команды и даты внутри названия в кавычках, вложенные и "
    "незакрытые кавычки, несколько названий, противоречивые сроки, несуществующие даты и "
    "время, номера версий и телефонов, опечатки, лишние пробелы, ЗАГЛАВНЫЕ буквы",
    "gaps": "естественные формулировки сроков, которые помощник может ещё не понимать: дни "
    "недели, «через час», «в 9 утра», «вечером», месяц словом («15 ноября»), «на следующей "
    "неделе»",
}

GENERATION_SYSTEM = """Ты помогаешь тестировать офлайн-помощника для управления задачами на русском языке.
Помощник работает на правилах, без языковой модели. Ты придумываешь реалистичные фразы, которые
живой пользователь мог бы написать в чат помощника. Фразы должны быть разнообразными по лексике,
порядку слов и стилю. Не повторяй примеры дословно. Не используй реальные персональные данные."""

GENERATION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"phrases": {"type": "array", "items": {"type": "string"}}},
    "required": ["phrases"],
    "additionalProperties": False,
}


def generation_prompt(topic: str, count: int, examples: list[str]) -> str:
    description = TOPICS[topic]
    sample = "\n".join(f"- {e}" for e in examples[:8]) or "- (примеров нет)"
    return (
        f"Придумай {count} разных фраз пользователя. Тема: {description}.\n\n"
        "Правило помощника: название новой задачи пишется в кавычках («…», “…”, „…“ или \"…\").\n"
        "Часть фраз может нарушать правила — это тоже полезно для тестов.\n\n"
        f"Фразы, которые уже есть (не повторяй их):\n{sample}\n\n"
        'Верни JSON: {"phrases": ["…", "…"]}.'
    )


LABEL_SYSTEM = """Ты размечаешь фразы для регрессионных тестов помощника задач. Укажи, как фразу
ДОЛЖЕН понять правильно работающий помощник по спецификации ниже — даже если формулировка редкая.

Намерение (intent):
- createTask — просьба создать задачу или напоминание (добавь, создай, запиши, напомни, новая задача).
- rescheduleTask — перенести срок задачи (перенеси, сдвинь, отложи, передвинь).
- completeTask — команда или сообщение, что задача сделана (заверши, выполнил, готово, сделано).
  Вопросы («что выполнить?») и отрицания («не выполнено») — НЕ completeTask, а unknown.
- listTasks — показать задачи или планы.
- unknown — всё остальное.
Решает первое по порядку слово-команда вне кавычек: «Добавь задачу выполнить отчёт» — createTask.

Название (title):
- Только текст внутри парных кавычек « », “ ”, „ “, " ". Без кавычек — null.
- Слова и даты внутри кавычек не влияют на намерение и срок.
- Для rescheduleTask и completeTask title — название задачи в кавычках, к которой относится
  команда; без кавычек — null. Для listTasks и unknown — всегда null.
- Незакрытая кавычка: titleIssue = unbalancedQuotes, title = null.
- Несколько названий в кавычках: titleIssue = multipleTitles, title = null.

Срок (due) — только для createTask и rescheduleTask, иначе null:
- Формат «YYYY-MM-DD» без времени (precision = date) или «YYYY-MM-DDTHH:MM» (precision = dateTime).
- «сегодня», «завтра», «послезавтра», дни недели, «через N часов», «15 ноября» и т. п. —
  считай от текущего момента, указанного в запросе.
- Дата ДД.ММ без года — ближайшая не раньше сегодняшнего дня. ДД.ММ.ГГ — год 20ГГ.
- Только время без дня: если оно уже прошло сегодня — завтра в это время.
- Явный день (или дата) и время, которые уже прошли: due = null, issue = inPast.
  Явная дата в прошлом без времени — тоже inPast.
- «с 15:00 на 17:00» — срок 17:00 (берётся значение после «на»).
- Несуществующая дата (31.02): invalidDate. Несуществующее время (24:00, 25:10, «в 7.5»): invalidTime.
- Несколько разных дней: conflictingDays; несколько разных времён: conflictingTimes. В этих
  случаях due = null. Один и тот же день двумя способами («сегодня, 02.11») — не конфликт.
- Номера версий («версия 2.10») и телефонов — не сроки.
- Если срока нет: due = null, precision = null, issue = none.

confident = false, если фраза двусмысленна даже для человека; поясни в comment."""

_NULLABLE_STRING = {"anyOf": [{"type": "string"}, {"type": "null"}]}

LABEL_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "intent": {"type": "string", "enum": INTENTS},
        "title": _NULLABLE_STRING,
        "due": _NULLABLE_STRING,
        "precision": {"anyOf": [{"type": "string", "enum": PRECISIONS}, {"type": "null"}]},
        "issue": {"type": "string", "enum": ISSUES},
        "titleIssue": {"type": "string", "enum": TITLE_ISSUES},
        "confident": {"type": "boolean"},
        "comment": {"type": "string"},
    },
    "required": ["intent", "title", "due", "precision", "issue", "titleIssue", "confident", "comment"],
    "additionalProperties": False,
}

LABEL_FIELDS = ("intent", "title", "due", "precision", "issue", "titleIssue")


def label_prompt(text: str, now: str) -> str:
    moment = datetime.fromisoformat(now)
    weekday = WEEKDAYS[moment.weekday()]
    return (
        f"Текущий момент: {moment:%Y-%m-%d %H:%M}, {weekday}.\n"
        f"Фраза пользователя (между маркерами, как есть):\n<<<{text}>>>\n\n"
        "Верни разметку JSON-объектом."
    )
