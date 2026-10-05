/// Минимальная локализация интерфейса: ru (по умолчанию) и en.
/// Переводится только UI; названия книг и тексты модулей — данные.
library;

import 'state.dart';

bool get isEn => settings.lang == 'en';

/// ru → en по выбранному языку интерфейса.
String tr(String ru, String en) => isEn ? en : ru;
