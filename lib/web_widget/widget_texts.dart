/// Тексты веб-помощника вместо путей приложения (ADR-032): в складе нет
/// «Мой Связной → Помощники → Роли → Кладовщик» — вход берётся из входа
/// сотрудника на странице склада, а действия включает администратор
/// склада. Подстановки — те же, что у записей каталога (проверяет
/// `ReplyLibrary.withOverrides`).
abstract final class WidgetTexts {
  static const String _relogin =
      '{вы:Обновите|ты:Обнови} страницу склада и {вы:войдите|ты:войди} заново.';

  static const Map<String, String> replies = <String, String>{
    'common.loginLink': 'Это ссылка входа на склад для приложения Связной — '
        'здесь она не нужна: веб-помощник уже работает под вашим входом в '
        'склад.',
    'role.notConnected': '{app} ещё не подключён ({role}, {button}). '
        '$_relogin',
    'warehouse.notConnected': 'Склад не подключён. $_relogin',
    'warehouse.auth.token': 'Склад не принял вход помощника. $_relogin',
    'warehouse.auth.expired': 'Вход помощника устарел. $_relogin',
    'warehouse.auth.staff': 'Это видно только под своим логином. $_relogin',
    'warehouse.act.off': 'Действия через помощника выключены — их включает '
        'администратор склада.',
    'warehouse.act.needLogin': 'Действия — только под своим логином. '
        '$_relogin',
    'warehouse.act.otherLogin': 'Карточка — для {login}, а вход сейчас под '
        '{now}. {вы:Повторите|ты:Повтори} команду.',
  };
}
