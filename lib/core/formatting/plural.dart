/// Склонение существительного после числа: «1 день», «2 дня», «5 дней».
library;

/// Форма для числа [n]: [one] — 1, 21, 101…; [few] — 2–4, 22–24…;
/// [many] — 0, 5–20, 25–30…
String ruPlural(int n, String one, String few, String many) {
  final abs = n.abs();
  final mod100 = abs % 100;
  final mod10 = abs % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}

/// «1 день», «2 дня», «5 дней».
String days(int n) => '$n ${ruPlural(n, 'день', 'дня', 'дней')}';

/// «1 дело», «2 дела», «5 дел».
String deeds(int n) => '$n ${ruPlural(n, 'дело', 'дела', 'дел')}';
