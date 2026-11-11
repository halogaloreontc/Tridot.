"""Фильтр секретов: фразы, похожие на пароль, PIN-код, логин, почту или телефон, не сохраняются.

В модели уходят только синтетические фразы. Генератор может нарушить запрет из
generation_rules и вписать во фразу «пароль: …» или «wifi2024», а фразу из веб-чата вставляет
человек, — поэтому перед сохранением кандидата (generate, import-manual), перед отправкой
разметчику (label), перед примерами в промпте генерации и перед переносом в корпус (promote)
фраза проверяется здесь. Похожая на секрет фраза отбрасывается; печатается только их число,
сам текст — никогда (и в ошибках генерации кусок ответа модели скрывается, см. pipeline).

Проверка — не слабее SecretGuard приложения (lib/core/passwords/secret_guard.dart): его правила
повторены здесь дословно (_guard_flags; тест сверяет общий список фраз с настоящим SecretGuard),
а сверху — более строгие правила: любые кавычки во фразе навыка, «пароль от X это/— Y» с
названием любой длины, коды из цифр через пробелы («пин 12 34»), слова с буквами и цифрами от
4 знаков, слова со смешанным регистром («CanaryCanary»), латинское слово после «пароль»
(«мой пароль canary»), почта, телефон. Здесь лучше потерять синтетическую фразу, чем
сохранить секрет.

Проверяются фразы навыка «Пароли» и фразы любого коннектора со словом о пароле, PIN-коде,
логине или коде доступа («код домофона», «код: …»), в том числе написанным латиницей вперемешку
с кириллицей или «p@ssword». Склад («215-1-1-1», «где лежит 64115») и калькулятор без этих слов
не трогаются. Известный пробел: пароль из одних русских строчных букв без разделителя и кавычек
(«мой пароль котик») не отличить от слова — его запрещают generation_rules.
"""

from __future__ import annotations

import re

# Коннектор, у которого проверяется каждая фраза.
PASSWORDS_CONNECTOR = "passwords"

_START = r"(?<![\w])"
_END = r"(?![\w-])"

# Слова о секрете: формы «пароль», пасс, password, pwd, PIN-код, пин, логин.
_SECRET_WORD = (
    r"(?:парол[а-яё]*|мастер-?парол[а-яё]*|пасс|passwords?|passwd|pwd|pass|parol[a-z]*|"
    r"пин-?код[а-яё]*|pin-?code|pincode|pin-?код[а-яё]*|пин|pin|"
    r"логин[а-яё]*|login)"
)

# Упоминание: из-за него фраза другого коннектора проверяется так же строго.
_MENTION = re.compile(_START + _SECRET_WORD + _END, re.IGNORECASE)

# «Код» сам по себе бывает и у склада, поэтому упоминанием считается только код доступа:
# «код домофона», «код от двери», «код: …», «код 4821».
_CODE = r"(?:код[а-яё]*|code)"
_CODE_MENTION = re.compile(
    _START
    + _CODE
    + r"(?:\s+(?:от|для|к|на|у)\b|\s+(?:домофон|подъезд|двер|калитк|ворот|карт|сигнализац|сейф|замк|замо|доступ|"
    r"вход|wi-?fi|вайфа|роутер|телефон|смс|sms|подтвержд|приложени|банк|ячейк)|\s*[:=：]|\s+\d)",
    re.IGNORECASE,
)

# С разделителем — ещё и «код»: «код: 1234», «код домофона = 1234».
_KEY = r"(?:" + _SECRET_WORD + r"|" + _CODE + r")"
_KEY_RE = re.compile(_START + _KEY + _END, re.IGNORECASE)

# Разделитель — «:», «=», «：»; двоеточие времени («в 10:00») и адреса («https://») — нет.
_SEPARATOR = r"(?:(?<!\d)[:=：]|[:=：](?!\d))(?!//)"

_SEPARATED = re.compile(_START + _KEY + r"[^:=：\n]*?\s*" + _SEPARATOR + r"\s*\S", re.IGNORECASE)

# «логин X пароль Y» (как SecretGuard._loginPassword).
_LOGIN_PASSWORD = re.compile(
    _START
    + r"(?:логин|login)\s*[:=：]?\s*(?!(?:и|или|а|and|or)\s)\S+\s+(?:(?:и|а|and)\s+)?"
    + _SECRET_WORD
    + r"\s*[:=：]?\s*(?!(?:от|для|к|на|у)\s)\S+",
    re.IGNORECASE,
)

# «пароль от рабочей почты на ноутбуке это X», «пароль от wifi — X»: название любой длины.
_THIS_IS = re.compile(
    _START + _KEY + r"\s+(?:от|для|к|на|у)\s+[^\n]*?\s(?:это|—|–|-)\s+\S+",
    re.IGNORECASE,
)

# «пароль — это X», «пароль это X» без названия: X похож на пароль или латинское слово.
_THIS_IS_BARE = re.compile(_START + _KEY + r"[^\n]*?\s(?:это|—|–)\s+(\S+)", re.IGNORECASE)

# Любой фрагмент в кавычках: в кавычках обычно и пишут пароль («пароль "…"»).
_QUOTED = re.compile(r"[«“„\"'`‘][^«»“”„\"'`‘’]*[»”“\"'`’]")
_QUOTE_CHARS = re.compile(r"[«»“”„\"'`‘’]")

_EMAIL = re.compile(r"\S+@\S+")

# Телефон: 10 и больше цифр подряд, через пробелы, скобки, дефисы, «+».
_PHONE = re.compile(r"(?:\+?\d[\s()\-]*){10,}")

_EDGE = re.compile(r"^[«»“”„\"'`(\[{.,!?;:…]+|[«»“”„\"'`)\]}.,!?;:…]+$")

# Дата или время: «15.11», «10:00», «2026-11-04» — не секрет.
_DATE_TIME = re.compile(r"^\d{1,4}(?:[.:/-]\d{1,4}){1,2}$")

# Пример калькулятору: только цифры, знаки действий и скобки («2+2*2», «15%»).
_ARITHMETIC = re.compile(r"^[\d\s+\-*/×÷^().,%=]+$")

# Метка задачи: «#дом», «#работа».
_HASHTAG = re.compile(r"^#[^\W\d_][\w-]*$")

_LETTER = re.compile(r"[^\W\d_]")
_DIGIT = re.compile(r"\d")
_DIGITS_ONLY = re.compile(r"^\d+$")
# Слова через косую черту: «напомни/подскажи», «и/или».
_WORDS_SLASH = re.compile(r"^[^\W\d_][^\W\d_A-ZА-ЯЁ]*(?:/[^\W\d_][^\W\d_A-ZА-ЯЁ]*)+$")
_LATIN_WORD = re.compile(r"^[a-z]+$", re.IGNORECASE)
# Символ — не буква, не цифра, не дефис и не апостроф (они бывают в словах: «wi-fi», «Т-Банк»).
_SYMBOL = re.compile(r"[^\w\s'’-]|_")

# Число после «пароль» — параметр генератора, если дальше единица: «на 128 символов».
_UNIT = re.compile(r"^(?:символ|знак|слов|букв|цифр|раз|штук|шт|минут|час|дн|день|недел|месяц|лет|год|бит|байт)", re.I)

_PREPOSITIONS = frozenset({"от", "для", "к", "на", "у", "в", "из", "по", "с", "со"})

# Латинские названия сервисов и устройств: не пароль, хоть и латиница или смешанный регистр.
_KNOWN_LATIN = frozenset(
    """wifi wi-fi wi fi vk vkontakte google gmail yandex mail email e-mail apple id appleid icloud
    iphone ipad imac macbook mac android samsung xiaomi huawei honor windows microsoft outlook
    office skype zoom teams discord telegram tg whatsapp viber instagram insta facebook twitter
    tiktok youtube netflix spotify steam epic origin playstation psn xbox nintendo github gitlab
    linkedin paypal ozon wildberries wb avito sber sberbank tinkoff alfa vtb gosuslugi mts beeline
    megafon tele2 rostelecom router admin wpa wpa2 wps ssid pin pass password passwords login
    master chrome firefox safari edge opera brave bitwarden keepass keepassxc lastpass onedrive
    dropbox notion slack jira trello figma amazon ebay aliexpress booking airbnb uber yandexgo
    onlyoffice moodle wordpress hh headhunter dns mvideo lamoda kaspi okko ivi kinopoisk""".split()
)

# Латиница, похожая на кириллицу, и наоборот: «пaроль» с латинской «a», «pаssword».
_LAT_TO_CYR = str.maketrans("aeopcxykmthbAEOPCXYKMTHB", "аеорсхукмтнвАЕОРСХУКМТНВ")
_CYR_TO_LAT = str.maketrans("аеорсхукмтнвАЕОРСХУКМТНВ", "aeopcxykmthbAEOPCXYKMTHB")
# Цифры и знаки вместо букв: «p@ssw0rd», «pa$$».
_DELEET = str.maketrans("@$0134571!", "asoieastii")


def _variants(text: str) -> list[str]:
    """Текст и его написания без подмены букв: для поиска слова «пароль»."""
    tokens = text.split()
    deleet = " ".join(t.translate(_DELEET) if _LETTER.search(t) else t for t in tokens)
    return [text, text.translate(_LAT_TO_CYR), text.translate(_CYR_TO_LAT), deleet, deleet.translate(_LAT_TO_CYR)]


def _mentions_plain(text: str) -> bool:
    return bool(_MENTION.search(text) or _CODE_MENTION.search(text))


def mentions_secret(text: str) -> bool:
    """Во фразе есть слово о пароле, PIN-коде, логине или коде доступа (и замаскированное)."""
    return any(_mentions_plain(v) for v in _variants(text))


def looks_secret(text: str, connector: str | None = None) -> bool:
    """Фраза похожа на секрет и не должна попасть ни в модели, ни в корпус.

    Проверяются фразы навыка «Пароли» (connector="passwords") и фразы со словом о пароле,
    PIN-коде, логине или коде доступа; остальные фразы — всегда False. Слово «пароль»,
    написанное вперемешку латиницей и кириллицей или цифрами («p@ssword», «пaроль»), — уже
    секрет: так прячут пароль от фильтра, а не пишут в чат.
    """
    strict = connector == PASSWORDS_CONNECTOR
    if not _mentions_plain(text):
        if mentions_secret(text):
            return True
        if not strict:
            return False
    if _guard_flags(text):
        return True
    if _SEPARATED.search(text) or _LOGIN_PASSWORD.search(text) or _THIS_IS.search(text):
        return True
    for match in _THIS_IS_BARE.finditer(text):
        value = _EDGE.sub("", match.group(1))
        if _LATIN_WORD.match(value) or looks_like_password(value):
            return True
    if strict and (_QUOTED.search(text) or _QUOTE_CHARS.search(text)):
        return True
    if _EMAIL.search(text) or _PHONE.search(text):
        return True
    if any(_secret_token(token) for token in text.split()):
        return True
    return _after_keyword(text)


def _secret_token(raw: str) -> bool:
    """Слово похоже на пароль или код: «wifi2024», «c4n4r», «Kx9!mq2z», «CanaryCanary», «4821»."""
    token = _EDGE.sub("", raw)
    if not token or _HASHTAG.match(token) or _DATE_TIME.match(token) or _WORDS_SLASH.match(token):
        return False
    digits = len(_DIGIT.findall(token))
    letter = bool(_LETTER.search(token))
    symbol = bool(_SYMBOL.search(token))
    if not letter:
        if _ARITHMETIC.match(token):
            # PIN-код, код домофона, год — 4 цифры и больше подряд; «2+2*2», «на 24» — нет.
            return bool(re.search(r"\d{4,}", token))
        return digits > 0 or len(token) >= 6
    if digits and len(token) >= 4:
        return True
    if len(token) >= 6 and (digits or symbol):
        return True
    return len(token) >= 6 and token.lower() not in _KNOWN_LATIN and _mixed_case(token)


def _mixed_case(token: str) -> bool:
    """Заглавная не в начале и строчные в одной части слова: «CanaryCanary», «CANARYx»; «Т-Банк» — нет."""
    for part in re.split(r"[-'’]", token):
        if any(c.isupper() for c in part[1:]) and any(c.islower() for c in part):
            return True
    return False


def _after_keyword(text: str) -> bool:
    """После «пароль/пин/код»: цифры через пробелы («пин 12 34») или латинское слово («мой пароль canary»)."""
    for match in _KEY_RE.finditer(text):
        tokens = [_EDGE.sub("", t) for t in text[match.end() :].split()]
        # Название сервиса после предлога («пароль от почты») — не пароль.
        skip = 2 if tokens and tokens[0].lower() in _PREPOSITIONS else 0
        run = 0
        for i, token in enumerate(tokens):
            if _DIGITS_ONLY.match(token):
                run += len(token)
                continue
            if run >= 3 and not _UNIT.match(token):
                return True
            run = 0
            if i >= skip and _LATIN_WORD.match(token) and len(token) >= 3 and token.lower() not in _KNOWN_LATIN:
                return True
        if run >= 3:
            return True
    return False


# ------------------------------------------------------------------ SecretGuard дословно
# Правила SecretGuard.redact (без сверки отпечатков — хранилища здесь нет). Фраза, которую
# SecretGuard замаскировал бы, — секрет и здесь.

_G_START = r"(?<![\w])"
_G_WORD = (
    r"(?:пароль|пароля|паролю|паролем|пароле|"
    r"пароли|паролей|паролям|паролями|паролях|"
    r"пасс|passwords|password|passwd|pwd|pass|"
    r"пин-код[а-яё]*|pin-код[а-яё]*|пинкод[а-яё]*|pin-code|pincode|"
    r"пин|pin)"
    r"(?![\w-])"
)
_G_KEYWORD = _G_START + r"(?:(?:мой|моя|мои|my)\s+)?" + _G_WORD
_G_SEPARATOR = r"\s*(?:(?<!\d)[:=：]|[:=：](?!\d))(?!(?<=:)//)\s*"
_G_SERVICE = (
    r"(?:\s+(?:"
    r"(?:от|для|к|на|у)\s+(?:[^:=：\n«»\"“”„]|:(?=//))+?"
    r"|(?:[^\s:=：«»\"“”„]|:(?=//))+"
    r"(?:\s+(?:[^\s:=：«»\"“”„]|:(?=//))+){0,2}"
    r"))?"
)
_G_REST = r"(\S(?:[^\n]*\S)?)"
_G_FLAGS = re.IGNORECASE
_G_SEPARATED = re.compile(_G_KEYWORD + _G_SERVICE + _G_SEPARATOR + _G_REST, _G_FLAGS)
_G_LOGIN_PASSWORD = re.compile(
    _G_START
    + r"(?:логин|login)\s*[:=：]?\s*"
    + r"(?!(?:и|или|а|and|or)\s)\S+\s+(?:(?:и|а|and)\s+)?"
    + _G_KEYWORD
    + r"\s*[:=：]?\s*(?!(?:от|для|к|на|у)\s)"
    + _G_REST,
    _G_FLAGS,
)
_G_QUOTED = re.compile(_G_KEYWORD + _G_SERVICE + r"\s*[:=：]?\s*[\"«“„'](.+?)[\"»”“']", _G_FLAGS)
_G_THIS_IS = re.compile(_G_KEYWORD + _G_SERVICE + r"\s+это\s+(\S+)", _G_FLAGS)
_G_PHRASE = re.compile(_G_KEYWORD + r"\s+(?:(?:от|для|к|на|у)\s+)?\S+", _G_FLAGS)
_G_EDGE = re.compile(r"^[«»\"“”„(\[]+|[«»\"“”„.,!?;:)\]]+$")
_G_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_G_URL = re.compile(r"^(?:https?://|www\.)", re.IGNORECASE)
_G_DATE_TIME = re.compile(r"^\d{1,4}(?:[.:/-]\d{1,4}){1,2}$|^\d{1,2}:\d{2}$")


def looks_like_password(token: str, allow_spaces: bool = False) -> bool:
    """SecretGuard.looksLikePassword: цифра среди букв, символ, заглавные не только в начале."""
    if not token:
        return False
    if _G_EMAIL.match(token) or _G_URL.match(token) or _G_DATE_TIME.match(token):
        return False
    lower = upper_inside = digit = symbol = letter = False
    for index, char in enumerate(token):
        if char.lower() != char.upper():
            letter = True
            if char == char.lower():
                lower = True
            elif index > 0:
                upper_inside = True
        elif "0" <= char <= "9":
            digit = True
        elif char in "-'" or (char == " " and allow_spaces):
            pass
        else:
            symbol = True
    if not letter:
        return (digit and len(token) >= 4) or (symbol and digit)
    return digit or symbol or (upper_inside and lower)


def _guard_flags(text: str) -> bool:
    """SecretGuard.redact(text).guarded без отпечатков."""
    if _G_SEPARATED.search(text) or _G_LOGIN_PASSWORD.search(text) or _G_QUOTED.search(text):
        return True
    for match in _G_THIS_IS.finditer(text):
        if looks_like_password(match.group(1), allow_spaces=True):
            return True
    for match in _G_PHRASE.finditer(text):
        for token in re.finditer(r"\S+", text[match.end() :]):
            core = _G_EDGE.sub("", token.group(0))
            if len(core) >= 6 and looks_like_password(core):
                return True
    return False


def drop_secrets(texts: list[str], connector: str | None = None) -> tuple[list[str], int]:
    """Фразы без похожих на секрет и число отброшенных (сами отброшенные не возвращаются)."""
    kept = [t for t in texts if not looks_secret(t, connector)]
    return kept, len(texts) - len(kept)
