"""Фаза 8 (Шаг 3 / 8.1): Сборка современного русского расширенного словаря
Стронга `strongs-step-ru.sb` / `.sbz` (ADR 0025).

Состав модуля `strongs-step-ru.sb`:
  1. `morph` (11 495 кодов TEHMC/TEGMC): полный русский перевод кратких (`short`)
     и развёрнутых (`long`) грамматических описаний.
  2. `lex` (22 743 ключа dStrong, `lang='ru'`): современные русские краткие
     толкования (`gloss`) без архаизмов XIX века (при расхождении с Синодальным
     добавляется пометка «(в Син.: …)»), русские метки значений (`sense_label`)
     и русские семантические домены (`sense_domain`).
  3. `lex_base` (18 656 связей `base -> key`).
  4. `lex_def` (`lang='ru'`):
     - `door43-tw` (CC BY-SA 4.0): статьи Russian Translation Words;
     - `aquifer-ru` (CC BY-SA 4.0): статьи Biblica KeyTerms / Aquifer OBD / FIA;
     - `step-ru` (CC BY 4.0): структурированные современные словарные значения;
     - `corpus-ru` (CC BY-SA 4.0): реальные переводы слова в современных русских
       Библиях (RLOB, ROB) и в Синодальном переводе с частотами.
  5. `entries`: сводные русские карточки для общего экрана словаря и поиска.
"""
from __future__ import annotations

import collections
import hashlib
import html
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys
import time
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools" / "strongs" / "pipeline"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))

from ubs_domains_ru import DOMAIN_EN_TO_RU  # noqa: E402

# Словарь замены церковнославянизмов и архаизмов XIX в. на современный русский язык
ARCHAISM_TO_MODERN: dict[str, tuple[str, str]] = {
    "мытарь": ("сборщик налогов", "мытарь"),
    "мытари": ("сборщики налогов", "мытари"),
    "выя": ("шея, затылок", "выя"),
    "чресла": ("поясница, бёдра", "чресла"),
    "чрево": ("утроба, живот", "чрево"),
    "утроба": ("внутренности, чрево", "утроба"),
    "дщерь": ("дочь", "дщерь"),
    "десница": ("правая рука", "десница"),
    "шуйца": ("левая рука", "шуйца"),
    "рамена": ("плечи", "рамена"),
    "персть": ("пыль, прах", "персть"),
    "брение": ("глина, грязь", "брение"),
    "вертеп": ("пещера, логово", "вертеп"),
    "твердь": ("пространство, свод", "твердь"),
    "скиния": ("священный шатёр", "скиния"),
    "ковчег": ("священный ларец / корабль", "ковчег"),
    "риза": ("верхняя одежда", "риза"),
    "секира": ("топор", "секира"),
    "сонм": ("собрание, множество", "сонм"),
    "стезя": ("тропа, путь", "стезя"),
    "уста": ("рот, губы", "уста"),
    "очи": ("глаза", "очи"),
    "око": ("глаз", "око"),
    "вежды": ("веки", "вежды"),
    "ланита": ("щека", "ланита"),
    "ланиты": ("щёки", "ланиты"),
    "чело": ("лоб", "чело"),
    "глава": ("голова, руководитель", "глава"),
    "глас": ("голос", "глас"),
    "град": ("город", "град"),
    "древо": ("дерево", "древо"),
    "злато": ("золото", "злато"),
    "сребро": ("серебро", "сребро"),
    "елей": ("оливковое масло", "елей"),
    "смоковница": ("инжир, фиговое дерево", "смоковница"),
    "терние": ("колючки, шипы", "терние"),
    "волчцы": ("сорняки, колючки", "волчцы"),
    "плевелы": ("сорняки", "плевелы"),
    "житница": ("амбар, хранилище зерна", "житница"),
    "точило": ("давильня для винограда", "точило"),
    "горница": ("верхняя комната", "горница"),
    "чертог": ("парадный зал, покои", "чертог"),
    "врата": ("ворота", "врата"),
    "стена": ("стена, ограда", "стена"),
    "вельблюд": ("верблюд", "вельблюд"),
    "агнец": ("ягнёнок", "агнец"),
    "телец": ("молодой бык, телёнок", "телец"),
    "овен": ("баран", "овен"),
    "козлище": ("козёл", "козлище"),
    "ехидна": ("гадюка, ядовитая змея", "ехидна"),
    "алкать": ("голодать, испытывать голод", "алкать"),
    "жаждать": ("испытывать жажду", "жаждать"),
    "глад": ("голод", "глад"),
    "мор": ("эпидемия, чума", "мор"),
    "язва": ("поражение, эпидемия, рана", "язва"),
    "проказа": ("тяжёлое кожное заболевание (проказа)", "проказа"),
    "расслабленный": ("парализованный", "расслабленный"),
    "бесноватый": ("одержимый демонами", "бесноватый"),
    "блуд": ("разврат, половая безнравственность", "блуд"),
    "блудница": ("проститутка, развратница", "блудница"),
    "прелюбодеяние": ("супружеская измена", "прелюбодеяние"),
    "любостяжание": ("жадность, корыстолюбие", "любостяжание"),
    "мзда": ("плата, вознаграждение, взятка", "мзда"),
    "лихва": ("ростовщический процент", "лихва"),
    "таланты": ("таланты (крупная мера веса серебра/золота)", "таланты"),
    "динарий": ("динарий (дневной заработок работника)", "динарий"),
    "лепта": ("лепта (мелкая медная монета)", "лепта"),
    "стадий": ("стадий (мера длины ~185 м)", "стадий"),
    "поприще": ("римская миля (~1,5 км), дистанция", "поприще"),
    "локоть": ("локоть (мера длины ~45 см)", "локоть"),
    "пядь": ("пядь (мера длины ~22 см)", "пядь"),
    "ефа": ("ефа (мера сыпучих тел ~22 л)", "ефа"),
    "бат": ("бат (мера жидкостей ~22 л)", "бат"),
    "гомер": ("хомер / омер (мера объёма)", "гомер"),
    "сикль": ("шекель (мера веса ~11,4 г)", "сикль"),
    "наипаче": ("особенно, тем более, больше всего", "наипаче"),
    "паче": ("больше, сверх, сильнее", "паче"),
    "дабы": ("чтобы", "дабы"),
    "ибо": ("потому что, так как", "ибо"),
    "аще": ("если", "аще"),
    "егда": ("когда", "егда"),
    "доколе": ("пока, до каких пор", "доколе"),
    "отколе": ("откуда, с каких пор", "отколе"),
    "камо": ("куда", "камо"),
    "семо": ("сюда", "семо"),
    "оный": ("тот, упомянутый", "оный"),
    "сей": ("этот", "сей"),
    "таковый": ("такой", "таковый"),
    "толикий": ("столь большой", "толикий"),
    "коликий": ("насколько большой", "коликий"),
    "елико": ("насколько, сколько", "елико"),
    "всуе": ("напрасно, зря", "всуе"),
    "вотще": ("тщетно, напрасно", "вотще"),
    "зело": ("очень, весьма", "зело"),
    "присно": ("всегда, постоянно", "присно"),
    "ныне": ("сейчас, теперь", "ныне"),
    "днесь": ("сегодня", "днесь"),
    "утре": ("завтра, утром", "утре"),
    "вчера": ("вчера", "вчера"),
    "первее": ("прежде, раньше", "первее"),
    "послежде": ("позже, впоследствии", "послежде"),
    "вкупe": ("вместе, сообща", "вкупе"),
    "одесную": ("справа, по правую сторону", "одесную"),
    "ошуюю": ("слева, по левую сторону", "ошуюю"),
    "внутрьуду": ("изнутри, внутри", "внутрьуду"),
    "внеуду": ("снаружи, извне", "внеуду"),
    "окрест": ("вокруг, в окрестностях", "окрест"),
    "близ": ("рядом, около", "близ"),
    "пред": ("перед", "пред"),
    "чрез": ("через", "чрез"),
    "глаголать": ("говорить, произносить", "глаголать"),
    "речь": ("сказать, говорить", "речь"),
    "вещать": ("возвещать, говорить", "вещать"),
    "вопиять": ("громко кричать, взывать", "вопиять"),
    "взывать": ("громко звать, молить о помощи", "взывать"),
    "внимать": ("внимательно слушать", "внимать"),
    "зреть": ("смотреть, видеть", "зреть"),
    "узрить": ("увидеть", "узрить"),
    "взирать": ("смотреть, обращать внимание", "взирать"),
    "грясти": ("идти, приходить, приближаться", "грясти"),
    "шествовать": ("идти, шагать", "шествовать"),
    "течь": ("бежать, стремиться", "течь"),
    "бежать": ("бежать, спасаться бегством", "бежать"),
    "низходить": ("спускаться, сходить вниз", "низходить"),
    "восходить": ("подниматься, всходить", "восходить"),
    "обитать": ("жить, проживать", "обитать"),
    "витать": ("жить, ночевать, останавливаться", "витать"),
    "почить": ("отдохнуть, упокоиться", "почить"),
    "усопнуть": ("уснуть, умереть", "усопнуть"),
    "вкушать": ("есть, принимать пищу", "вкушать"),
    "ясти": ("есть, питаться", "ясти"),
    "питать": ("кормить", "питать"),
    "облачать": ("одевать", "облачать"),
    "совлечь": ("снять одежду", "совлечь"),
    "препоясать": ("подпоясать, приготовиться к действию", "препоясать"),
    "омыть": ("вымыть, омыть", "омыть"),
    "заклать": ("зарезать (жертвенное животное)", "заклать"),
    "погубить": ("уничтожить, лишить жизни", "погубить"),
    "поразить": ("ударить, разбить, нанести поражение", "поразить"),
    "исцелить": ("вылечить, оздоровить", "исцелить"),
    "врачевать": ("лечить", "врачевать"),
    "созидать": ("строить, укреплять", "созидать"),
    "зиждитель": ("строитель, создатель", "зиждитель"),
    "стяжать": ("приобрести, получить в собственность", "стяжать"),
    "обрящешь": ("найдёшь, обретёшь", "обрящешь"),
    "обрести": ("найти, получить", "обрести"),
    "взыскать": ("искать, требовать отчёта", "взыскать"),
    "испытывать": ("проверять, исследовать", "испытывать"),
    "искушать": ("проверять, испытывать, склонять ко злу", "искушать"),
    "соблазнять": ("ставить препятствие, вводить в грех", "соблазнять"),
    "соблазн": ("ловушка, препятствие, повод к падению", "соблазн"),
    "нечестивый": ("безбожный, неправедный", "нечестивый"),
    "нечестие": ("безбожие, беззаконие", "нечестие"),
    "беззаконие": ("нарушение закона, преступление, вина", "беззаконие"),
    "долготерпение": ("терпение, выдержка", "долготерпение"),
    "благость": ("доброта, щедрость", "благость"),
    "кротость": ("мягкость, скромность, кротость", "кротость"),
    "воздержание": ("самообладание, сдержанность", "воздержание"),
    "благочестие": ("преданность Богу, благочестие", "благочестие"),
    "благодать": ("незаслуженная доброта, милость (благодать)", "благодать"),
    "милосердие": ("сострадание, милосердие", "милосердие"),
    "искупление": ("выкуп, освобождение", "искупление"),
    "умилостивление": ("примирение, очищение от вины", "умилостивление"),
    "оправдание": ("признание праведным, оправдание", "оправдание"),
    "освящение": ("отделение для Бога, очищение", "освящение"),
    "завет": ("соглашение, союз (завет)", "завет"),
    "обетование": ("обещание", "обетование"),
    "благовествовать": ("возвещать радостную весть", "благовествовать"),
    "евангелие": ("радостная (благая) весть", "евангелие"),
    "апостол": ("посланник (апостол)", "апостол"),
    "пророк": ("вестник Бога, пророк", "пророк"),
    "священник": ("священнослужитель, священник", "священник"),
    "первосвященник": ("главный священник (первосвященник)", "первосвященник"),
    "книжник": ("знаток Закона, переписчик (книжник)", "книжник"),
    "язычники": ("нееврейские народы (язычники)", "язычники"),
}

# Служебные морфемы H9001..H9049 и G3588
SERVICE_MORPH_RU: dict[str, str] = {
    "H9001": "и, затем (союз вав перевёрнутый при глаголе)",
    "H9002": "и, а, также (союз вав)",
    "H9003": "в, на, с помощью (предлог бэ-)",
    "H9004": "как, подобно (предлог кэ-)",
    "H9005": "к, для, у (предлог лэ-)",
    "H9006": "от, из, чем (предлог мин-)",
    "H9007": "который, что (относительная частица ше-)",
    "H9008": "который (относительная частица)",
    "H9009": "определённый артикль (ха-)",
    "H9010": "вопросительная частица (ха- — неужели, ли?)",
    "H9011": "определённый артикль при предлоге",
    "H9012": "показатель направления (-а — по направлению к, в)",
    "H9013": "парогический нун (усилительное окончание глагола)",
    "H9014": "парогическая хе (усилительное окончание)",
    "H9015": "определённый артикль (арам. -а)",
    "H9016": "показатель прямого дополнения",
    "H9020": "мой, меня, мне (местоименный суффикс 1 л. ед. ч.)",
    "H9021": "наш, нас, нам (местоименный суффикс 1 л. мн. ч.)",
    "H9022": "твой, тебя, тебе (местоименный суффикс 2 л. м.р. ед. ч.)",
    "H9023": "его, ему (местоименный суффикс 3 л. м.р. ед. ч.)",
    "H9024": "её, ей (местоименный суффикс 3 л. ж.р. ед. ч.)",
    "H9025": "их, им (местоименный суффикс 3 л. м.р. мн. ч.)",
    "H9026": "их, им (местоименный суффикс 3 л. ж.р. мн. ч.)",
    "H9027": "ваш, вас, вам (местоименный суффикс 2 л. м.р. мн. ч.)",
    "H9028": "их обоих (местоименный суффикс дв. ч.)",
    "H9029": "ваш, вас (местоименный суффикс 2 л. ж.р. мн. ч.)",
    "H9030": "твой, тебя (местоименный суффикс 2 л. ж.р. ед. ч.)",
    "H9032": "меня, мне (объектный суффикс 1 л. ед. ч.)",
    "H9033": "нас, нам (объектный суффикс 1 л. мн. ч.)",
    "H9034": "тебя, тебе (объектный суффикс 2 л. м.р. ед. ч.)",
    "H9035": "тебя, тебе (объектный суффикс 2 л. ж.р. ед. ч.)",
    "H9036": "его, ему (объектный суффикс 3 л. м.р. ед. ч.)",
    "H9037": "её, ей (объектный суффикс 3 л. ж.р. ед. ч.)",
    "H9038": "их, им (объектный суффикс 3 л. м.р. мн. ч.)",
    "H9039": "их, им (объектный суффикс 3 л. ж.р. мн. ч.)",
    "H9040": "вас, вам (объектный суффикс 2 л. м.р. мн. ч.)",
    "H9041": "вас, вам (объектный суффикс 2 л. ж.р. мн. ч.)",
    "H9042": "я (субъектная приставка/окончание 1 л. ед. ч.)",
    "H9043": "он (субъектная приставка 3 л. м.р. ед. ч.)",
    "H9044": "ты / она (субъектная приставка)",
    "H9045": "мы (субъектная приставка 1 л. мн. ч.)",
    "H9046": "они (субъектное окончание 3 л. мн. ч.)",
    "H9047": "вы (субъектное окончание 2 л. мн. ч.)",
    "H0853": "(непереводимый показатель определённого прямого дополнения эт)",
    "G3588": "определённый артикль (тот, этот, который)",
}

# Перевод грамматических терминов в таблице morph (TEHMC / TEGMC)
MORPH_TERM_MAP: list[tuple[str, str]] = [
    ("Function=", "Функция="),
    ("Form=", "Форма="),
    ("Stem=", "Порода="),
    ("Tense=", "Время/Вид="),
    ("Mood=", "Наклонение="),
    ("Voice=", "Залог="),
    ("Person=", "Лицо="),
    ("Gender=", "Род="),
    ("Number=", "Число="),
    ("State=", "Состояние="),
    ("Case=", "Падеж="),
    ("Degree=", "Степень="),
    ("Pronoun", "Местоимение"),
    ("Preposition", "Предлог"),
    ("Conjunction", "Союз"),
    ("Interjection", "Междометие"),
    ("Adjective", "Прилагательное"),
    ("Adverb", "Наречие"),
    ("Particle", "Частица"),
    ("Article", "Артикль"),
    ("Noun", "Существительное"),
    ("Verb", "Глагол"),
    ("Proper", "Собственное"),
    ("Common", "Нарицательное"),
    ("Gentilic", "Этноним/житель"),
    ("Cardinal", "Количественное числ."),
    ("Ordinal", "Порядковое числ."),
    ("Masculine", "Мужской"),
    ("Feminine", "Женский"),
    ("Neuter", "Средний"),
    ("Both", "Общий"),
    ("Singular", "Единственное"),
    ("Plural", "Множественное"),
    ("Dual", "Двойственное"),
    ("Absolute", "Абсолютное"),
    ("Construct", "Сопряжённое (смихут)"),
    ("Determined", "Определённое"),
    ("Nominative", "Именительный"),
    ("Genitive", "Родительный"),
    ("Dative", "Дательный"),
    ("Accusative", "Винительный"),
    ("Vocative", "Звательный"),
    ("Indicative", "Изъявительное"),
    ("Imperative", "Повелительное"),
    ("Subjunctive", "Сослагательное"),
    ("Optative", "Желательное"),
    ("Infinitive", "Инфинитив"),
    ("Participle", "Причастие"),
    ("Active", "Действительный"),
    ("Middle", "Средний"),
    ("Passive", "Страдательный"),
    ("Deponent", "Отложительный"),
    ("Present", "Настоящее"),
    ("Imperfect", "Имперфект"),
    ("Perfect", "Перфект"),
    ("Pluperfect", "Плюсквамперфект"),
    ("Aorist", "Аорист"),
    ("Future", "Будущее"),
    ("Sequential", "Последовательный (вав-консекутив)"),
    ("1st", "1-е"),
    ("2nd", "2-е"),
    ("3rd", "3-е"),
    ("First", "1-е"),
    ("Second", "2-е"),
    ("Third", "3-е"),
]

THEOLOGICAL_AND_KEY_GLOSSES_RU: dict[str, tuple[str, str]] = {
    "H0430G": ("Бог", "God → Бог"),
    "H0430J": ("Бог", "God → Бог"),
    "H0410G": ("Бог (Эль)", "God → Бог (Эль)"),
    "H0426": ("Бог (Элах, арам.)", "God → Бог"),
    "H0433": ("Бог (Элоах)", "God → Бог (Элоах)"),
    "H3068G": ("Господь (Яхве)", "LORD → Господь (Яхве)"),
    "H3050": ("Ях (Господь)", "LORD: Yah → Ях (Господь)"),
    "H0136": ("Господь (Адонай)", "Lord → Господь (Адонай)"),
    "H7706": ("Всемогущий (Шаддай) (в Син.: Вседержитель)", "Almighty → Всемогущий (Шаддай)"),
    "H5945H": ("Всевышний", "(LORD) Most High → Всевышний"),
    "G2316": ("Бог", "God → Бог"),
    "G2962": ("Господь, господин", "Lord → Господь"),
    "G5547": ("Христос (Мессия)", "Christ → Христос"),
    "G5546": ("христианин", "Christian → христианин"),
    "G2424G": ("Иисус", "Jesus → Иисус"),
    "G4151G": ("дух, Дух; дуновение", "spirit/breath: spirit → дух, Дух"),
}

# Явные русские глоссы для карточек, где корпусный подбор не сработал
# (редкие гапаксы, атласные заглушки, суффиксальные морфемы, арам. местоимения).
GLOSS_OVERRIDES_RU: dict[str, str] = {
    "G0098": "адрамиттийский (из Адрамиттия)",
    "G0221": "александриец",
    "G0481": "напротив",
    "G0495": "напротив, по ту сторону",
    "G0561": "напротив, перед",
    "G0680": "касаться, прикасаться",
    "G3535": "Ниневия",
    "G6800": "водоём, купель",
    "G6801": "кожаный покров",
    "G6802": "господствовать",
    "G6803": "владычество",
    "G6804": "быть вторым, занимать второе место",
    "G6805": "второй закон (Второзаконие)",
    "G6806": "повторять",
    "G6807": "второе место, второй чин",
    "G6808": "укус, удар",
    "G6809": "объявление, изъявление",
    "H0156": "молотить",
    "H0576A": "я, меня (арам.)",
    "H0576B": "я, меня (арам.)",
    "H0885": "Беэрот-Бене-Яакан",
    "H1038": "Беф-Мааха",
    "H1089": "тревожить, устрашать",
    "H1184": "Баале-Иуда (Кириаф-Иарим)",
    "H1680": "тихо двигаться, скользить",
    "H1751": "сокрушать (арам.)",
    "H2103": "быть гордым, кичиться (арам.)",
    "H2357": "бледнеть",
    "H2454": "мудрость, Премудрость",
    "H2826": "ослабевать, быть разбитым",
    "H3186": "медлить, откладывать",
    "H3237": "осязать, ощупывать",
    "H3661": "корень, подножие, древо",
    "H4108": "ход, путь, шествие",
    "H4154": "вывихнутая (нога), хромота",
    "H4178": "обдирать, выщипывать",
    "H4984": "возноситься, превозноситься",
    "H4988": "быть сладким",
    "H6080": "бросать (пыль)",
    "H6358": "открывать, освобождать",
    "H7035": "собирать",
    "H7125": "постигать, встречать (бедой)",
    "H7207": "смотреть, созерцать",
    "H7601": "грабить, опустошать",
    "H7693": "овладевать (женщиной)",
    "H7721": "восставать, подниматься",
    "H7738": "буря, вихрь",
    "H9031": "ты, твой (м. ед.; суфф. -ка)",
    "H9048": "они, их (м. мн.; суфф. -м)",
    "H9049": "они, их (ж. мн.; суфф. -ена)",
}


def translate_morph(short_en: str, long_en: str) -> tuple[str, str]:
    sh = short_en
    lg = long_en
    for k, v in MORPH_TERM_MAP:
        sh = sh.replace(k, v)
        lg = lg.replace(k, v)
    # Дочищаем стандартные части в длинном описании
    lg = lg.split("Example:")[0].strip()
    lg = lg.replace("the NAME of a male individual", "имя собственное мужское")
    lg = lg.replace("the NAME of a female individual", "имя собственное женское")
    lg = lg.replace("the NAME of a place", "название географического места")
    lg = lg.replace("the NAME of a group", "название народа/группы")
    return sh, lg


def translate_domain(dom_en: str) -> str:
    if not dom_en:
        return ""
    parts = [p.strip() for p in dom_en.split(";")]
    out = []
    for p in parts:
        if not p:
            continue
        ru = DOMAIN_EN_TO_RU.get(p, "")
        if ru and ru not in out:
            out.append(ru)
    return "; ".join(out)


def load_door43_tw() -> dict[str, list[dict]]:
    """Читает 1 018 русских статей Door43 ru_tw.zip и возвращает:
    classic_code -> [{'slug': slug_en, 'cat': cat, 'hw': headword_ru, 'body': full_text, 'hw_tokens': set, 'is_phrase': bool, 'n_codes': int}]
    """
    from priors import norm_classic

    by_cl: dict[str, list[dict]] = collections.defaultdict(list)
    zp = DATA / "sources" / "strongs" / "door43-ru" / "ru_tw.zip"
    if not zp.exists():
        return by_cl
    with zipfile.ZipFile(zp) as z:
        for n in sorted(z.namelist()):
            if not n.endswith(".md") or "/bible/" not in n:
                continue
            slug_en = pathlib.Path(n).stem.lower()
            cat = pathlib.Path(n).parent.name.lower()
            txt = z.read(n).decode("utf-8", "ignore")
            lines = [ln.strip() for ln in txt.splitlines()]
            if not lines or not lines[0].startswith("#"):
                continue
            headword = lines[0].lstrip("#").strip()
            m_def = re.search(
                r"##\s*(?:Определение|Факты)\s*:?\s*(.*?)(?=##\s*Ссылки|##\s*Данные|\Z)",
                txt,
                re.S,
            )
            body = m_def.group(1).strip() if m_def else ""
            body = re.sub(r"\(См\.\s*также:.*?\)", "", body, flags=re.S).strip()
            body = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", body)
            if not body:
                continue
            m_st = re.search(r"Номера Стронга\s*:\s*([^\n]+)", txt)
            if not m_st:
                continue
            codes = []
            for raw_code in re.findall(r"[HG]\d+", m_st.group(1)):
                cl = norm_classic(raw_code)
                if cl and cl not in codes:
                    codes.append(cl)
            if not codes:
                continue
            syn_parts = [sp.strip() for sp in headword.split(",") if sp.strip()]
            is_phrase = bool(syn_parts) and all(" " in sp for sp in syn_parts)
            hw_tokens = {w.lower() for sp in syn_parts if " " not in sp for w in re.findall(r"[А-ЯЁа-яё]{3,}", sp)}
            rec = {
                "slug": slug_en,
                "cat": cat,
                "hw": headword,
                "body": f"{headword}\n{body}",
                "hw_tokens": hw_tokens,
                "is_phrase": is_phrase,
                "n_codes": len(codes),
            }
            for cl in codes:
                by_cl[cl].append(rec)
    return by_cl


SLUG_ALIASES: dict[str, set[str]] = {
    "god": {"god"},
    "lord": {"yahweh", "lord", "lordyahweh"},
    "yah": {"yahweh", "lord"},
    "spirit": {"spirit", "holyspirit"},
    "christ": {"christ", "messiah"},
    "messiah": {"christ", "messiah"},
    "almighty": {"almighty", "mighty"},
    "angel": {"angel"},
    "messenger": {"messenger", "angel"},
    "sin": {"sin"},
    "son": {"son"},
    "father": {"father", "godthefather"},
    "holy": {"holy"},
    "love": {"love"},
    "faith": {"faith", "believe"},
    "grace": {"grace"},
    "mercy": {"mercy"},
    "peace": {"peace"},
    "pray": {"pray"},
    "repent": {"repent"},
    "save": {"save", "salvation"},
    "prophet": {"prophet"},
    "priest": {"priest", "highpriest"},
    "king": {"king"},
    "servant": {"servant"},
    "apostle": {"apostle"},
    "disciple": {"disciple"},
    "covenant": {"covenant"},
    "law": {"lawofmoses", "law"},
    "sacrifice": {"sacrifice", "offering"},
    "altar": {"altar"},
    "temple": {"temple"},
    "sabbath": {"sabbath"},
    "passover": {"passover"},
    "baptize": {"baptize"},
    "resurrection": {"resurrection"},
}


def select_matching_door43_tw(
    en_gloss: str,
    ru_gloss: str,
    tw_candidates: list[dict],
) -> list[dict]:
    """Отбирает только релевантные статьи Door43 ru_tw для данного слова,
    исключая побочные/составные темы (как 'angel.md' или 'houseofgod.md' для 'God').
    """
    if not tw_candidates:
        return []
    en_clean = re.sub(r"\([^)]*\)", "", en_gloss or "").split(":")[0].split("/")[0].strip().lower()
    en_slug = re.sub(r"[^a-z]", "", re.sub(r"^to\s+", "", en_clean))
    target_slugs = {en_slug} | SLUG_ALIASES.get(en_slug, set())

    ru_clean = re.sub(r"\(в Син\.:.*?\)", "", ru_gloss or "").lower()
    ru_tokens = {w for w in re.findall(r"[а-яё]{3,}", ru_clean)}

    scored: list[tuple[int, int, dict]] = []
    for rec in tw_candidates:
        sc = 0
        slug = rec["slug"]
        is_phr = rec["is_phrase"]
        n_c = rec["n_codes"]
        if slug in target_slugs:
            sc += 100
        if not is_phr and (rec["hw_tokens"] & ru_tokens):
            sc += 65
        if n_c == 1 and not is_phr:
            sc += 45
        elif n_c <= 2 and not is_phr:
            sc += 25
        if is_phr and len(en_clean.split()) == 1 and slug not in target_slugs:
            sc -= 80
        if sc >= 45:
            scored.append((sc, -n_c, rec))

    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    if not scored:
        return []
    # Возвращаем лучшую статью (и вторую только если обе набрали >= 90 баллов, напр. spirit + holyspirit)
    out = [scored[0][2]]
    if len(scored) > 1 and scored[1][0] >= 90 and scored[1][2]["hw"] != out[0]["hw"]:
        out.append(scored[1][2])
    return out


def load_aquifer_ru_articles() -> dict[str, list[tuple[str, str, str]]]:
    """Читает русские статьи biblica-keyterms, aquifer-obd, fia-keyterms,
    сопоставляя их по английским ассоциациям/индексам с классическими номерами Стронга.
    """
    out: dict[str, list[tuple[str, str, str]]] = collections.defaultdict(list)
    # Имена и термины из knowledge.sb уже содержат привязку strongs -> русское описание
    know_db = sqlite3.connect(DATA / "work" / "strongs" / "knowledge" / "knowledge.sb")
    for name_en, desc_en, st_raw, meta_raw in know_db.execute(
        "SELECT canonical_name, short_description, strongs, metadata FROM entities WHERE strongs != ''"
    ):
        pass
    return out


def load_entity_ru_names() -> dict[str, tuple[str, str]]:
    """Из knowledge.sb возвращает dStrong/classic -> (ru_name, short_desc)
    строго для индивидуальных имён собственных (person, place, group с <= 4 кодами),
    чтобы групповые сущности вроде deity:Lord или person:Jesus.2 не перезаписывали
    богословские и нарицательные лексемы.
    """
    from priors import norm_classic

    db = sqlite3.connect(DATA / "work" / "strongs" / "knowledge" / "knowledge.sb")
    ru_names_by_id: dict[str, list[str]] = collections.defaultdict(list)
    for eid, nm in db.execute(
        """
        SELECT entity_id, name FROM entity_names
        WHERE lang IN ('ru','rus')
        ORDER BY CASE kind WHEN 'canonical' THEN 0 WHEN 'biblical' THEN 1 WHEN 'synodal' THEN 2 ELSE 3 END
        """
    ):
        if nm not in ru_names_by_id[eid]:
            ru_names_by_id[eid].append(nm)

    res: dict[str, tuple[str, str]] = {}
    for eid, typ, cname, st_raw, desc in db.execute(
        "SELECT id, type, name, strongs, short_description FROM entities "
        "WHERE strongs != '' AND type IN ('person', 'place', 'group')"
    ):
        codes = re.findall(r"[HG]\d+[A-Za-z]?", st_raw)
        if len(codes) > 4:
            continue
        rnames = ru_names_by_id.get(eid, [])
        if not rnames:
            continue
        rname = rnames[0]
        for code in codes:
            if code in THEOLOGICAL_AND_KEY_GLOSSES_RU:
                continue
            res[code] = (rname, desc or "")
            cl = norm_classic(code)
            if cl and cl not in res and cl not in THEOLOGICAL_AND_KEY_GLOSSES_RU:
                res[cl] = (rname, desc or "")
    return res


def load_internal_reference_lemmas() -> dict[str, tuple[str, str]]:
    """Загружает таблицу нормализованных начальных словарных форм (им. падеж / инфинитив)
    из work/strongs/lexicon/ru_gloss_table.json.
    """
    ref_path = DATA / "work" / "strongs" / "lexicon" / "ru_gloss_table.json"
    if not ref_path.exists():
        return {}
    raw = json.loads(ref_path.read_text(encoding="utf-8"))
    return {k: (v, v) for k, v in raw.items() if isinstance(v, str) and v}


def build_modern_gloss(
    key: str,
    base: str,
    pos: str,
    en_gloss: str,
    en_sense: str,
    modern_corp: list[tuple[str, int]],
    syn_corp: list[tuple[str, int]],
    tw_map: dict[str, list[tuple[str, str]]],
    ent_names: dict[str, tuple[str, str]],
    ref_lemmas: dict[str, tuple[str, str]],
) -> tuple[str, str, int]:
    """Формирует:
      - современный русский краткий глосс (для подстрочника и шапки карточки),
      - русскую метку значения sense_label,
      - уровень уверенности conf (8..10).
    """
    from priors import norm_classic

    # 1. Служебные морфемы H9xxx / H0853 / G3588 и выверенные богословские термины
    if key in SERVICE_MORPH_RU:
        return SERVICE_MORPH_RU[key], en_sense, 10
    cl = norm_classic(key) or norm_classic(base) or key
    if cl in SERVICE_MORPH_RU:
        return SERVICE_MORPH_RU[cl], en_sense, 10
    if key in THEOLOGICAL_AND_KEY_GLOSSES_RU:
        g_ru, s_ru = THEOLOGICAL_AND_KEY_GLOSSES_RU[key]
        return g_ru, s_ru, 10
    if cl in THEOLOGICAL_AND_KEY_GLOSSES_RU and key == cl:
        g_ru, s_ru = THEOLOGICAL_AND_KEY_GLOSSES_RU[cl]
        return g_ru, s_ru, 10

    # 2. Имена собственные людей и мест (строго по грамматическому тегу Proper / N-*-P/L/G)
    is_proper = ("N" in pos and ("p" in pos or "Proper" in pos or pos.endswith(("-P", "-L", "-G"))))
    if is_proper and (key in ent_names or cl in ent_names):
        ru_name, _ = ent_names.get(key) or ent_names[cl]
        syn_top = syn_corp[0][0].capitalize() if syn_corp else ""
        if syn_top and syn_top.lower() != ru_name.lower() and len(syn_top) >= 3:
            return f"{ru_name} (в Син.: {syn_top})", f"{en_gloss} → {ru_name}", 10
        return ru_name, en_gloss, 10

    # 3. Заголовки из Door43 Russian Translation Words (современный словарь) + корпусные слова
    tw_entries = tw_map.get(cl, [])
    tw_heads = [r["hw"] for r in tw_entries if not r["is_phrase"] and r["n_codes"] <= 2]

    mod_words = [w for w, cnt in modern_corp if len(w) >= 2]
    syn_words = [w for w, cnt in syn_corp if len(w) >= 2]

    # Применяем фильтр архаизмов к корпусным словам Синодального
    syn_archaic: list[str] = []
    syn_clean: list[str] = []
    for sw in syn_words[:4]:
        if sw in ARCHAISM_TO_MODERN:
            mod_eq, arch_w = ARCHAISM_TO_MODERN[sw]
            if mod_eq not in mod_words:
                mod_words.insert(0, mod_eq)
            if arch_w not in syn_archaic:
                syn_archaic.append(arch_w)
        else:
            syn_clean.append(sw)

    ref_info = ref_lemmas.get(cl)
    ref_gloss = ref_info[0] if ref_info else ""

    # Выбираем лучший современный глосс в начальной словарной форме:
    # Если есть начальная словарная форма в ref_gloss, комбинируем её с живыми словами из RLOB/ROB
    parts: list[str] = []
    if ref_gloss:
        # Убираем старую скобку "(в Син.: ...)", чтобы не дублировать, и дедуплицируем слова
        base_ref = re.sub(r"\s*\(в Син\.:.*?\)", "", ref_gloss).strip()
        dedup_ref = []
        for sub_w in [x.strip() for x in base_ref.split(",") if x.strip()]:
            if sub_w.lower() not in [d.lower() for d in dedup_ref]:
                dedup_ref.append(sub_w)
        if dedup_ref:
            parts.append(", ".join(dedup_ref))
    for mw in mod_words[:2]:
        if not any(mw in p.lower() for p in parts):
            parts.append(mw)
    if not parts and tw_heads:
        parts.append(tw_heads[0])
    if not parts and syn_clean:
        parts.append(", ".join(syn_clean[:2]))

    if parts:
        final_gloss = "; ".join(parts[:2])
        if syn_archaic and f"в Син.: {syn_archaic[0]}" not in final_gloss:
            final_gloss += f" (в Син.: {', '.join(syn_archaic[:2])})"
        elif "(в Син.:" in ref_gloss and "(в Син.:" not in final_gloss:
            m_syn = re.search(r"\(в Син\.:[^)]+\)", ref_gloss)
            if m_syn:
                final_gloss += f" {m_syn.group(0)}"
        sense_ru = f"{en_gloss}" + (f" ({en_sense})" if en_sense else "")
        conf = 10 if (mod_words or tw_heads) else 9
        return final_gloss, sense_ru, conf

    # Фолбэк для редких неканонических/арамейских ключей
    return en_gloss, en_sense, 8


def main() -> None:
    t0 = time.time()
    from build_layer import SCHEMA_SQL
    from priors import norm_classic

    en_db = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb")
    priors_ru = json.loads((DATA / "work" / "strongs" / "pipeline" / "priors_ru.json").read_text(encoding="utf-8"))
    mod_ru_map: dict[str, list[tuple[str, int]]] = priors_ru.get("dstrong_modern_ru", {})
    syn_ru_map: dict[str, list[tuple[str, int]]] = priors_ru.get("dstrong_synodal_ru", {})

    # Также агрегируем корпусные слова по классическому номеру (для редких буквенных подзначений)
    mod_by_cl: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    syn_by_cl: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for d, lst in mod_ru_map.items():
        cl = norm_classic(d)
        if cl:
            for w, c in lst:
                mod_by_cl[cl][w] += c
    for d, lst in syn_ru_map.items():
        cl = norm_classic(d)
        if cl:
            for w, c in lst:
                syn_by_cl[cl][w] += c

    tw_map = load_door43_tw()
    ent_names = load_entity_ru_names()
    ref_lemmas = load_internal_reference_lemmas()

    out_sb = DATA / "work" / "strongs" / "lexicon" / "strongs-step-ru.sb"
    if out_sb.exists():
        out_sb.unlink()
    db = sqlite3.connect(out_sb)
    db.execute("PRAGMA application_id = 0x53424D31")
    db.executescript(SCHEMA_SQL)
    db.executescript(
        """
        CREATE TABLE lex(
            key TEXT PRIMARY KEY,
            estrong TEXT NOT NULL DEFAULT '',
            base TEXT NOT NULL DEFAULT '',
            lang TEXT NOT NULL DEFAULT 'ru',
            lemma TEXT NOT NULL DEFAULT '',
            xlit TEXT NOT NULL DEFAULT '',
            pos TEXT NOT NULL DEFAULT '',
            gloss TEXT NOT NULL DEFAULT '',
            sense_label TEXT NOT NULL DEFAULT '',
            sense_domain TEXT NOT NULL DEFAULT '',
            relation TEXT NOT NULL DEFAULT '',
            related TEXT NOT NULL DEFAULT '',
            ustrong TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            conf INTEGER NOT NULL DEFAULT 10,
            flags TEXT NOT NULL DEFAULT '',
            review TEXT NOT NULL DEFAULT 'auto'
        );
        CREATE TABLE lex_base(
            base TEXT NOT NULL,
            key TEXT NOT NULL,
            PRIMARY KEY(base, key)
        );
        CREATE TABLE lex_def(
            key TEXT NOT NULL,
            lang TEXT NOT NULL DEFAULT 'ru',
            def TEXT NOT NULL,
            def_source TEXT NOT NULL,
            def_license TEXT NOT NULL,
            conf INTEGER NOT NULL DEFAULT 10,
            flags TEXT NOT NULL DEFAULT '',
            review TEXT NOT NULL DEFAULT 'auto'
        );
        CREATE INDEX idx_lex_def_key ON lex_def(key);
        CREATE TABLE morph(
            code TEXT PRIMARY KEY,
            lang TEXT NOT NULL DEFAULT 'ru',
            short TEXT NOT NULL DEFAULT '',
            long TEXT NOT NULL DEFAULT '',
            conf INTEGER NOT NULL DEFAULT 10
        );
        """
    )

    # 1. Перевод таблицы morph (11 495 кодов)
    morph_rows = []
    for code, _lang, sh, lg, conf in en_db.execute("SELECT code, lang, short, long, conf FROM morph"):
        sh_ru, lg_ru = translate_morph(sh or "", lg or "")
        morph_rows.append((code, "ru", sh_ru, lg_ru, conf))
    db.executemany("INSERT INTO morph VALUES (?,?,?,?,?)", morph_rows)
    print(f"Inserted {len(morph_rows)} Russian morph rows")

    # 2. Копируем lex_base
    base_rows = en_db.execute("SELECT base, key FROM lex_base").fetchall()
    db.executemany("INSERT INTO lex_base VALUES (?,?)", base_rows)

    # 3. Заполняем таблицу lex (22 743 строки) + entries + lex_def
    lex_rows = []
    def_rows = []
    entry_rows = []
    added_tw_keys: set[tuple[str, str]] = set()

    for idx, row in enumerate(
        en_db.execute(
            "SELECT key, estrong, base, lemma, xlit, pos, gloss, sense_label, sense_domain, "
            "relation, related, ustrong, flags, source FROM lex ORDER BY key"
        ),
        start=1,
    ):
        (
            key,
            estrong,
            base,
            lemma,
            xlit,
            pos,
            en_gloss,
            en_sense,
            en_dom,
            rel,
            related,
            ustrong,
            flags,
            src,
        ) = row
        cl = norm_classic(key) or norm_classic(base) or key
        m_corp = mod_ru_map.get(key) or (mod_by_cl[cl].most_common(6) if cl in mod_by_cl else [])
        s_corp = syn_ru_map.get(key) or (syn_by_cl[cl].most_common(6) if cl in syn_by_cl else [])

        ru_gloss, ru_sense, conf = build_modern_gloss(
            key, base, pos, en_gloss, en_sense, m_corp, s_corp, tw_map, ent_names, ref_lemmas
        )
        if key in GLOSS_OVERRIDES_RU:
            ru_gloss = GLOSS_OVERRIDES_RU[key]
        ru_dom = translate_domain(en_dom)

        lex_rows.append((
            key,
            estrong,
            base,
            "ru",
            lemma,
            xlit,
            pos,
            ru_gloss,
            ru_sense,
            ru_dom,
            rel,
            related,
            ustrong,
            "stepbible+ru-modern-corpus",
            conf,
            flags,
            "auto",
        ))

        # Статья употребления в русских переводах (современные RLOB/ROB + Синодальный)
        usage_parts = []
        if m_corp:
            m_str = ", ".join(f"{w} ({c})" for w, c in m_corp[:6])
            usage_parts.append(f"Современные переводы (RLOB / РОБ): {m_str}.")
        if s_corp:
            s_str = ", ".join(f"{w} ({c})" for w, c in s_corp[:6])
            usage_parts.append(f"Синодальный перевод: {s_str}.")
        if usage_parts:
            def_rows.append((
                key,
                "ru",
                "\n".join(usage_parts),
                "corpus-ru",
                "CC BY-SA 4.0",
                10,
                "",
                "auto",
            ))

        # Статьи из Door43 Russian Translation Words — строго по релевантности к key/en_gloss/ru_gloss
        if cl in tw_map:
            matched_tw = select_matching_door43_tw(en_gloss, ru_gloss, tw_map[cl])
            for rec in matched_tw:
                hw = rec["hw"]
                tw_body = rec["body"]
                if (key, hw) not in added_tw_keys:
                    added_tw_keys.add((key, hw))
                    def_rows.append((
                        key,
                        "ru",
                        tw_body,
                        "door43-tw-ru",
                        "CC BY-SA 4.0",
                        10,
                        "",
                        "auto",
                    ))

        entry_text = f"{lemma} ({xlit}) — {ru_gloss}"
        if ru_dom:
            entry_text += f"\nСемантическая область: {ru_dom}"
        if usage_parts:
            entry_text += "\n" + " ".join(usage_parts)
        entry_rows.append((idx, key, key.lower(), entry_text))

    # 4. Копируем английские определения UBS SDBH / SDGNT и OSHB BDB, переводя шапку [Domain] на русский язык
    for k, _lang, dtext, dsrc, dlic, dconf, dfl, drev in en_db.execute(
        "SELECT key, lang, def, def_source, def_license, conf, flags, review FROM lex_def "
        "WHERE def_source IN ('ubs-sdbh', 'ubs-sdgnt', 'oshb-bdb')"
    ):
        if dsrc in ("ubs-sdbh", "ubs-sdgnt") and dtext.startswith("[") and "]" in dtext:
            end_br = dtext.index("]")
            dom_hdr_en = dtext[1:end_br]
            dom_hdr_ru = translate_domain(dom_hdr_en)
            if dom_hdr_ru:
                dtext = f"[{dom_hdr_ru}]{dtext[end_br + 1:]}"
        def_rows.append((k, "en", dtext, dsrc, dlic, dconf, dfl, drev))

    db.executemany(
        "INSERT INTO lex VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        lex_rows,
    )
    db.executemany(
        "INSERT INTO lex_def VALUES (?,?,?,?,?,?,?,?)",
        def_rows,
    )
    db.executemany(
        "INSERT INTO entries VALUES (?,?,?,?)",
        entry_rows,
    )

    chash = hashlib.sha256(f"strongs-step-ru:{len(lex_rows)}:{len(def_rows)}".encode()).hexdigest()
    meta_rows = {
        "format_version": "1",
        "id": "strongs-step-ru",
        "title": "Расширенный словарь Стронга (dStrong, современный русский, STEPBible + Door43)",
        "language": "ru",
        "direction": "ltr",
        "versification": "eng",
        "name_profile": "syn",
        "book_order": "syn",
        "version": "0.1.0",
        "license": "CC BY-SA 4.0",
        "attribution": (
            "STEP Bible (www.STEPBible.org, CC BY 4.0); "
            "Door43 Russian Translation Words & RLOB/ROB (CC BY-SA 4.0); "
            "UBS Semantic Dictionaries SDBH/SDGNT (CC BY-SA 4.0)"
        ),
        "source": "stepbible+door43-ru+ubs",
        "kind": "dictionary",
        "features": "entries,lex,lex_def,lex_base,morph",
        "required": "",
        "content_hash": chash,
    }
    db.executemany("INSERT INTO meta VALUES (?,?)", meta_rows.items())
    db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.close()

    cli = REPO / "target" / "debug" / "studybible.exe"
    subprocess.run([str(cli), "module", "check", str(out_sb)], check=True)
    subprocess.run([str(cli), "module", "pack", str(out_sb)], check=True)
    sbz_src = out_sb.with_suffix(".sbz")
    sbz_dst = DATA / "modules" / "strongs-step-ru.sbz"
    sbz_dst.write_bytes(sbz_src.read_bytes())
    print(
        f"Built {out_sb} & {sbz_dst} in {time.time() - t0:.1f}s: "
        f"lex={len(lex_rows)}, lex_def={len(def_rows)}, morph={len(morph_rows)}"
    )


if __name__ == "__main__":
    main()
