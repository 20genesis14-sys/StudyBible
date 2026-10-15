"""Фаза 8+ / Мегаэнциклопедия `knowledge.sb` (v0.3.0, ADR 0024 §§6–13):
1. Сверка и нормализация русских имён `entity_names` (исправление косвенных падежей
   в родословных, доведение покрытия русских имён до 100 % всех 5 700 сущностей).
2. Подключение 1 018 открытых русских статей `Door43 ru_tw` (CC BY-SA 4.0),
   генерация русских кратких описаний `short_description_ru` из открытых данных
   ACAI / STEPBible / Door43 и замыкание обратных родственных связей `relationships`.
3. Создание и заполнение таблицы `book_chronology` для всех 66 книг канона
   (Матрица хронологии написания канона, ADR 0024 §9) и таблицы `visual_aids`
   (буквенно-цифровые шифры `1A`, `26A`, шкалы с «гармошкой», межкнижные таблицы
   и родословные древа, ADR 0024 §§10–13).
4. Индексация 3 145 открытых иллюстраций, фотографий и карт (`OpenBible Geocoding`
   CC BY-SA / PD + `UBS Fauna/Flora/Realia` CC BY-SA 4.0) в таблицу `media`
   и поле `entities.image_path`.
"""
from __future__ import annotations

import collections
import hashlib
import json
import os
import pathlib
import re
import shutil
import sqlite3
import subprocess
import sys
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools" / "strongs" / "lexicon"))
sys.path.insert(0, str(REPO / "tools" / "strongs" / "pipeline"))

import common as C  # noqa: E402
from build_ru_layers import AUX_RU_WORDS, tokenize_module  # noqa: E402
from priors import norm_classic  # noqa: E402

DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))
KNOW_SB = DATA / "work" / "strongs" / "knowledge" / "knowledge.sb"

# 1. Исправление косвенных падежей (родительный/винительный/дательный в списках «сын Х»)
#    и ошибочных выравниваний локализации на точные формы именительного падежа.
OBLIQUE_TO_NOMINATIVE: dict[str, str] = {
    "Адлая": "Адлай",
    "Адна": "Аднах",
    "Амафиин": "Амафий",
    "Аммиуда": "Аммиуд",
    "Аммишаддая": "Аммишаддай",
    "Аридая": "Аридай",
    "Арода": "Арод",
    "Баладана": "Баладан",
    "Бесодея": "Бесодия",
    "Беф-Рафу": "Беф-Рафа",
    "Колхозея": "Колхозей",
    "Ахсафскому": "Ахсаф",
    "народа": "Амав",
    "киринеянин": "Кирена",
    "ефиопские": "Кушан",
    "возвышенности Адуммима": "Возвышенность Адуммим",
    "из дома Ашбеи": "Беф-Ашбея",
    "дома Фогарма": "Беф-Фогарма",
    "поток Египетский": "Поток Египетский",
    "долина Ахор": "Долина Ахор",
    "восточные ворота": "Восточные ворота",
    "восток": "Восток",
    "ареопаг": "Ареопаг",
    "царица Савская": "Царица Савская",
    "хананеянка": "Хананеянка",
    "агарянин": "Агарянин",
    "город Наас ": "Ир-Нахаш",
    "книга Праведного": "Книга Праведного (Яшар)",
    "Ахсf": "Ахса",
    "Alexandria": "Александрия",
    "Аcтароф": "Аштароф",
    "Гадорамa": "Гадорам",
    "Жена (Phineas)": "Жена Финееса",
    "Сиistr (трещотка)": "Систр (трещотка)",
    "Ваалверифа": "Ваал-Вериф",
    "Серафимов": "Серафимы",
    "Авиноамов": "Авиноам",
    "Авиноамова": "Авиноам",
}

# Метрические эквиваленты библейских мер длины, объёма, веса и денежных единиц
MEASURE_METRIC_RU: dict[str, str] = {
    "realia:Cubit": "Мера длины (расстояние от локтя до кончика среднего пальца): стандартный локоть ≈ 44,5 см.",
    "realia:Cubit.2": "Длинный (царский) локоть (6 ладоней + палец, Иез 40:5) ≈ 51,8 см.",
    "realia:Span": "Пядь (расстояние между разведёнными большим пальцем и мизинцем, ½ локтя) ≈ 22,2 см.",
    "realia:Handbreadth": "Ладонь (ширина четырёх пальцев, 1/6 локтя) ≈ 7,4 см.",
    "realia:Finger": "Палец (перст, наименьшая мера длины, ¼ ладони) ≈ 1,85 см.",
    "realia:Gomed": "Гомед (короткий локоть от локтя до сжатого кулака, Сд 3:16) ≈ 38 см.",
    "realia:MeasuringReed": "Измерительная трость (6 локтей): обычная ≈ 2,67 м; длинная (Иез 40:5) ≈ 3,11 м.",
    "realia:Fathom": "Сажень (оргия, морская мера глубины, Де 27:28) ≈ 1,8 м.",
    "realia:Stade": "Стадий (греческая и римская мера расстояния, 600 футов) ≈ 185 м.",
    "keyterm:HalfAMile": "Субботний путь (допустимое расстояние от города в субботу, Де 1:12, 2 000 локтей) ≈ 0,9–1 км.",
    "realia:Acre": "Цемед (участок поля, который пара волов вспахивает за один день, 1См 14:14) ≈ 0,2–0,25 га.",
    "realia:Bath": "Бат (основная мера жидких тел, равная по объёму ефе) ≈ 22 л (1/10 кора).",
    "realia:Hin": "Гин (мера жидкостей: вина и масла, 1/6 бата) ≈ 3,67 л.",
    "realia:Log": "Лог (наименьшая библейская мера жидкостей, 1/12 гина) ≈ 0,31 л.",
    "realia:Ephah": "Ефа (основная мера сыпучих тел, равная по объёму бату) ≈ 22 л (10 гоморов / 3 саты).",
    "realia:Saton": "Сата (греч. форма евр. сеа, мера муки и зерна, 1/3 ефы) ≈ 7,33 л.",
    "realia:Seah": "Сеа (сата, мера сыпучих тел, 1/3 ефы) ≈ 7,33 л.",
    "realia:Omer": "Гомор (омер, дневная норма манны на человека, 1/10 ефы, Исх 16:36) ≈ 2,2 л.",
    "realia:Kab": "Кав (мера сыпучих тел, 1/18 ефы или 4 лога) ≈ 1,22 л.",
    "realia:Homer": "Хомер (ослиный вьюк, наибольшая мера сыпучих тел, 10 еф / 10 батов) ≈ 220 л.",
    "realia:Kor": "Кор (крупная мера сыпучих и жидких тел, равная хомеру, 10 батов / 10 еф) ≈ 220 л.",
    "realia:Kor.2": "Кор (мера зерна и масла, равная 10 ефам или 10 батам) ≈ 220 л.",
    "realia:Quart": "Хиникс (дневной паёк пшеницы в НЗ, Отк 6:6) ≈ 1,08 л.",
    "realia:Gerah": "Гера (наименьшая еврейская мера веса, 1/20 шекеля) ≈ 0,57 г.",
    "realia:AHalfShekel": "Полшекеля (бека, храмовый сбор с каждого взрослого мужчины, 10 гер) ≈ 5,7 г.",
    "realia:Shekel": "Шекель (сикль, основная еврейская единица веса серебра и золота, 20 гер) ≈ 11,4 г.",
    "realia:Mina": "Мина (50 шекелей в Еврейских Писаниях ≈ 570 г; греческая мина в НЗ = 100 драхм ≈ 340 г).",
    "realia:Talent": "Талант (крупнейшая единица веса и денежного счёта, 3 000 шекелей / 60 мин) ≈ 34,2 кг (греч. талант ≈ 20,4 кг).",
    "realia:Pound": "Литра (римский фунт мирры и алоэ, Ин 12:3; 19:39) ≈ 327 г.",
    "realia:Daric": "Дарик (персидская золотая монета высокой пробы, 1Лт 29:7; Езд 8:27) ≈ 8,4 г золота.",
    "realia:Lepton": "Лепта (мельчайшая медная/бронзовая иудейская монета, ½ кодранта, 1/128 динария, Мк 12:42).",
    "realia:Quadrans": "Кодрант (римская медная монета, равная 2 лептам или 1/64 динария, Мк 12:42).",
    "realia:Assarion": "Ассарий (римская медная монета, равная 4 кодрантам или 1/16 динария, Мф 10:29).",
    "realia:Denarius": "Динарий (римская серебряная монета весом ≈ 3,85 г, обычный дневной заработок работника, Мф 20:2).",
    "realia:Drachma": "Драхма (греческая серебряная монета весом ≈ 3,4 г, близкая по стоимости к римскому динарию, Лк 15:8).",
    "realia:Two-drachmaPiece": "Дидрахма (греческая серебряная монета в 2 драхмы ≈ 6,8 г, сумма ежегодного храмового сбора, Мф 17:24).",
    "realia:Stater": "Статер (греческая серебряная монета в 4 драхмы / тетрадрахма ≈ 13,6 г, покрывавшая храмовый сбор за двоих, Мф 17:27).",
}

# 2. Прямой словарь русских названий для сущностей без прямого номера Стронга
#    (животные, растения, предметы быта, ключевые понятия, группы, составные топонимы и города).
EXPLICIT_RU_NAMES: dict[str, str] = {
    # Сверхъестественные существа и божества
    "deity:Angel": "Ангел",
    "deity:Demons": "Бесы (демоны)",
    "deity:El-berith": "Эл-Бериф (Ваал-Бериф)",
    "deity:FirstLivingCreature": "Первое живое существо",
    "deity:SecondLivingCreature": "Второе живое существо",
    "deity:ThirdLivingCreature": "Третье живое существо",
    "deity:FourthLivingCreature": "Четвёртое живое существо",
    "deity:Voice": "Голос с небес",
    # Животные (fauna)
    "fauna:Addax": "Аддакс (антилопа)",
    "fauna:BarnOwl": "Сипуха (сова)",
    "fauna:BlackKite": "Чёрный коршун",
    "fauna:Boar": "Дикий кабан",
    "fauna:BubalHartebeest": "Бубал (антилопа)",
    "fauna:Cormorant": "Баклан",
    "fauna:CreepingAnimal": "Пресмыкающееся",
    "fauna:Elephant": "Слон",
    "fauna:Flea": "Блоха",
    "fauna:Goose": "Гусь",
    "fauna:Hartebeest": "Конгони (антилопа)",
    "fauna:Hippopotamus": "Бегемот",
    "fauna:Hyrax": "Даман",
    "fauna:Iguana": "Варан",
    "fauna:Leech": "Пиявка",
    "fauna:MoleRat": "Слепыш",
    "fauna:Monkey": "Обезьяна",
    "fauna:Partridge": "Куропатка",
    "fauna:Quail": "Перепел",
    "fauna:RockPartridge": "Каменная куропатка (кеклик)",
    "fauna:WildCat": "Дикая кошка",
    # Растения (flora)
    "flora:Agarwood": "Алойное дерево (аквилария)",
    "flora:Almond": "Миндаль",
    "flora:BottleGourd": "Горлянка (бутылочная тыква)",
    "flora:Calamus": "Аир (душистый тростник)",
    "flora:Cattails": "Рогоз (камыш)",
    "flora:Chickpea": "Нут (турецкий горох)",
    "flora:CitronTree": "Цитрон",
    "flora:Coriander": "Кориандр",
    "flora:Ebony": "Эбеновое (чёрное) дерево",
    "flora:Elm": "Вяз (ильм)",
    "flora:Garlic": "Чеснок",
    "flora:Henna": "Хна (кипр)",
    "flora:Ivy": "Плющ",
    "flora:Mandrake": "Мандрагора",
    "flora:Mint": "Мята",
    "flora:PineTree": "Алеппская сосна",
    "flora:PoisonousHemlock": "Ядовитый болиголов",
    "flora:Sorghum": "Сорго",
    "flora:StarOfBethlehem": "Птицемлечник",
    "flora:Styrax": "Стиракс",
    "flora:Tulip": "Тюльпан",
    "flora:Watermelon": "Арбуз",
    # Предметы и реалии (realia)
    "realia:AlabasterJar": "Алебастровый сосуд",
    "realia:Arena": "Арена (амфитеатр)",
    "realia:Bagpipe": "Волынка (симфония)",
    "realia:Bath": "Бат (мера жидкостей)",
    "realia:Battering-ram": "Таран (стенобитное орудие)",
    "realia:Bellows": "Кузнечные мехи",
    "realia:Birthstool": "Родильный камень (кресло)",
    "realia:BreadOfDisplay": "Хлебы предложения",
    "realia:Breeches": "Льняные штаны (нижнее облачение)",
    "realia:Brick": "Кирпич",
    "realia:Chisel": "Резец (долото)",
    "realia:Cubit": "Локоть (мера длины)",
    "realia:Hinge": "Дверная петля (стержень)",
    "realia:Jinglet": "Подвеска (бубенчик)",
    "realia:Kor": "Кор (мера сыпучих тел)",
    "realia:PerimiterCurtain": "Завеса двора скинии",
    "realia:PotteryWheel": "Гончарный круг",
    "realia:Room": "Комната (горница)",
    "realia:SacredCakes": "Священные лепёшки",
    "realia:SecondStory": "Второй этаж (верхняя горница)",
    "realia:Shaker": "Систр (трещотка)",
    "realia:TheHolyPlace": "Святое (отделение скинии/храма)",
    "realia:Two-drachmaPiece": "Дидрахма (монета в две драхмы)",
    "realia:Talent": "Талант (мера веса и денег)",
    "realia:Shekel": "Шекель (сикль)",
    "realia:AHalfShekel": "Полшекеля (бека)",
    "realia:Gerah": "Гера (мера веса)",
    "realia:Mina": "Мина (мера веса и денег)",
    "realia:Pound": "Литра (римский фунт)",
    "realia:Daric": "Дарик (золотая монета)",
    "realia:Denarius": "Динарий (серебряная монета)",
    "realia:Drachma": "Драхма (серебряная монета)",
    "realia:Stater": "Статер (тетрадрахма)",
    "realia:Assarion": "Ассарий (медная монета)",
    "realia:Quadrans": "Кодрант (медная монета)",
    "realia:Lepton": "Лепта (мелкая монета)",
    "realia:Ephah": "Ефа (мера сыпучих тел)",
    "realia:Saton": "Сата (сеа, мера муки)",
    "realia:Seah": "Сеа (сата, мера сыпучих тел)",
    "realia:Omer": "Гомор (омер, мера сыпучих тел)",
    "realia:Kab": "Кав (мера сыпучих тел)",
    "realia:Homer": "Хомер (крупная мера объёма)",
    "realia:Kor.2": "Кор (мера объёма)",
    "realia:Hin": "Гин (мера жидкостей)",
    "realia:Log": "Лог (малая мера жидкостей)",
    "realia:Quart": "Хиникс (дневная мера зерна)",
    "realia:Span": "Пядь (мера длины)",
    "realia:Handbreadth": "Ладонь (мера длины)",
    "realia:Finger": "Палец (перст, мера длины)",
    "realia:Gomed": "Гомед (короткий локоть)",
    "realia:MeasuringReed": "Измерительная трость",
    "realia:Fathom": "Сажень (оргия, мера глубины)",
    "realia:Stade": "Стадий (мера расстояния)",
    "realia:Acre": "Цемед (участок воловьей упряжки)",
    # Понятия (keyterm)
    "keyterm:AbominationOfDesolation": "Мерзость запустения",
    "keyterm:Agitation": "Волнение (смятение)",
    "keyterm:Appease": "Умилостивить (умиротворить)",
    "keyterm:Appetite": "Жажда (аппетит)",
    "keyterm:Appoint": "Назначать (поставлять)",
    "keyterm:AppointedFeast": "Назначенный праздник",
    "keyterm:BeFirm": "Утверждённый (стойкий)",
    "keyterm:BearTheConsequencesOf": "Понести наказание за грех",
    "keyterm:BecomeWorthless": "Обесцениться (развратиться)",
    "keyterm:BegForMercy": "Умолять о милости",
    "keyterm:BelieveIn": "Верить (доверять)",
    "keyterm:BreadOfDisplay": "Хлебы предложения",
    "keyterm:BringHonorAndGloryOnOneself": "Прославить себя",
    "keyterm:BringToTheAttentionOf": "Довести до сведения",
    "keyterm:Community": "Община (собрание)",
    "keyterm:ConvincedOf": "Быть убеждённым",
    "keyterm:DayBeforeTheSabbath": "День приготовления (перед субботой)",
    "keyterm:Defame": "Порочить (злословить)",
    "keyterm:Diligent": "Усердный (прилежный)",
    "keyterm:EnticedToServe": "Принуждать к служению",
    "keyterm:EternalFire": "Вечный огонь",
    "keyterm:FeastOfWeeks": "Праздник седмиц (Пятидесятница)",
    "keyterm:FundamentalPrinciples": "Начала мира (основы)",
    "keyterm:GiveUpOrLayAsideWhatOnePossesses": "Оставить имущество",
    "keyterm:GuardAgainst": "Остерегаться (беречься)",
    "keyterm:Guidance": "Руководство (водительствующий совет)",
    "keyterm:HalfAMile": "Субботний путь",
    "keyterm:HaveAVision": "Видеть видение",
    "keyterm:HaveInsight": "Иметь разумение",
    "keyterm:HonoredTogetherWith": "Разделять славу и честь",
    "keyterm:KindlyDisposed": "Благосклонный",
    "keyterm:LandFlowingOfMilkAndHoney": "Земля, где течёт молоко и мёд",
    "keyterm:Lead": "Вести (руководить)",
    "keyterm:LiftUp": "Приносить клятву (поднимать руку)",
    "keyterm:MightyAct": "Великое дело (чудо)",
    "keyterm:MightyOne": "Сильный (Всемогущий)",
    "keyterm:NewMoonFestival": "Праздник новомесячия",
    "keyterm:OuterDarkness": "Внешняя тьма",
    "keyterm:PalmBranchAndReed": "Пальмовая ветвь и тростник (голова и хвост)",
    "keyterm:PleasingOdor": "Приятное благоухание",
    "keyterm:Proscribe": "Посвящённое Богу (херем)",
    "keyterm:Proscribe.2": "Преданное уничтожению (заклятое)",
    "keyterm:SelfImposedReligion": "Самовольное благочестие",
    "keyterm:ShowOneselfLoyal": "Проявлять верность",
    "keyterm:SomethingDevotedToGod": "Посвящённый дар Богу",
    "keyterm:Tumors": "Нарывы (опухоли)",
    "keyterm:UnableToSpeakWell": "Косноязычный",
    "keyterm:WordOfTheLord": "Слово Господне",
    # Группы (group)
    "group:Angels": "Ангелы",
    "group:Arbathite": "Арбатитяне",
    "group:Asshurim": "Ашурим",
    "group:Beth-shemesh": "Жители Вефсамиса",
    "group:Earlypatriarchs": "Древние патриархи",
    "group:EgyptianSlaveDrivers": "Египетские надсмотрщики",
    "group:Ekron": "Жители Экрона",
    "group:FalseWitnesses": "Лжесвидетели",
    "group:FarmWorkers": "Жнецы (земледельцы)",
    "group:Gad": "Гадитяне (колено Гада)",
    "group:Gadara": "Гадаринцы",
    "group:Gaza": "Жители Газы",
    "group:GenericBelievers": "Верующие",
    "group:GenericChildren": "Дети",
    "group:GenericChurch": "Церковь (собрание)",
    "group:GenericDaughters": "Дочери",
    "group:GenericDisciples": "Ученики",
    "group:GenericElders": "Старейшины",
    "group:GenericEnemies": "Враги",
    "group:GenericFemales": "Женщины",
    "group:GenericGroup": "Группа людей",
    "group:GenericMales": "Мужчины",
    "group:GenericOfficials": "Начальники (чиновники)",
    "group:GenericPriests": "Священники",
    "group:GenericProphets": "Пророки",
    "group:GenericRulers": "Правители",
    "group:GenericServants": "Слуги",
    "group:GenericSons": "Сыновья",
    "group:Girzites": "Гирзитяне",
    "group:HalfBrothersOfJephthah": "Единокровные братья Иеффая",
    "group:Herdsmen": "Пастухи",
    "group:Heshbon": "Жители Есевона",
    "group:Joseph": "Потомки Иосифа",
    "group:Lepers": "Прокажённые",
    "group:Magi": "Мудрецы с востока (волхвы)",
    "group:Magicians": "Египетские жрецы-маги",
    "group:Malta": "Жители Мальты",
    "group:Messengers": "Вестники (посланники)",
    "group:MilitaryMembers": "Воины",
    "group:Mishraites": "Мишраитяне",
    "group:Parents": "Родители",
    "group:Puthites": "Пуфитяне",
    "group:ReligiousOfficials": "Религиозные начальники",
    "group:Sailors": "Моряки (корабельщики)",
    "group:Sanhedrin": "Синедрион",
    "group:Shuhites": "Шухитяне",
    "group:Shumathites": "Шумафитяне",
    "group:Singers": "Певцы",
    "group:Sinners": "Грешники",
    "group:SonsOfLaban": "Сыновья Лавана",
    "group:SonsOfSceva": "Сыновья Скевы",
    "group:Spies": "Разведчики (соглядатаи)",
    "group:TaxCollectors": "Сборщики налогов (мытари)",
    "group:Timnites": "Фимнитяне",
    "group:Watchmen": "Стражи (сторожа)",
    # Персонажи (person)
    "person:Abi-albon": "Ави-Албон",
    "person:Ambassador": "Посол (вестник)",
    "person:Arba": "Арба",
    "person:Baal-zebub": "Веельзевул (Ваал-Зевув)",
    "person:BlindMan": "Слепой",
    "person:Centurion": "Сотник (центурион)",
    "person:Centurion.2": "Сотник из Капернаума",
    "person:Centurion.3": "Сотник у креста",
    "person:ChiefBaker": "Главный пекарь (хлебодар) фараона",
    "person:ChiefCupbearer": "Главный виночерпий фараона",
    "person:CretanProphet": "Критский пророк (Эпименид)",
    "person:Daughter1OfLot": "Старшая дочь Лота",
    "person:Daughter2OfLot": "Младшая дочь Лота",
    "person:Drunkard": "Пьяница",
    "person:Dysmas": "Разбойник на кресте (Дисмас)",
    "person:Gestas": "Разбойник на кресте (Гестас)",
    "person:Fool": "Глупец (неразумный)",
    "person:FortuneTeller": "Прорицательница (гадалка)",
    "person:GenericBlindMan": "Слепой человек",
    "person:GenericDaughter": "Дочь",
    "person:GenericDisciple": "Ученик",
    "person:GenericEnemy": "Враг",
    "person:GenericFather": "Отец",
    "person:GenericFemale": "Женщина",
    "person:GenericMale": "Мужчина",
    "person:GenericMidwife": "Повитуха",
    "person:GenericMother": "Мать",
    "person:GenericOfficial": "Вельможа (начальник)",
    "person:GenericPerson": "Человек",
    "person:GenericPriest": "Священник",
    "person:GenericProphet": "Пророк",
    "person:GenericRuler": "Правитель",
    "person:GenericServant": "Слуга (раб)",
    "person:GenericSon": "Сын",
    "person:HealedInvalid": "Исцелённый у купальни Вифезда",
    "person:Horseman": "Всадник",
    "person:Husband": "Муж",
    "person:Informant": "Доносчик (осведомитель)",
    "person:JerusalemWives": "Иерусалимские жёны",
    "person:Josech": "Иосиф (Иосех, предок Иисуса)",
    "person:KinsmanRedeemer": "Родственник-искупитель (гоэль)",
    "person:Leper": "Прокажённый",
    "person:Lookout": "Дозорный (страж)",
    "person:MacedonianMan": "Муж-македонянин",
    "person:MilitaryMember": "Воин",
    "person:PhilippianJailer": "Темничный страж в Филиппах",
    "person:Psalmist": "Псалмопевец",
    "person:Pyrrhus": "Пирр",
    "person:ReligiousOfficial": "Начальник синагоги",
    "person:RichYoungRuler": "Богатый молодой начальник",
    "person:SecondAccuserOfPeter": "Вторая служанка, обвинившая Петра",
    "person:ShipCaptain": "Капитан корабля (кормчий)",
    "person:Sluggard": "Ленивец",
    "person:StewardOfJoseph": "Управляющий дома Иосифа",
    "person:SyrophonecianWoman": "Сирофиникиянка",
    "person:UncleOfSaul": "Дядя Саула",
    "person:Widow": "Вдова",
    "person:WifeOfZebedee": "Жена Зеведея (Саломия)",
    # Места и исторические топонимы (place)
    "place:Abila": "Авила (в Перее)",
    "place:AbilaLysaniou": "Авила Лисаниева",
    "place:Adami-nekeb": "Адами-Некев",
    "place:Adasa": "Адаса",
    "place:Adulis": "Адулис",
    "place:AegeanSea": "Эгейское море",
    "place:Amathus": "Амафунт",
    "place:Aphik": "Афик",
    "place:Apollonia-Arsuf": "Аполлония (Арсуф)",
    "place:Aquincum": "Аквинк",
    "place:Aram-maacah": "Арам-Мааха",
    "place:Arbela": "Арбела",
    "place:Archelais": "Архелаида",
    "place:Ashteroth-karnaim": "Аштероф-Карнаим",
    "place:AsiaMinor": "Малая Азия",
    "place:AugustaTreverorum": "Августа-Треверорум (Трир)",
    "place:AugustaVindelicum": "Августа-Винделикорум (Аугсбург)",
    "place:Baal-hazor": "Ваал-Гацор",
    "place:Baal-meon": "Ваал-Меон",
    "place:Baalath-beer": "Ваалаф-Беэр",
    "place:Babylonia": "Вавилония",
    "place:BacaValley": "Долина Бака (Плача)",
    "place:Bamoth-baal": "Вамоф-Ваал",
    "place:Batanea": "Батанея",
    "place:Bealoth.2": "Беалоф (на севере Израиля)",
    "place:Bene-jaakan": "Бене-Яакан",
    "place:Beth-haggan": "Беф-Ган",
    "place:Beth-haram": "Беф-Гаран",
    "place:Beth-horonLower": "Нижний Беф-Орон",
    "place:Beth-horonUpper": "Верхний Беф-Орон",
    "place:Beth-nimrah": "Беф-Нимра",
    "place:Beth-pelet": "Беф-Палет",
    "place:Beth-rehob": "Беф-Рехов",
    "place:Beth-shan": "Беф-Сан (Скифополь)",
    "place:Bethabara": "Вифавара (Вифания за Иорданом)",
    "place:BeyondTheJordan": "Заиорданье",
    "place:Bostra": "Бостра",
    "place:Brundisium": "Брундизий",
    "place:Burdigala": "Бурдигала (Бордо)",
    "place:Byzantium": "Византий (Константинополь)",
    "place:Carthage": "Карфаген",
    "place:Chalcedon": "Халкидон",
    "place:Chephar-ammoni": "Кефар-Аммонай",
    "place:CityOfDestruction": "Город разрушения (Город солнца)",
    "place:CityOfPalms.2": "Город пальм",
    "place:Corduba": "Кордуба (Кордова)",
    "place:Ctesiphon": "Ктесифон",
    "place:Daphne": "Дафна",
    "place:Dion": "Дион",
    "place:Eburacum": "Эборак (Йорк)",
    "place:Edessa": "Эдесса",
    "place:Eglath-shelishiyah.1": "Эглаф-Шелишия",
    "place:Emek-keziz": "Емек-Кециц",
    "place:Emmatha": "Эммафа",
    "place:En-rogel": "Эн-Рогел",
    "place:Ephron.2": "Ефрон (Ефраин)",
    "place:Ezion-geber": "Ецион-Гавер",
    "place:Gades": "Гадес (Кадис)",
    "place:Gamala": "Гамала",
    "place:Ge-harashim": "Ге-Харашим (Долина ремесленников)",
    "place:Geneva": "Женева",
    "place:GilboaMount": "Гора Гелвуй",
    "place:Gischala": "Гисхала (Гуш-Халав)",
    "place:Hadad-rimmon": "Гадад-Риммон",
    "place:Harosheth-hagoyim": "Харошеф-Гоим",
    "place:HeracleopolisMagna": "Гераклеополь Великий",
    "place:Hippo": "Гиппон",
    "place:Hippos": "Гиппос (Сусита)",
    "place:InspectionGate": "Смотровые ворота (ворота Гаммифкад)",
    "place:Ir-moab": "Ир-Моав",
    "place:Ir-shemesh": "Ир-Шемеш",
    "place:JacobsWell": "Колодец Иакова",
    "place:JordanValley": "Иорданская долина",
    "place:Jotapata": "Иотапата (Йодфат)",
    "place:Kerioth-hezron": "Кериоф-Хецрон",
    "place:KhirbetEd-Deir": "Хирбет-эд-Дейр",
    "place:Kibroth-hattaavah": "Киброт-Гаттаава (Гробы прихоти)",
    "place:Kiriath-jearim": "Кириаф-Иарим",
    "place:Latopolis": "Латополь (Эсна)",
    "place:Leb-kamai": "Лев-Камай",
    "place:LeptisMagna": "Лептис-Магна",
    "place:Lesbos": "Лесбос",
    "place:Lo-debar": "Лодевар",
    "place:Londinium": "Лондиний (Лондон)",
    "place:LowerGulloth": "Нижние источники (Гуллоф)",
    "place:LowerPool": "Нижний пруд",
    "place:Lud.2": "Лудим",
    "place:Lugdunum": "Лугдун (Лион)",
    "place:Lutetia": "Лютеция (Париж)",
    "place:Luxeuil": "Люксёй",
    "place:Maareh-geba": "Мааре-Гева",
    "place:Machaerus": "Махерон",
    "place:Magdala": "Магдала",
    "place:Marmoutier": "Мармутье",
    "place:Masada": "Масада",
    "place:Massilia": "Массилия (Марсель)",
    "place:Mediolanum": "Медиолан (Милан)",
    "place:Meronoth": "Мероноф",
    "place:Meshech-tubal": "Мешех и Фувал",
    "place:MiddleGate": "Средние ворота",
    "place:Misrephoth-maim": "Мисрефоф-Маим",
    "place:Montecassino": "Монтекассино",
    "place:Moriah": "Мориа",
    "place:MountAthos": "Гора Афон",
    "place:MountColzim": "Гора Колзим",
    "place:MountZemaraim": "Гора Цемараим",
    "place:Naqlun": "Наклун",
    "place:Narbo": "Нарбон",
    "place:Nazianzus": "Назианз",
    "place:Nicaea": "Никея",
    "place:Nicomedia": "Никомидия",
    "place:Nola": "Нола",
    "place:NorthGate": "Северные ворота",
    "place:Nyssa": "Нисса",
    "place:OldPool": "Старый пруд",
    "place:Patras": "Патры",
    "place:Pella": "Пелла",
    "place:Poitiers": "Пуатье",
    "place:Qumran": "Кумран",
    "place:Ramathaim-zophim": "Рамафаим-Цофим",
    "place:Raphia": "Рафия",
    "place:Ravenna": "Равенна",
    "place:Scillium": "Сциллий",
    "place:Sebaste": "Севастия (Самария)",
    "place:Sennabris": "Сеннабрис",
    "place:Sepphoris": "Сепфорис (Циппори)",
    "place:Seville": "Севилья (Гиспалис)",
    "place:Shaalbon": "Шаалбон",
    "place:Siloam": "Силоам",
    "place:SinaiMount": "Гора Синай",
    "place:SouthGate": "Южные ворота",
    "place:StAlbans": "Сент-Олбанс (Веруламий)",
    "place:Subiaco": "Субиако",
    "place:Synnada": "Синнада",
    "place:Tabbur-erez": "Пуп земли (возвышенность)",
    "place:TaborMount": "Гора Фавор",
    "place:Tarentum": "Тарент",
    "place:Tarraco": "Тарракон",
    "place:TerritoryOfAsher": "Удел Асира",
    "place:TerritoryOfBenjamin": "Удел Вениамина",
    "place:TerritoryOfDan": "Удел Дана",
    "place:TerritoryOfEastManasseh": "Восточный удел Манассии",
    "place:TerritoryOfEphraim": "Удел Ефрема",
    "place:TerritoryOfGad": "Удел Гада",
    "place:TerritoryOfIssachar": "Удел Иссахара",
    "place:TerritoryOfJudah": "Удел Иуды",
    "place:TerritoryOfNaphtali": "Удел Неффалима",
    "place:TerritoryOfReuben": "Удел Рувима",
    "place:TerritoryOfSimeon": "Удел Симеона",
    "place:TerritoryOfWestManasseh": "Западный удел Манассии",
    "place:TerritoryOfZebulun": "Удел Завулона",
    "place:TheLordWillProvide": "Иегова-Ире (Господь усмотрит)",
    "place:Theveste": "Тевеста",
    "place:Timnath-heres": "Фимнаф-Херес",
    "place:Tingi": "Тингис (Танжер)",
    "place:Toletum": "Толет (Толедо)",
    "place:TowerOfShechem": "Башня Сихема",
    "place:Trapezus": "Трапезунд",
    "place:UpperGulloth": "Верхние источники (Гуллоф)",
    "place:UpperPool": "Верхний пруд",
    "place:Uqnu": "Река Укну",
    "place:Valencia": "Валентия (Валенсия)",
    "place:ValleyOfDecision": "Долина суда (решения)",
    "place:ValleyOfGerar": "Долина Герара",
    "place:ValleyOfMizpeh": "Долина Мицпы",
    "place:Vercellae": "Верцеллы",
    "place:Vienne": "Вьенн",
    "place:Vindobona": "Виндобона (Вена)",
    "place:Vivarium": "Виварий",
    "place:WatersOfJericho": "Воды Иерихона",
    "place:WayOfTheRedSea": "Путь к Чермному морю",
    "place:WestGate": "Западные ворота",
    "place:WildernessOfMaon": "Пустыня Маон",
    "place:WildernessOfParan": "Пустыня Фаран",
    # Сущности, у которых автоматика оставила только косвенные формы (баг-фикс v0.4.1)
    "deity:Asherah": "Ашера",
    "deity:Destiny": "Мени (божество судьбы)",
    "deity:Fortune": "Гад (божество удачи)",
    "deity:Lucifer": "Денница",
    "deity:Nehushtan": "Нехуштан (медный змей)",
    "deity:Succoth-benoth": "Суккот-Беноф",
    "fauna:Bull": "Крупный рогатый скот",
    "fauna:Camel": "Верблюд",
    "fauna:Cobra": "Аспид (ядовитая змея)",
    "fauna:Donkey": "Осёл",
    "fauna:Dugong": "Тахаш (дюгонь)",
    "fauna:Horse": "Конь",
    "fauna:Jackal": "Шакал",
    "fauna:Locust": "Саранча",
    "fauna:Mule": "Мул",
    "fauna:Osprey": "Скопа",
    "fauna:Rooster": "Петух",
    "fauna:Swallow": "Ласточка",
    "fauna:WildDonkey": "Дикий осёл",
    "fauna:Wolf": "Волк",
    "flora:Aloes": "Алоэ",
    "flora:AppleTree": "Яблоня",
    "flora:Bean": "Бобы",
    "flora:Boxthorn": "Терн (терновник)",
    "flora:DatePalm": "Финиковая пальма",
    "flora:Frankincense": "Ладан (фимиам)",
    "flora:Grain": "Зерно",
    "flora:Papyrus": "Папирус",
    "flora:PistachioNuts": "Фисташки",
    "flora:Soap": "Мыльнянка",
    "flora:Terebinth": "Теревинф (терпентинное дерево)",
    "flora:Thistle": "Чертополох",
    "flora:Vine": "Виноградная лоза",
    "group:Asia": "Асийцы",
    "group:Avva": "Иввиты",
    "group:Buzites": "Вузитяне",
    "group:Colossae": "Колоссяне",
    "group:Elam": "Еламиты",
    "group:Ephesus": "Ефесяне",
    "group:Eri": "Ерииты",
    "group:Ethiopia": "Ефиопляне",
    "group:Freedmen": "Либертинцы",
    "keyterm:KnowerOfHearts": "Сердцеведец",
    "keyterm:Letter": "Письмо (документ)",
    "keyterm:Life": "Жизнь",
    "keyterm:Majesty": "Величие",
    "keyterm:Mercy": "Милосердие",
    "keyterm:Mighty": "Всемогущий",
    "keyterm:Oath": "Клятва",
    "keyterm:Offering": "Жертва (жертвоприношение)",
    "keyterm:Passover": "Пасха",
    "keyterm:Poor": "Бедные (угнетённые)",
    "keyterm:PracticeDivination": "Прорицание (ворожба)",
    "keyterm:Pray": "Молитва",
    "keyterm:Psalm": "Псалом",
    "keyterm:Resurrection": "Воскресение",
    "keyterm:RoundDance": "Хоровод",
    "keyterm:Savior": "Спаситель",
    "keyterm:Sin": "Грех",
    "keyterm:Slaughtering": "Жертва (заклание)",
    "keyterm:Speak": "Пророчество",
    "keyterm:Strength": "Сила",
    "keyterm:TaxCollector": "Сборщик налогов (мытарь)",
    "keyterm:Terror": "Ужас",
    "keyterm:TheWay": "Путь",
    "keyterm:Truth": "Истина",
    "keyterm:Witness": "Свидетель",
    "keyterm:Woe": "Горе",
    "keyterm:Worship": "Поклонение",
    "person:Baal-hanan": "Ваал-Ханан",
    "person:Baal-hanan.2": "Ваал-Ханан",
    "person:Bath-shua": "Вирсавия (Ват-Шуа)",
    "person:Ben-hur": "Бен-Хур",
    "person:Hacaliah": "Ахалия",
    "person:Haggedolim": "Гагедолим",
    "person:Nero": "Нерон",
    "place:Aram-zobah": "Сирия-Цова (Арам-Цова)",
    "place:BeautifulGate": "Красные ворота",
    "place:Beth-arbel": "Бет-Арбел",
    "place:Beth-eked": "Беф-Екед",
    "place:Beth-ezel": "Бет-Ецель",
    "place:BroadWall": "Широкая стена",
    "place:BrookOfTheWillows": "Поток Ив (верб)",
    "place:CityOfSalt": "Город Соли (Ир-Мелах)",
    "place:Corban": "Сокровищница храма (Корбан)",
    "place:DragonSpring": "Драконов источник",
    "place:EbalMount": "Гора Гевал (Евал)",
    "place:Eden.2": "Едемский сад",
    "place:En-hazor": "Ен-Гацор",
    "place:Eth-kazin": "Итта-Кацин",
    "place:FoundationGate": "Ворота основания",
    "place:Greece": "Греция (Еллада)",
    "place:GuardGate": "Ворота стражи",
    "place:HallOfTheThrone": "Зал престола",
    "place:Kue": "Кува (Киликия)",
    "place:MizarMount": "Гора Мицар",
    "place:Mizpeh.3": "Мицфа",
    "place:OlivesMount": "Елеонская гора (Масличная)",
    "place:Parbar": "Парвар",
    "place:Perez-uzza": "Перец-Узза",
    "place:PotsherdGate": "Ворота черепков (Харсиф)",
    "place:RockOfEscape": "Села-Гаммахлекоф",
    "place:Sheba.2": "Савская (Аравия)",
    "place:SolomonsPortico": "Притвор Соломона",
    "place:Tel-abib": "Тель-Авив",
    "place:ThreeTaverns": "Три гостиницы",
    "place:TowerOfTheOvens": "Печная башня",
    "place:Trogyllium": "Трогиллий",
    "place:ValleyGate": "Ворота долины",
    "place:WaterGate": "Водяные ворота",
    "place:WildgoatsRocks": "Скалы серн",
    "place:YeshanahGate": "Ворота Иешаны",
    "place:Zeredah.2": "Цареда",
    "realia:Aloes": "Алоэ (благовоние)",
    "realia:Altar": "Жертвенник",
    "realia:Anvil": "Наковальня",
    "realia:Arrow": "Стрела",
    "realia:Bag": "Мешок (кошелёк)",
    "realia:Basket": "Корзина",
    "realia:Battle-axe": "Боевой топор",
    "realia:Bowl": "Чаша",
    "realia:Capital": "Капитель (столб)",
    "realia:Clothing": "Одежда",
    "realia:Craftsman": "Ремесленник",
    "realia:Cross": "Крест (столб казни)",
    "realia:Crown": "Венец",
    "realia:Crown.2": "Венец (диадема)",
    "realia:Curtain": "Завеса",
    "realia:Doorstep": "Порог",
    "realia:Entrance": "Вход",
    "realia:FestivalOfTheTabernacles": "Праздник кущей (Суккот)",
    "realia:Floor": "Пол",
    "realia:Fortification": "Укрепление",
    "realia:Foundation": "Основание",
    "realia:GravenImage": "Идол (истукан)",
    "realia:Harpoon": "Гарпун",
    "realia:HighPlace": "Высота (капище)",
    "realia:Image": "Изображение (идол)",
    "realia:Lamp": "Светильник",
    "realia:Lampstand": "Светильник (менора)",
    "realia:Loop": "Петля",
    "realia:Lyre": "Кифара (лира)",
    "realia:MoltenImage": "Литой истукан",
    "realia:Myrrh": "Мирра (смирна)",
    "realia:Pit": "Яма",
    "realia:Plaster": "Штукатурка",
    "realia:Prison": "Темница",
    "realia:ReplicaTemple": "Храм (модель)",
    "realia:Rope": "Верёвка",
    "realia:SacredPole": "Священный шест (ашера)",
    "realia:Seal": "Печать",
    "realia:Ship": "Корабль",
    "realia:Siege-works": "Осадные сооружения",
    "realia:SiegeTower": "Осадная башня",
    "realia:Sieve": "Решето",
    "realia:Soap": "Мыло (щёлок)",
    "realia:StoneAltar": "Каменный жертвенник",
    "realia:TabernacleAltar": "Жертвенник скинии",
    "realia:Tablet": "Скрижаль (дощечка)",
    "realia:Temple": "Храм",
    "realia:TempleAltar": "Жертвенник храма",
    "realia:Threshing-sledge": "Молотильная повозка",
    "realia:ThreshingFloor": "Гумно",
    "realia:ToSaddle": "Седло",
    "realia:Torch": "Факел",
    "realia:Trap": "Ловушка",
    "realia:Wagon": "Колесница",
    "realia:Watch-tower": "Сторожевая башня",
    "realia:Weapons": "Оружие",
}

# 3. Таблица хронологии написания всех 66 канонических книг Библии (ADR 0024 §9):
#    (book, book_num, written_start, written_end, uncertain, events_start, events_end,
#     author_en, author_ru, place_en, place_ru, period_en, period_ru)
#    Отрицательные годы = до н. э. (BCE), положительные = н. э. (CE).
BOOK_CHRONOLOGY_ROWS: list[tuple] = [
    ("GEN", 1, -1513, -1513, 0, -4026, -1657, "Moses", "Моисей", "Wilderness", "Пустыня", '"In the beginning" to 1657 BCE', "«В начале» — 1657 до н. э."),
    ("EXO", 2, -1512, -1512, 0, -1657, -1512, "Moses", "Моисей", "Wilderness", "Пустыня", "1657–1512 BCE", "1657–1512 до н. э."),
    ("LEV", 3, -1512, -1512, 0, -1512, -1512, "Moses", "Моисей", "Wilderness", "Пустыня", "1 month (1512 BCE)", "1 месяц (1512 до н. э.)"),
    ("NUM", 4, -1473, -1473, 0, -1512, -1473, "Moses", "Моисей", "Wilderness and Plains of Moab", "Пустыня и равнины Моава", "1512–1473 BCE", "1512–1473 до н. э."),
    ("DEU", 5, -1473, -1473, 0, -1473, -1473, "Moses", "Моисей", "Plains of Moab", "Равнины Моава", "2 months (1473 BCE)", "2 месяца (1473 до н. э.)"),
    ("JOS", 6, -1450, -1450, 1, -1473, -1450, "Joshua", "Иисус Навин", "Canaan", "Ханаан", "1473 – c. 1450 BCE", "1473 — ок. 1450 до н. э."),
    ("JDG", 7, -1100, -1100, 1, -1450, -1120, "Samuel", "Самуил", "Israel", "Израиль", "c. 1450 – c. 1120 BCE", "ок. 1450 — ок. 1120 до н. э."),
    ("RUT", 8, -1090, -1090, 1, -1160, -1149, "Samuel", "Самуил", "Israel", "Израиль", "11 years of rule by judges", "11 лет правления судей"),
    ("1SA", 9, -1078, -1078, 1, -1180, -1078, "Samuel, Gad, Nathan", "Самуил, Гад, Нафан", "Israel", "Израиль", "c. 1180–1078 BCE", "ок. 1180–1078 до н. э."),
    ("2SA", 10, -1040, -1040, 1, -1077, -1040, "Gad, Nathan", "Гад, Нафан", "Israel", "Израиль", "1077 – c. 1040 BCE", "1077 — ок. 1040 до н. э."),
    ("1KI", 11, -580, -580, 0, -1040, -840, "Jeremiah", "Иеремия", "Judah and Egypt", "Иуда и Египет", "c. 1040–580 BCE (1 & 2 Kings)", "ок. 1040–580 до н. э. (1 и 2 Царей)"),
    ("2KI", 12, -580, -580, 0, -840, -580, "Jeremiah", "Иеремия", "Judah and Egypt", "Иуда и Египет", "c. 1040–580 BCE (1 & 2 Kings)", "ок. 1040–580 до н. э. (1 и 2 Царей)"),
    ("1CH", 13, -460, -460, 1, -1077, -997, "Ezra", "Ездра", "Jerusalem", "Иерусалим", "1077–537 BCE (after genealogies)", "1077–537 до н. э. (после родословных)"),
    ("2CH", 14, -460, -460, 1, -997, -537, "Ezra", "Ездра", "Jerusalem", "Иерусалим", "1077–537 BCE", "1077–537 до н. э."),
    ("EZR", 15, -460, -460, 1, -537, -467, "Ezra", "Ездра", "Jerusalem", "Иерусалим", "537 – c. 467 BCE", "537 — ок. 467 до н. э."),
    ("NEH", 16, -443, -440, 1, -456, -443, "Nehemiah", "Неемия", "Jerusalem", "Иерусалим", "456 – after 443 BCE", "456 — после 443 до н. э."),
    ("EST", 17, -475, -475, 1, -493, -475, "Mordecai", "Мардохей", "Shushan (Elam)", "Сузы (Элам)", "493 – c. 475 BCE", "493 — ок. 475 до н. э."),
    ("JOB", 18, -1473, -1473, 1, -1657, -1473, "Moses", "Моисей", "Wilderness", "Пустыня", "Over 140 years between 1657 and 1473 BCE", "Более 140 лет между 1657 и 1473 до н. э."),
    ("PSA", 19, -1473, -460, 1, -1513, -460, "David and others", "Давид и другие", "Israel / Jerusalem", "Израиль / Иерусалим", "c. 1513 – c. 460 BCE", "ок. 1513 — ок. 460 до н. э."),
    ("PRO", 20, -1000, -717, 1, -1000, -717, "Solomon, Agur, Lemuel", "Соломон, Агур, Лемуил", "Jerusalem", "Иерусалим", "Compiled by c. 717 BCE", "Собрана к ок. 717 до н. э."),
    ("ECC", 21, -1000, -1000, 1, -1020, -1000, "Solomon", "Соломон", "Jerusalem", "Иерусалим", "Before 1000 BCE", "До 1000 до н. э."),
    ("SNG", 22, -1020, -1020, 1, -1020, -1020, "Solomon", "Соломон", "Jerusalem", "Иерусалим", "c. 1020 BCE", "ок. 1020 до н. э."),
    ("ISA", 23, -732, -730, 1, -778, -732, "Isaiah", "Исаия", "Jerusalem", "Иерусалим", "c. 778 – after 732 BCE", "ок. 778 — после 732 до н. э."),
    ("JER", 24, -580, -580, 0, -647, -580, "Jeremiah", "Иеремия", "Judah and Egypt", "Иуда и Египет", "647–580 BCE", "647–580 до н. э."),
    ("LAM", 25, -607, -607, 0, -607, -607, "Jeremiah", "Иеремия", "Near Jerusalem", "Близ Иерусалима", "607 BCE", "607 до н. э."),
    ("EZK", 26, -591, -591, 1, -613, -591, "Ezekiel", "Иезекииль", "Babylon", "Вавилон", "613 – c. 591 BCE", "613 — ок. 591 до н. э."),
    ("DAN", 27, -536, -536, 1, -618, -536, "Daniel", "Даниил", "Babylon", "Вавилон", "618 – c. 536 BCE", "618 — ок. 536 до н. э."),
    ("HOS", 28, -745, -740, 1, -804, -745, "Hosea", "Осия", "Samaria (district)", "Самария (область)", "Before 804 – after 745 BCE", "До 804 — после 745 до н. э."),
    ("JOL", 29, -820, -820, 1, -820, -820, "Joel", "Иоиль", "Judah", "Иуда", "c. 820 BCE (?)", "ок. 820 до н. э. (?)"),
    ("AMO", 30, -804, -804, 1, -804, -804, "Amos", "Амос", "Judah", "Иуда", "c. 804 BCE", "ок. 804 до н. э."),
    ("OBA", 31, -607, -607, 1, -607, -607, "Obadiah", "Авдий", "Judah", "Иуда", "c. 607 BCE", "ок. 607 до н. э."),
    ("JON", 32, -844, -844, 1, -844, -844, "Jonah", "Иона", "Israel", "Израиль", "c. 844 BCE", "ок. 844 до н. э."),
    ("MIC", 33, -717, -717, 1, -777, -717, "Micah", "Михей", "Judah", "Иуда", "c. 777–717 BCE", "ок. 777–717 до н. э."),
    ("NAM", 34, -632, -632, 1, -663, -632, "Nahum", "Наум", "Judah", "Иуда", "Before 632 BCE", "До 632 до н. э."),
    ("HAB", 35, -628, -628, 1, -628, -628, "Habakkuk", "Аввакум", "Judah", "Иуда", "c. 628 BCE (?)", "ок. 628 до н. э. (?)"),
    ("ZEP", 36, -648, -648, 1, -648, -648, "Zephaniah", "Софония", "Judah", "Иуда", "Before 648 BCE", "До 648 до н. э."),
    ("HAG", 37, -520, -520, 0, -520, -520, "Haggai", "Аггей", "Jerusalem", "Иерусалим", "112 days (520 BCE)", "112 дней (520 до н. э.)"),
    ("ZEC", 38, -518, -518, 0, -520, -518, "Zechariah", "Захария", "Jerusalem", "Иерусалим", "520–518 BCE", "520–518 до н. э."),
    ("MAL", 39, -443, -440, 1, -443, -440, "Malachi", "Малахия", "Jerusalem", "Иерусалим", "After 443 BCE", "После 443 до н. э."),
    # Новый Завет (CE)
    ("MAT", 40, 41, 41, 1, -2, 33, "Matthew", "Матфей", "Palestine", "Палестина", "2 BCE – 33 CE", "2 до н. э. — 33 н. э."),
    ("MRK", 41, 60, 65, 1, 29, 33, "Mark", "Марк", "Rome", "Рим", "29–33 CE", "29–33 н. э."),
    ("LUK", 42, 56, 58, 1, -3, 33, "Luke", "Лука", "Caesarea", "Кесария", "3 BCE – 33 CE", "3 до н. э. — 33 н. э."),
    ("JHN", 43, 98, 98, 1, 29, 33, "John", "Иоанн", "Ephesus or near", "Эфес или вблизи", "29–33 CE (after prologue)", "29–33 н. э. (кроме пролога)"),
    ("ACT", 44, 61, 61, 1, 33, 61, "Luke", "Лука", "Rome", "Рим", "33 – c. 61 CE", "33 — ок. 61 н. э."),
    ("ROM", 45, 56, 56, 1, 56, 56, "Paul", "Павел", "Corinth", "Коринф", "c. 56 CE", "ок. 56 н. э."),
    ("1CO", 46, 55, 55, 1, 55, 55, "Paul", "Павел", "Ephesus", "Эфес", "c. 55 CE", "ок. 55 н. э."),
    ("2CO", 47, 55, 55, 1, 55, 55, "Paul", "Павел", "Macedonia", "Македония", "c. 55 CE", "ок. 55 н. э."),
    ("GAL", 48, 50, 52, 1, 50, 52, "Paul", "Павел", "Corinth or Syrian Antioch", "Коринф или Антиохия Сирийская", "c. 50–52 CE", "ок. 50–52 н. э."),
    ("EPH", 49, 60, 61, 1, 60, 61, "Paul", "Павел", "Rome", "Рим", "c. 60–61 CE", "ок. 60–61 н. э."),
    ("PHP", 50, 60, 61, 1, 60, 61, "Paul", "Павел", "Rome", "Рим", "c. 60–61 CE", "ок. 60–61 н. э."),
    ("COL", 51, 60, 61, 1, 60, 61, "Paul", "Павел", "Rome", "Рим", "c. 60–61 CE", "ок. 60–61 н. э."),
    ("1TH", 52, 50, 50, 1, 50, 50, "Paul", "Павел", "Corinth", "Коринф", "c. 50 CE", "ок. 50 н. э."),
    ("2TH", 53, 51, 51, 1, 51, 51, "Paul", "Павел", "Corinth", "Коринф", "c. 51 CE", "ок. 51 н. э."),
    ("1TI", 54, 61, 64, 1, 61, 64, "Paul", "Павел", "Macedonia", "Македония", "c. 61–64 CE", "ок. 61–64 н. э."),
    ("2TI", 55, 65, 65, 1, 65, 65, "Paul", "Павел", "Rome", "Рим", "c. 65 CE", "ок. 65 н. э."),
    ("TIT", 56, 61, 64, 1, 61, 64, "Paul", "Павел", "Macedonia (?)", "Македония (?)", "c. 61–64 CE", "ок. 61–64 н. э."),
    ("PHM", 57, 60, 61, 1, 60, 61, "Paul", "Павел", "Rome", "Рим", "c. 60–61 CE", "ок. 60–61 н. э."),
    ("HEB", 58, 61, 61, 1, 61, 61, "Paul", "Павел", "Rome", "Рим", "c. 61 CE", "ок. 61 н. э."),
    ("JAS", 59, 60, 62, 1, 60, 62, "James", "Иаков", "Jerusalem", "Иерусалим", "Before 62 CE", "До 62 н. э."),
    ("1PE", 60, 62, 64, 1, 62, 64, "Peter", "Пётр", "Babylon", "Вавилон", "c. 62–64 CE", "ок. 62–64 н. э."),
    ("2PE", 61, 64, 64, 1, 64, 64, "Peter", "Пётр", "Babylon (?)", "Вавилон (?)", "c. 64 CE", "ок. 64 н. э."),
    ("1JN", 62, 98, 98, 1, 98, 98, "John", "Иоанн", "Ephesus or near", "Эфес или вблизи", "c. 98 CE", "ок. 98 н. э."),
    ("2JN", 63, 98, 98, 1, 98, 98, "John", "Иоанн", "Ephesus or near", "Эфес или вблизи", "c. 98 CE", "ок. 98 н. э."),
    ("3JN", 64, 98, 98, 1, 98, 98, "John", "Иоанн", "Ephesus or near", "Эфес или вблизи", "c. 98 CE", "ок. 98 н. э."),
    ("JUD", 65, 65, 65, 1, 65, 65, "Jude", "Иуда", "Palestine (?)", "Палестина (?)", "c. 65 CE", "ок. 65 н. э."),
    ("REV", 66, 96, 96, 1, 96, 96, "John", "Иоанн", "Patmos", "Патмос", "c. 96 CE", "ок. 96 н. э."),
]

TYPE_RU_MAP: dict[str, str] = {
    "person": "Человек",
    "place": "Место",
    "group": "Группа / народ",
    "deity": "Сверхъестественное существо / божество",
    "creature": "Животное",
    "plant": "Растение",
    "object": "Предмет / реалия",
    "concept": "Библейское понятие",
}

ROLE_RU_MAP: dict[str, str] = {
    "King": "царь",
    "Queen": "царица",
    "Prophet": "пророк",
    "Prophetess": "пророчица",
    "Priest": "священник",
    "High Priest": "первосвященник",
    "Levite": "левит",
    "Judge": "судья",
    "Apostle": "апостол",
    "Disciple": "ученик",
    "Warrior": "воин",
    "Military Leader": "военачальник",
    "Ruler": "правитель",
    "Governor": "областной правитель",
    "Patriarch": "патриарх",
    "Matriarch": "матриарх",
    "Musician": "музыкант, певец",
    "Scribe": "книжник, переписчик",
    "Shepherd": "пастух",
    "Servant": "слуга",
    "Official": "царский приближённый",
    "Wise Person": "мудрец",
    "Craftsman": "мастер, ремесленник",
}


def load_door43_tw_full() -> tuple[dict[str, dict], dict[str, list[dict]]]:
    """Читает 1 018 русских статей Door43 ru_tw.zip (CC BY-SA 4.0).
    Возвращает:
      by_slug: {slug: {'title': ..., 'short': ..., 'body': ..., 'strongs': [...]}}
      by_strong: {classic_code: [rec, ...]}
    """
    by_slug: dict[str, dict] = {}
    by_strong: dict[str, list[dict]] = collections.defaultdict(list)
    zp = DATA / "sources" / "strongs" / "door43-ru" / "ru_tw.zip"
    if not zp.exists():
        return by_slug, by_strong
    with zipfile.ZipFile(zp) as z:
        for n in sorted(z.namelist()):
            if not n.endswith(".md") or "/bible/" not in n:
                continue
            slug = os.path.splitext(os.path.basename(n))[0].lower().replace("-", "").replace("_", "")
            txt = z.read(n).decode("utf-8", "ignore")
            lines = [ln.strip() for ln in txt.splitlines() if ln.strip()]
            if not lines or not lines[0].startswith("#"):
                continue
            raw_title = lines[0].lstrip("#").strip()
            clean_title = re.split(r"[,;]", raw_title)[0].strip()
            m_def = re.search(
                r"##\s*(?:Определение|Факты)\s*:?\s*(.*?)(?=##\s*Ссылки|##\s*Данные|\Z)",
                txt,
                re.S,
            )
            body = m_def.group(1).strip() if m_def else ""
            body = re.sub(r"\(См\.\s*также:.*?\)", "", body, flags=re.S).strip()
            body = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", body)
            # Первое предложение или первый абзац для краткого описания
            first_para = ""
            for p in body.splitlines():
                p_clean = p.lstrip("*•- ").strip()
                if len(p_clean) >= 15:
                    first_para = p_clean
                    break
            m_st = re.search(r"Номера Стронга\s*:\s*([^\n]+)", txt)
            st_codes = []
            if m_st:
                for rc in re.findall(r"[HG]\d+", m_st.group(1)):
                    cl = norm_classic(rc)
                    if cl:
                        st_codes.append(cl)
            rec = {
                "slug": slug,
                "title": clean_title,
                "raw_title": raw_title,
                "short": first_para[:320],
                "body": f"# {raw_title}\n\n{body}"[:20000],
                "strongs": st_codes,
            }
            by_slug[slug] = rec
            for cl in st_codes:
                by_strong[cl].append(rec)
    return by_slug, by_strong


def collect_rob_capitalized_names() -> dict[str, collections.Counter]:
    """Собирает имена собственные с заглавной буквы из полного 66-книжного модуля ru_rob.sb."""
    rob_sb = DATA / "modules" / "ru_rob.sb"
    rob_lay = DATA / "work" / "strongs" / "layers" / "ru_rob-strongs.sb"
    if not rob_sb.exists() or not rob_lay.exists():
        return {}
    _, verses = tokenize_module(rob_sb)
    word_by_coord: dict[tuple[int, int, int, int], str] = {}
    for (bid, ch, v), (ws, _) in verses.items():
        for idx, w in enumerate(ws):
            if idx > 0 and len(w) >= 3 and w[0].isupper() and w.lower() not in AUX_RU_WORDS:
                word_by_coord[(bid, ch, v, idx)] = w
    lay_db = sqlite3.connect(rob_lay)
    out: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for bid, ch, v, w_idx, st_s, conf in lay_db.execute(
        "SELECT book_id, chapter, verse, word, strong, conf FROM links WHERE strong != '' AND conf >= 8"
    ):
        w = word_by_coord.get((bid, ch, v, w_idx))
        if not w:
            continue
        for d in st_s.split():
            if d.startswith("H9") or d in ("H0853", "G3588"):
                continue
            out[d][w] += 1
            cl = norm_classic(d)
            if cl:
                out[cl][w] += 1
    lay_db.close()
    return out


def pick_nominative_ru(ctr: collections.Counter) -> str | None:
    if not ctr:
        return None
    top = ctr.most_common(6)
    candidates = [w for w, c in top if c >= max(1, top[0][1] // 4)]
    obl_endings = ("ом", "ем", "ою", "ею", "ам", "ям", "ами", "ями", "ах", "ях", "ов", "ев", "ому", "ему", "ого", "его")
    clean = [w for w in candidates if not w.lower().endswith(obl_endings)]
    chosen = clean[0] if clean else candidates[0]
    return OBLIQUE_TO_NOMINATIVE.get(chosen, chosen)


def translate_pattern_name(eid: str, en_name: str, base_ru_by_slug: dict[str, str]) -> str | None:
    """Переводит структурные описания имён ACAI ('Wife of X', 'Daughter of X', 'Father of X' и т.д.)."""
    if eid in EXPLICIT_RU_NAMES:
        return EXPLICIT_RU_NAMES[eid]
    patterns = [
        (r"^(?:A\s+)?Wife of\s+([A-Za-z0-9-]+)", "Жена"),
        (r"^([A-Za-z0-9-]+)'s Wife$", "Жена"),
        (r"^Daughter\s*\d*\s+of\s+([A-Za-z0-9-]+)", "Дочь"),
        (r"^Father-in-Law of\s+([A-Za-z0-9-]+)", "Тесть"),
        (r"^Father of\s+([A-Za-z0-9-]+)", "Отец"),
        (r"^Mother-in-law of\s+([A-Za-z0-9-]+)", "Тёща"),
        (r"^([A-Za-z0-9-]+)'s Mother-in-law$", "Тёща"),
        (r"^Mother of\s+([A-Za-z0-9-]+)", "Мать"),
        (r"^([A-Za-z0-9-]+)'s Mother$", "Мать"),
        (r"^Husband of\s+([A-Za-z0-9-]+)", "Муж"),
        (r"^Son of\s+([A-Za-z0-9-]+)", "Сын"),
        (r"^Sister of\s+([A-Za-z0-9-]+)", "Сестра"),
        (r"^King of\s+([A-Za-z0-9-]+)", "Царь"),
        (r"^Queen of\s+([A-Za-z0-9-]+)", "Царица"),
        (r"^People (?:of|From)\s+([A-Za-z0-9-]+)", "Жители"),
    ]
    clean_en = en_name.split("(")[0].strip()
    for pat, prefix_ru in patterns:
        m = re.match(pat, clean_en, flags=re.I)
        if m:
            target_slug = m.group(1).lower().replace("-", "")
            target_ru = base_ru_by_slug.get(target_slug, m.group(1))
            return f"{prefix_ru} ({target_ru})"
    return None


def generate_ru_short_description(
    eid: str,
    typ: str,
    sub: str,
    ru_name: str,
    en_name: str,
    en_desc: str,
    meta: dict,
    rels_by_from: dict[str, list[tuple[str, str, str]]],
    ru_name_by_id: dict[str, str],
    tw_short: str,
) -> str:
    """Формирует точное русское краткое описание `short_description_ru` из открытых
    структурированных полей ACAI (`roles`, `relationships`, `type`, `key_references`)
    и открытых статей `Door43 ru_tw` / `Aquifer Russian`.
    """
    if eid in MEASURE_METRIC_RU:
        return MEASURE_METRIC_RU[eid]
    # 1. Если есть готовое определение из открытой статьи Door43 ru_tw (для понятий, реалий, основных героев)
    if tw_short and typ in ("concept", "object", "plant", "creature", "group"):
        return tw_short

    # 2. Для людей — собираем паспортное описание: пол/роль + чьи родители/супруги/дети + колено + первая ссылка
    if typ == "person":
        roles_en = meta.get("roles") or []
        roles_ru = [ROLE_RU_MAP.get(r, "") for r in roles_en if ROLE_RU_MAP.get(r)]
        gender = meta.get("gender")
        lead = ", ".join(roles_ru) if roles_ru else ("библейский персонаж" if gender != "female" else "библейская женщина")
        lead = lead[0].upper() + lead[1:]

        kin_parts = []
        rels = rels_by_from.get(eid, [])
        fathers = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "father"]
        mothers = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "mother"]
        partners = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "partner"]
        offspring = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "offspring"]
        tribes = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "member_of"]

        if fathers:
            kin_parts.append(f"отец: {', '.join(fathers[:2])}")
        if mothers:
            kin_parts.append(f"мать: {', '.join(mothers[:2])}")
        if partners:
            kin_parts.append(f"супруг(а): {', '.join(partners[:2])}")
        if offspring:
            kin_parts.append(f"дети: {', '.join(offspring[:3])}")
        if tribes:
            kin_parts.append(f"род/группа: {', '.join(tribes[:2])}")

        refs = meta.get("key_references") or []
        body = f"{lead}."
        if kin_parts:
            body += " " + "; ".join(kin_parts) + "."
        if tw_short and len(body) < 80:
            body += " " + tw_short
        return body

    # 3. Для географических мест (`place`)
    if typ == "place":
        pt_map = {
            "settlement": "поселение / город",
            "city": "город",
            "region": "историческая область",
            "mountain": "гора / возвышенность",
            "mountain range": "горный хребет",
            "river": "река / поток",
            "wadi": "долина / поток (вади)",
            "valley": "долина",
            "body of water": "водоём / море",
            "island": "остров",
            "spring": "источник / колодец",
            "well": "колодец",
            "structure": "сооружение / ворота",
            "gate": "городские ворота",
            "desert": "пустыня",
        }
        kind_ru = pt_map.get(sub.lower(), "географическое место")
        kind_ru = kind_ru[0].upper() + kind_ru[1:]
        rels = rels_by_from.get(eid, [])
        regions = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt in ("subregion_of", "tribal_area")]
        nearby = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "nearby"]
        parts = [f"{kind_ru} библейского мира."]
        if regions:
            parts.append(f"Область/удел: {', '.join(regions[:2])}.")
        if nearby:
            parts.append(f"Рядом: {', '.join(nearby[:3])}.")
        if "lat" in meta and "lon" in meta:
            parts.append(f"Координаты: {meta['lat']:.3f}°, {meta['lon']:.3f}°.")
        return " ".join(parts)

    # 4. Для остальных категорий (group, deity, creature, plant, object, concept)
    cat_ru = TYPE_RU_MAP.get(typ, "Библейская сущность")
    rels = rels_by_from.get(eid, [])
    orig_p = [ru_name_by_id.get(tid, tname) for rt, tid, tname in rels if rt == "origin_person"]
    extra = f" Родоначальник: {', '.join(orig_p[:2])}." if orig_p else ""
    if tw_short:
        return f"{cat_ru}. {tw_short}{extra}"
    return f"{cat_ru}: {ru_name} ({en_name}).{extra}"


def build_curated_visual_aids() -> list[tuple]:
    """Создаёт базовый набор наглядных пособий `visual_aids` (ADR 0024 §§10–13):
    временны́е шкалы с «гармошкой» (`timeline`), таблицы межкнижных связей (`chart`)
    и генеалогические древа (`genealogy`).
    """
    return [
        (
            "1A",
            1,
            "A",
            "genealogy",
            "Lineage of the Patriarchs (Terah to the 12 Tribes)",
            "Родословное древо патриархов (от Фарры до 12 колен Израиля)",
            "Genesis 11–35",
            "Бытие, главы 11–35",
            json.dumps(
                {
                    "primary_nodes": ["person:Terah", "person:Abraham", "person:Sarah", "person:Isaac", "person:Rebekah", "person:Jacob"],
                    "secondary_nodes": ["person:Nahor.2", "person:Haran", "person:Lot", "person:Hagar", "person:Ishmael", "person:Esau", "person:Leah", "person:Rachel"],
                    "marriages": [
                        {"spouses": ["person:Abraham", "person:Sarah"], "children": ["person:Isaac"]},
                        {"spouses": ["person:Abraham", "person:Hagar"], "children": ["person:Ishmael"]},
                        {"spouses": ["person:Isaac", "person:Rebekah"], "children": ["person:Esau", "person:Jacob"]},
                    ],
                },
                ensure_ascii=False,
            ),
            "person:Abraham",
            "GEN",
            11,
            27,
            "ACAI+STEPBible",
            "CC BY-SA 4.0",
        ),
        (
            "1B",
            1,
            "B",
            "chart",
            "Connections Between Genesis and the Rest of the Canon",
            "Связь книги Бытие с другими книгами Библии",
            "Creation, Abrahamic Covenant, and Messianic Promises",
            "Сотворение, завет с Авраамом и мессианские обетования",
            json.dumps(
                {
                    "rows": [
                        {"src": "GEN.1.1", "kind": "quote", "targets": ["JHN.1.1", "HEB.11.3", "REV.4.11"], "note_ru": "Сотворение неба и земли Словом Бога", "note_en": "Creation of heaven and earth by God's Word"},
                        {"src": "GEN.2.24", "kind": "quote", "targets": ["MAT.19.5", "MRK.10.7", "EPH.5.31"], "note_ru": "Основание брака: «станут одной плотью»", "note_en": "Foundation of marriage: 'one flesh'"},
                        {"src": "GEN.3.15", "kind": "prophecy", "targets": ["ROM.16.20", "GAL.4.4", "REV.12.9", "REV.20.2"], "note_ru": "Первое пророчество о Потомке, сокрушающем змея", "note_en": "First prophecy of the Offspring crushing the serpent"},
                        {"src": "GEN.12.3", "kind": "prophecy", "targets": ["ACT.3.25", "GAL.3.8"], "note_ru": "Благословение всех народов через потомство Авраама", "note_en": "Blessing of all nations through Abraham's seed"},
                        {"src": "GEN.14.18", "kind": "parallel", "targets": ["PSA.110.4", "HEB.7.1"], "note_ru": "Царь и священник Мелхиседек — прообраз Христа", "note_en": "King-priest Melchizedek as type of Christ"},
                        {"src": "GEN.15.6", "kind": "quote", "targets": ["ROM.4.3", "GAL.3.6", "JAS.2.23"], "note_ru": "Вера Авраама вменилась ему в праведность", "note_en": "Abraham's faith credited as righteousness"},
                        {"src": "GEN.49.10", "kind": "prophecy", "targets": ["EZK.21.27", "LUK.1.32", "REV.5.5"], "note_ru": "Царский скипетр в колене Иуды (Примиритель / Шило)", "note_en": "Royal scepter in the tribe of Judah (Shiloh)"},
                    ]
                },
                ensure_ascii=False,
            ),
            "",
            "GEN",
            1,
            1,
            "OpenCrossRefs+STEPBible",
            "CC BY-SA 4.0",
        ),
        (
            "19A",
            19,
            "A",
            "timeline",
            "Timeline of the Composition of the Psalms",
            "Временна́я шкала написания Псалтири (с «гармошкой» периодов)",
            "From Moses (Psalm 90) to the Post-Exilic Collection",
            "От Моисея (Псалом 90/89) до послепленного собрания",
            json.dumps(
                {
                    "segments": [
                        {"from": -1513, "to": -1473},
                        {"break": "compressed", "from": -1473, "to": -1077},
                        {"from": -1077, "to": -997},
                        {"break": "compressed", "from": -997, "to": -732},
                        {"from": -732, "to": -701},
                        {"break": "compressed", "from": -701, "to": -537},
                        {"from": -537, "to": -460},
                    ],
                    "events": [
                        {"years": [-1513, -1473], "tier": 1, "title_ru": "Молитва Моисея в пустыне", "title_en": "Prayer of Moses in the Wilderness", "refs": ["PSA.90.0"]},
                        {"years": [-1077, -1015], "tier": 2, "title_ru": "Псалмы Давида и левитов (Асаф, сыновья Корея)", "title_en": "Psalms of David and Levitical Singers", "refs": ["PSA.3.0", "PSA.50.0", "PSA.42.0"]},
                        {"years": [-1015, -997], "tier": 1, "title_ru": "Псалмы Соломона", "title_en": "Psalms of Solomon", "refs": ["PSA.72.0", "PSA.127.0"]},
                        {"years": [-715, -701], "tier": 1, "title_ru": "Собрание псалмов при царе Езекии", "title_en": "Hezekiah's Liturgical Collection", "refs": ["2CH.29.30"]},
                        {"years": [-537, -460], "tier": 2, "title_ru": "Возвращение из Вавилона и завершение 5 книг Псалтири", "title_en": "Return from Exile & Final Compilation", "refs": ["PSA.126.1", "PSA.137.1"]},
                    ],
                },
                ensure_ascii=False,
            ),
            "person:David",
            "PSA",
            1,
            1,
            "STEPBible+ACAI",
            "CC BY-SA 4.0",
        ),
        (
            "35A",
            35,
            "A",
            "timeline",
            "Timeline of Habakkuk and the Rise of Babylon",
            "Временна́я шкала книги Аввакума и возвышения Вавилона",
            "Judah Before the Chaldean Invasion",
            "Иудея накануне нашествия халдеев",
            json.dumps(
                {
                    "segments": [
                        {"from": -659, "to": -625},
                        {"break": "compressed", "from": -625, "to": -607},
                    ],
                    "events": [
                        {"years": [-659, -629], "tier": 1, "title_ru": "Правление царя Иосии в Иудее", "title_en": "Reign of King Josiah in Judah", "refs": ["2KI.22.1"]},
                        {"years": [-632], "tier": 2, "title_ru": "Падение Ниневии перед вавилонянами и мидянами", "title_en": "Fall of Nineveh to Babylonians and Medes", "refs": ["NAM.3.7"]},
                        {"years": [-628], "tier": 2, "title_ru": "Запись пророчества Аввакума в Иудее", "title_en": "Habakkuk Writes His Prophecy in Judah", "refs": ["HAB.1.1", "HAB.2.4"]},
                        {"years": [-625], "tier": 1, "title_ru": "Победа Навуходоносора при Кархемисе", "title_en": "Nebuchadnezzar Defeats Pharaoh Necho at Carchemish", "refs": ["JER.46.2"]},
                    ],
                },
                ensure_ascii=False,
            ),
            "person:Habakkuk",
            "HAB",
            1,
            1,
            "STEPBible+ACAI",
            "CC BY-SA 4.0",
        ),
        (
            "35B",
            35,
            "B",
            "chart",
            "Connections Between Habakkuk and Other Books of the Bible",
            "Связь книги Аввакума с другими книгами Библии",
            "Quotations and Parallels in the Old and New Testaments",
            "Цитаты и параллели в Ветхом и Новом Заветах",
            json.dumps(
                {
                    "rows": [
                        {"src": "HAB.1.5", "kind": "quote", "targets": ["ACT.13.40", "ACT.13.41"], "note_ru": "Апостол Павел цитирует предостережение неверующим", "note_en": "Paul quotes Habakkuk's warning in Pisidian Antioch"},
                        {"src": "HAB.2.4", "kind": "quote", "targets": ["ROM.1.17", "GAL.3.11", "HEB.10.38"], "note_ru": "«Праведный своей верой жив будет»", "note_en": "'The righteous will live by his faith'"},
                        {"src": "HAB.2.14", "kind": "parallel", "targets": ["ISA.11.9"], "note_ru": "Земля наполнится познанием славы Господа", "note_en": "The earth will be filled with the knowledge of the Lord's glory"},
                        {"src": "HAB.2.20", "kind": "parallel", "targets": ["ZEP.1.7", "ZEC.2.13"], "note_ru": "Благоговейное молчание всей земли перед Господом в Его святом храме", "note_en": "All the earth silent before the Lord in His holy temple"},
                        {"src": "HAB.3.19", "kind": "parallel", "targets": ["2SA.22.34", "PSA.18.33"], "note_ru": "Бог делает ноги праведника быстрыми, как у оленя, на высотах", "note_en": "God makes the feet like the feet of a deer on the heights"},
                    ]
                },
                ensure_ascii=False,
            ),
            "person:Habakkuk",
            "HAB",
            1,
            1,
            "OpenCrossRefs+STEPBible",
            "CC BY-SA 4.0",
        ),
    ]


def populate_media_table(db: sqlite3.Connection) -> tuple[int, int]:
    """Индексирует открытые иллюстрации и фото из `openbible-geocoding/data/image.jsonl`
    (для `place`) и `ubs-fauna` / `ubs-flora` / `ubs-realia` (для `creature`, `plant`, `object`).
    Возвращает `(entities_with_media, total_media_rows)`.
    """
    ob_dir = DATA / "sources" / "strongs" / "openbible-geocoding" / "data"
    imgs: dict[str, dict] = {}
    if (ob_dir / "image.jsonl").exists():
        for line in (ob_dir / "image.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            imgs[r["id"]] = r

    mod_media: dict[str, dict] = {}
    if (ob_dir / "modern.jsonl").exists():
        for line in (ob_dir / "modern.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            th = (r.get("media") or {}).get("thumbnail")
            if th and th.get("image_id") in imgs:
                mod_media[r["id"]] = th

    anc_imgs: dict[str, list[dict]] = {}
    if (ob_dir / "ancient.jsonl").exists():
        for line in (ob_dir / "ancient.jsonl").read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            im_list: list[dict] = []
            th = (r.get("media") or {}).get("thumbnail")
            if th and th.get("image_id") in imgs:
                im_list.append(th)
            for wid in r.get("modern_associations") or {}:
                if wid in mod_media and mod_media[wid]["image_id"] not in [x["image_id"] for x in im_list]:
                    im_list.append(mod_media[wid])
            if im_list:
                anc_imgs[r["id"]] = im_list
                anc_imgs[(r.get("friendly_id") or "").lower()] = im_list

    ubs_imgs: dict[str, list[tuple[str, str]]] = {}
    for d in ("ubs-fauna", "ubs-flora", "ubs-realia"):
        zp = DATA / "sources" / "strongs" / d / "English-md.zip"
        if not zp.exists():
            continue
        with zipfile.ZipFile(zp) as z:
            for n in z.namelist():
                if not n.endswith(".md"):
                    continue
                txt = z.read(n).decode("utf-8")
                for part in re.split(r"(?=^#{1,4}\s+.*?\(id:\s*[A-Za-z]+:[\d.]+\))", txt, flags=re.M):
                    m = re.match(r"^#{1,4}\s+(.*?)\s*\(id:\s*([A-Za-z]+:[\d.]+)\)", part)
                    if m:
                        uid = m.group(2).lower()
                        ilinks = re.findall(r"!\[([^\]]*)\]\(([^)]+)\)", part)
                        if ilinks:
                            ubs_imgs[uid] = ilinks

    db.execute("DELETE FROM media")
    media_rows: list[tuple] = []
    ent_img_updates: list[tuple[str, str]] = []
    media_id = 1
    ent_with_media = 0

    for eid, typ, name, meta_s in db.execute("SELECT id, type, name, metadata FROM entities"):
        meta = json.loads(meta_s) if meta_s else {}
        alt = meta.get("alternate_sources") or {}
        found_rows: list[tuple[str, str, str]] = []

        if typ == "place":
            for oid in alt.get("openbible") or []:
                for th in anc_imgs.get(oid, []):
                    im_rec = imgs.get(th["image_id"], {})
                    url = im_rec.get("file_url") or th.get("file") or ""
                    cap = re.sub(r"<[^>]+>", "", th.get("description") or "")
                    lic = im_rec.get("license") or "CC-BY-SA"
                    author = th.get("credit") or im_rec.get("author") or ""
                    full_cap = f"{cap} ({author}, {lic})".strip(" ()")
                    if url and url not in [r[1] for r in found_rows]:
                        found_rows.append(("photo", url, full_cap))
            if not found_rows:
                k1 = name.lower().split("(")[0].strip()
                for th in anc_imgs.get(k1, []):
                    im_rec = imgs.get(th["image_id"], {})
                    url = im_rec.get("file_url") or th.get("file") or ""
                    cap = re.sub(r"<[^>]+>", "", th.get("description") or "")
                    lic = im_rec.get("license") or "CC-BY-SA"
                    author = th.get("credit") or im_rec.get("author") or ""
                    full_cap = f"{cap} ({author}, {lic})".strip(" ()")
                    if url and url not in [r[1] for r in found_rows]:
                        found_rows.append(("photo", url, full_cap))

        elif typ in ("creature", "plant", "object"):
            for k in ("ubsfauna", "ubsflora", "ubsrealia"):
                for uid in alt.get(k) or []:
                    u = uid.lower()
                    for cap, rel in ubs_imgs.get(u) or ubs_imgs.get(".".join(u.split(".")[:2])) or []:
                        clean_rel = rel.replace("../json/images/", "ubs-images/")
                        if clean_rel not in [r[1] for r in found_rows]:
                            found_rows.append(("illustration", clean_rel, f"{cap} (UBS, CC BY-SA 4.0)"))

        if found_rows:
            ent_with_media += 1
            ent_img_updates.append((found_rows[0][1], eid))
            for ord_idx, (mtype, rpath, cap) in enumerate(found_rows):
                media_rows.append((media_id, eid, mtype, rpath, cap, ord_idx))
                media_id += 1

    db.executemany("INSERT INTO media VALUES (?,?,?,?,?,?)", media_rows)
    db.executemany("UPDATE entities SET image_path=? WHERE id=?", ent_img_updates)
    return ent_with_media, len(media_rows)


def main() -> None:
    db = sqlite3.connect(KNOW_SB)
    sru = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step-ru.sb")
    sen = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb")

    # 1. Загружаем глоссы из strongs-step-ru.sb и strongs-step.sb
    sru_gloss: dict[str, str] = {}
    for key, _base, gloss in sru.execute("SELECT key, base, gloss FROM lex WHERE gloss != ''"):
        g = re.sub(r"\s*\(в Син\.:.*?\)", "", gloss).strip()
        g = re.split(r"[;,]", g)[0].strip()
        if g and not re.search(r"[A-Za-z]", g):
            sru_gloss[key] = g
            cl = norm_classic(key)
            if cl and cl not in sru_gloss:
                sru_gloss[cl] = g

    en_to_ru_gloss: dict[str, str] = {}
    for key, en_g in sen.execute("SELECT key, gloss FROM lex WHERE gloss != ''"):
        if key in sru_gloss:
            for part in re.split(r"[;,/]", en_g.lower()):
                p = re.sub(r"^to\s+", "", part.strip())
                if len(p) >= 3 and p not in en_to_ru_gloss:
                    en_to_ru_gloss[p] = sru_gloss[key]

    # 2. Загружаем 1 018 открытых русских статей Door43 ru_tw (CC BY-SA 4.0)
    tw_by_slug, tw_by_strong = load_door43_tw_full()
    rob_names = collect_rob_capitalized_names()

    # Загружаем выверенные в ОЗУ русские значения имён (`meaning_ru`), ударения (`accent_ru`)
    # и именительные формы (`nom_ru`), а также английские значения имён из TIPNR (`lex-name.json`).
    etym_acc_path = DATA / "work" / "strongs" / "knowledge" / "ru_etym_and_accents.json"
    etym_acc_map: dict[str, dict] = (
        json.loads(etym_acc_path.read_text(encoding="utf-8")) if etym_acc_path.exists() else {}
    )
    tipnr_gloss_by_eid: dict[str, str] = {}
    lex_name_path = DATA / "work" / "strongs" / "lex-name.json"
    if lex_name_path.exists():
        for _k, v in json.loads(lex_name_path.read_text(encoding="utf-8")).items():
            if v.get("gloss") and v.get("name") and v.get("ref"):
                tipnr_gloss_by_eid[f"{v['name'].lower()}@{v['ref']}"] = v["gloss"]

    # 3. Исправляем косвенные падежи в существующих русских именах `entity_names`
    cur_ru_rows = db.execute(
        "SELECT rowid, entity_id, name, lang, kind FROM entity_names WHERE lang IN ('ru', 'rus')"
    ).fetchall()
    fixed_oblique = 0
    for rowid, eid, nm, lang, kind in cur_ru_rows:
        clean_nm = nm.strip()
        if clean_nm in OBLIQUE_TO_NOMINATIVE:
            new_nm = OBLIQUE_TO_NOMINATIVE[clean_nm]
            db.execute("UPDATE entity_names SET name=? WHERE rowid=?", (new_nm, rowid))
            fixed_oblique += 1
        elif clean_nm != nm:
            db.execute("UPDATE entity_names SET name=? WHERE rowid=?", (clean_nm, rowid))

    # 4. Собираем текущие русские имена по сущностям и базовым омонимам
    ru_by_id: dict[str, list[str]] = collections.defaultdict(list)
    base_ru_by_id: dict[str, str] = {}
    base_ru_by_slug: dict[str, str] = {}

    for eid, nm, kind in db.execute(
        """
        SELECT entity_id, name, kind FROM entity_names
        WHERE lang IN ('ru', 'rus')
        ORDER BY CASE kind WHEN 'canonical' THEN 0 WHEN 'biblical' THEN 1 WHEN 'synodal' THEN 2 ELSE 3 END
        """
    ):
        if nm not in ru_by_id[eid]:
            ru_by_id[eid].append(nm)
        b_id = eid.split(".")[0]
        if b_id not in base_ru_by_id:
            base_ru_by_id[b_id] = nm
        slug = b_id.split(":")[-1].lower().replace("-", "")
        if slug not in base_ru_by_slug:
            base_ru_by_slug[slug] = nm

    # 5. Доводим покрытие русских имён до 100 % всех 5 700 сущностей и ставим именительную форму первой (`kind='canonical'`)
    added_names: list[tuple[str, str, str, str]] = []
    canon_existing = set(
        db.execute("SELECT entity_id, LOWER(name) FROM entity_names WHERE lang='ru' AND kind='canonical'").fetchall()
    )
    canon_eids = {e for e, _n in canon_existing}
    for eid, typ, en_name, strongs in db.execute("SELECT id, type, name, strongs FROM entities"):
        ea_rec = (
            (etym_acc_map.get(eid) or etym_acc_map.get(eid.split(".")[0]) or {})
            if typ in ("person", "place", "deity", "group")
            else {}
        )
        nom_ru = EXPLICIT_RU_NAMES.get(eid) or ea_rec.get("nom_ru")
        if nom_ru:
            if (eid, nom_ru.lower()) not in canon_existing:
                added_names.append((eid, nom_ru, "ru", "canonical"))
                canon_existing.add((eid, nom_ru.lower()))
                canon_eids.add(eid)
            if nom_ru in ru_by_id[eid]:
                ru_by_id[eid].remove(nom_ru)
            ru_by_id[eid].insert(0, nom_ru)

        # Дополнительная форма из 66-книжного ru_rob-strongs.sb (только для имён собственных!)
        codes = re.findall(r"[HG]\d+[A-Za-z]?", strongs)
        if typ in ("person", "place", "deity", "group"):
            rob_ctr: collections.Counter = collections.Counter()
            for c in codes:
                cl = norm_classic(c) or c
                rob_ctr.update(rob_names.get(c, {}))
                rob_ctr.update(rob_names.get(cl, {}))
            rob_form = pick_nominative_ru(rob_ctr)
            if rob_form and rob_form.lower() not in [x.lower() for x in ru_by_id.get(eid, [])]:
                added_names.append((eid, rob_form, "ru", "biblical"))
                ru_by_id[eid].append(rob_form)

        if ru_by_id.get(eid) and eid in canon_eids:
            continue

        found_ru: str | None = EXPLICIT_RU_NAMES.get(eid)
        if not found_ru:
            for c in codes:
                cl = norm_classic(c) or c
                found_ru = sru_gloss.get(c) or sru_gloss.get(cl)
                if found_ru:
                    break
        if not found_ru:
            b_id = eid.split(".")[0]
            found_ru = base_ru_by_id.get(b_id)
        if not found_ru:
            slug = eid.split(":")[-1].split(".")[0].lower().replace("-", "").replace("_", "")
            if slug in tw_by_slug:
                found_ru = tw_by_slug[slug]["title"]
        if not found_ru:
            clean_en = en_name.lower().split("(")[0].strip()
            found_ru = en_to_ru_gloss.get(clean_en)
            if not found_ru:
                c_slug = clean_en.replace(" ", "").replace("-", "")
                if c_slug in tw_by_slug:
                    found_ru = tw_by_slug[c_slug]["title"]
        if not found_ru:
            found_ru = translate_pattern_name(eid, en_name, base_ru_by_slug)
        if not found_ru:
            found_ru = en_name

        if typ in ("person", "place", "deity", "group") and found_ru and found_ru[0].islower():
            found_ru = found_ru[0].upper() + found_ru[1:]

        added_names.append((eid, found_ru, "ru", "canonical"))
        canon_eids.add(eid)
        canon_existing.add((eid, found_ru.lower()))
        ru_by_id[eid].append(found_ru)
        b_id = eid.split(".")[0]
        base_ru_by_id.setdefault(b_id, found_ru)
        base_ru_by_slug.setdefault(b_id.split(":")[-1].lower().replace("-", ""), found_ru)

    if added_names:
        db.executemany("INSERT INTO entity_names VALUES (?,?,?,?)", added_names)

    # 6. Замыкаем обратные родственные связи (`relationships`)
    existing_rels = set(
        db.execute("SELECT from_entity_id, to_entity_id, relation_type FROM relationships").fetchall()
    )
    max_rel_id = db.execute("SELECT COALESCE(MAX(id), 0) FROM relationships").fetchone()[0]
    new_rels: list[tuple] = []
    for f_id, t_id, rt in sorted(existing_rels):
        inv_rt = (
            "offspring"
            if rt in ("father", "mother")
            else "partner"
            if rt == "partner"
            else "sibling"
            if rt == "sibling"
            else None
        )
        if inv_rt and (t_id, f_id, inv_rt) not in existing_rels:
            max_rel_id += 1
            existing_rels.add((t_id, f_id, inv_rt))
            new_rels.append((max_rel_id, t_id, f_id, inv_rt, None, None, None, None, "", None, "ACAI-inverse"))
    if new_rels:
        db.executemany(
            "INSERT INTO relationships(id,from_entity_id,to_entity_id,relation_type,book,chapter,verse,seg,description,weight,source) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            new_rels,
        )

    # 7. Готовим индекс связей и русских имён для генерации `short_description_ru` и присоединения `Door43 ru_tw`
    primary_ru_by_id = {eid: nms[0] for eid, nms in ru_by_id.items() if nms}
    rels_by_from: dict[str, list[tuple[str, str, str]]] = collections.defaultdict(list)
    for f_id, rt, t_id, t_en in db.execute(
        "SELECT r.from_entity_id, r.relation_type, r.to_entity_id, e.name FROM relationships r JOIN entities e ON e.id = r.to_entity_id"
    ):
        rels_by_from[f_id].append((rt, t_id, t_en))

    tw_joined = 0
    ru_desc_count = 0
    meaning_ru_count = 0
    accent_ru_count = 0
    ent_updates: list[tuple[str, str, str]] = []

    for eid, typ, sub, en_name, strongs, en_desc, art, meta_s in db.execute(
        "SELECT id, type, subtype, name, strongs, short_description, article, metadata FROM entities"
    ):
        meta = json.loads(meta_s) if meta_s else {}
        ea_rec = (
            (etym_acc_map.get(eid) or etym_acc_map.get(eid.split(".")[0]) or {})
            if typ in ("person", "place", "deity", "group")
            else {}
        )
        if ea_rec.get("meaning_ru"):
            meta["name_meaning_ru"] = ea_rec["meaning_ru"]
            meaning_ru_count += 1
        if ea_rec.get("accent_ru"):
            meta["name_accented_ru"] = ea_rec["accent_ru"]
            accent_ru_count += 1
        # Английское значение имени из TIPNR
        for t_eid in (meta.get("alternate_sources") or {}).get("tipnr") or []:
            base_te = t_eid.split("|")[-1].split("-")[0].lower()
            if base_te in tipnr_gloss_by_eid:
                meta["name_meaning_en"] = tipnr_gloss_by_eid[base_te]
                break

        slug = eid.split(":")[-1].split(".")[0].lower().replace("-", "").replace("_", "")
        en_slug = en_name.lower().split("(")[0].strip().replace(" ", "").replace("-", "")
        tw_rec = tw_by_slug.get(slug) or tw_by_slug.get(en_slug)
        if not tw_rec:
            for c in re.findall(r"[HG]\d+[A-Za-z]?", strongs):
                cl = norm_classic(c)
                if cl and cl in tw_by_strong and len(tw_by_strong[cl]) == 1:
                    tw_rec = tw_by_strong[cl][0]
                    break

        tw_short = ""
        if tw_rec:
            tw_short = tw_rec["short"]
            arts = meta.setdefault("articles", {})
            rus_list = arts.setdefault("rus", [])
            if not any(a.get("src") == "Door43-ru_tw" for a in rus_list):
                rus_list.insert(
                    0,
                    {
                        "src": "Door43-ru_tw",
                        "title": tw_rec["raw_title"],
                        "content": tw_rec["body"],
                    },
                )
                tw_joined += 1
            meta["article_ru"] = tw_rec["body"]
            if not art:
                art = tw_rec["body"]

        ru_name = primary_ru_by_id.get(eid, en_name)
        desc_ru = generate_ru_short_description(
            eid,
            typ,
            sub,
            ru_name,
            en_name,
            en_desc,
            meta,
            rels_by_from,
            primary_ru_by_id,
            tw_short,
        )
        meta["short_description_ru"] = desc_ru
        ru_desc_count += 1
        ent_updates.append((art, json.dumps(meta, ensure_ascii=False), eid))

    db.executemany("UPDATE entities SET article=?, metadata=? WHERE id=?", ent_updates)

    # 8. Создаём и заполняем таблицы `book_chronology` и `visual_aids`
    db.executescript(
        """
        DROP TABLE IF EXISTS book_chronology;
        CREATE TABLE book_chronology(
            book TEXT PRIMARY KEY,
            book_num INTEGER NOT NULL,
            written_start INTEGER NOT NULL,
            written_end INTEGER NOT NULL,
            uncertain INTEGER NOT NULL DEFAULT 0,
            events_start INTEGER,
            events_end INTEGER,
            author_en TEXT NOT NULL DEFAULT '',
            author_ru TEXT NOT NULL DEFAULT '',
            place_en TEXT NOT NULL DEFAULT '',
            place_ru TEXT NOT NULL DEFAULT '',
            period_en TEXT NOT NULL DEFAULT '',
            period_ru TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT 'OpenBookIntros+Chronology'
        );
        DROP TABLE IF EXISTS visual_aids;
        CREATE TABLE visual_aids(
            code TEXT PRIMARY KEY,
            section_num INTEGER NOT NULL,
            letter TEXT NOT NULL,
            kind TEXT NOT NULL,
            title_en TEXT NOT NULL DEFAULT '',
            title_ru TEXT NOT NULL DEFAULT '',
            subtitle_en TEXT NOT NULL DEFAULT '',
            subtitle_ru TEXT NOT NULL DEFAULT '',
            body_json TEXT NOT NULL DEFAULT '{}',
            entity_id TEXT NOT NULL DEFAULT '',
            book TEXT NOT NULL DEFAULT '',
            chapter INTEGER,
            verse INTEGER,
            source TEXT NOT NULL DEFAULT '',
            license TEXT NOT NULL DEFAULT 'CC BY-SA 4.0'
        );
        CREATE INDEX idx_visual_aids_book ON visual_aids(book);
        CREATE INDEX idx_visual_aids_entity ON visual_aids(entity_id);
        """
    )
    db.executemany(
        "INSERT INTO book_chronology VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'OpenBookIntros+Chronology')",
        BOOK_CHRONOLOGY_ROWS,
    )
    va_rows = build_curated_visual_aids()
    existing_va_codes = {r[0] for r in va_rows}
    charts_66_path = DATA / "work" / "strongs" / "knowledge" / "book_charts_66.json"
    if charts_66_path.exists():
        charts_66 = json.loads(charts_66_path.read_text(encoding="utf-8"))
        for b_code, b_num, *_rest in BOOK_CHRONOLOGY_ROWS:
            va_code = f"{b_num}B"
            if va_code not in existing_va_codes and b_code in charts_66 and charts_66[b_code]:
                va_rows.append(
                    (
                        va_code,
                        b_num,
                        "B",
                        "chart",
                        f"Connections Between {b_code} and Other Books of the Bible",
                        f"Связь книги {b_code} с другими книгами Библии",
                        "Quotations, Prophecies, and Parallels Across the Canon",
                        "Цитаты, пророчества и параллели в каноне",
                        json.dumps({"rows": charts_66[b_code]}, ensure_ascii=False),
                        "",
                        b_code,
                        1,
                        1,
                        "OpenCrossRefs+STEPBible",
                        "CC BY-SA 4.0",
                    )
                )
    db.executemany("INSERT INTO visual_aids VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", va_rows)

    # 9. Заполняем таблицу `media` (OpenBible Geocoding + UBS Illustrations)
    ent_with_media, total_media_rows = populate_media_table(db)

    # 9a. Чистим данные: дубликаты canonical ru-имён, опечатку «Авесалом»
    #     в статьях Door43, и битые локальные `image_path` без реального файла.
    dup_removed = db.execute(
        """
        DELETE FROM entity_names WHERE rowid IN (
            SELECT rowid FROM (
                SELECT rowid, ROW_NUMBER() OVER (
                    PARTITION BY entity_id, LOWER(name)
                    ORDER BY CASE kind WHEN 'canonical' THEN 0 WHEN 'biblical' THEN 1
                             WHEN 'synodal' THEN 2 ELSE 3 END, rowid
                ) AS rn
                FROM entity_names WHERE lang IN ('ru', 'rus')
            ) WHERE rn > 1
        )
        """
    ).rowcount
    promoted = db.execute(
        """
        INSERT INTO entity_names
        SELECT e.id, n.name, 'ru', 'canonical'
        FROM entities e
        JOIN entity_names n ON n.entity_id = e.id AND n.lang = 'rus' AND n.kind = 'localized'
        WHERE NOT EXISTS(
            SELECT 1 FROM entity_names n2
            WHERE n2.entity_id = e.id AND n2.lang = 'ru' AND n2.kind = 'canonical'
        )
        GROUP BY e.id
        """
    ).rowcount
    db.execute(
        "UPDATE entities SET metadata=REPLACE(metadata, 'Авесалом', 'Авессалом') "
        "WHERE metadata LIKE '%Авесалом%'"
    )
    fixed_img = 0
    for eid, ipath in db.execute(
        "SELECT id, image_path FROM entities WHERE image_path != '' AND image_path NOT LIKE 'http%'"
    ).fetchall():
        http_media = db.execute(
            "SELECT rel_path FROM media WHERE entity_id=? AND rel_path LIKE 'http%' LIMIT 1",
            (eid,),
        ).fetchone()
        db.execute(
            "UPDATE entities SET image_path=? WHERE id=?",
            (http_media[0] if http_media else "", eid),
        )
        fixed_img += 1

    # 10. Обновляем метаданные модуля `knowledge.sb`
    all_ids = [r[0] for r in db.execute("SELECT id FROM entities ORDER BY id").fetchall()]
    digest = hashlib.sha256(json.dumps(all_ids, ensure_ascii=False).encode("utf-8")).hexdigest()
    db.execute("UPDATE meta SET value='0.4.0' WHERE key='version'")
    db.execute("UPDATE meta SET value=? WHERE key='content_hash'", (digest,))
    db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.execute("VACUUM")
    db.commit()

    # Итоговая статистика
    total_ent = db.execute("SELECT count(*) FROM entities").fetchone()[0]
    with_ru_name = db.execute(
        "SELECT count(DISTINCT entity_id) FROM entity_names WHERE lang IN ('ru','rus')"
    ).fetchone()[0]
    total_names = db.execute("SELECT count(*) FROM entity_names").fetchone()[0]
    total_rels = db.execute("SELECT count(*) FROM relationships").fetchone()[0]
    total_bc = db.execute("SELECT count(*) FROM book_chronology").fetchone()[0]
    total_va = db.execute("SELECT count(*) FROM visual_aids").fetchone()[0]
    db.close()
    sru.close()
    sen.close()

    # 11. Валидация `studybible module check` и упаковка `knowledge.sbz`
    cli = REPO / "target" / "debug" / "studybible.exe"
    subprocess.run([str(cli), "module", "check", str(KNOW_SB)], check=True)
    subprocess.run([str(cli), "module", "pack", str(KNOW_SB)], check=True)
    shutil.copy2(KNOW_SB, DATA / "modules" / "knowledge.sb")
    shutil.copy2(KNOW_SB.with_suffix(".sbz"), DATA / "modules" / "knowledge.sbz")

    summary = {
        "entities_total": total_ent,
        "entities_with_ru_name": with_ru_name,
        "ru_name_coverage_pct": round(100.0 * with_ru_name / total_ent, 2),
        "entity_names_total": total_names,
        "fixed_oblique_forms": fixed_oblique,
        "added_ru_names": len(added_names),
        "entities_with_name_meaning_ru": meaning_ru_count,
        "entities_with_name_accented_ru": accent_ru_count,
        "door43_ru_tw_joined": tw_joined,
        "short_description_ru_generated": ru_desc_count,
        "relationships_total": total_rels,
        "added_inverse_kinship_links": len(new_rels),
        "book_chronology_rows": total_bc,
        "visual_aids_rows": total_va,
        "entities_with_media": ent_with_media,
        "media_rows_total": total_media_rows,
        "duplicate_ru_names_removed": dup_removed,
        "rus_names_promoted_to_canonical": promoted,
        "dead_local_image_paths_fixed": fixed_img,
    }
    (DATA / "work" / "strongs" / "knowledge" / "stats-v0.3.0.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
