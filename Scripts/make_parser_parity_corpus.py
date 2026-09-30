#!/usr/bin/env python3
"""Record what the prototype's parser makes of a corpus of dialogue texts.

The Swift dialogue parser was written from `prototype/demo_anecdote.py` and had
never been compared against it. A disagreement there does not read as a parsing
bug: the turn count decides how many lead-ins the pacing lays down, so a text
split into a different number of turns has its pauses in the wrong places while
every pause constant still matches, and the only symptom is that the app sounds
worse than the demo.

This writes the fixture `theSwiftParserSplitsARealCorpusExactlyAsTheProtoypeDoes`
compares against, so the expected splits are the prototype's own output rather
than values somebody typed.

The texts are invented for this corpus. They reproduce the shapes the live
feeds were measured to carry — one-line narration, several narration lines,
hyphen and em-dash dialogues of two to four turns, narration that sets a scene
before a dialogue or interrupts it, a reply followed by narration — together
with the details a splitter can trip on: `…`, quotes, a dash inside a line, an
attribution after a reply. Third-party texts are not stored in this repository.

Run from the repository root:

    python3 Scripts/make_parser_parity_corpus.py
"""

from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTOTYPE = os.path.join(ROOT, "prototype")
FIXTURE = os.path.join(
    ROOT, "Tests", "PixbarKitTests", "Fixtures", "parser_parity_corpus.json"
)

sys.path.insert(0, PROTOTYPE)
from demo_anecdote import parse_turns  # noqa: E402

# One line of narration.
NARRATION = [
    "Кот считает, что будильник придумали специально для него.",
    "Программист полчаса искал очки, которые были у него на лбу.",
    "Сосед снова начал ремонт ровно в тот момент, когда я сел работать.",
    "Прогноз погоды обещал солнце, поэтому я взял зонт.",
    "Чайник вскипел в третий раз, а чай я так и не заварил.",
    "Утро понедельника - лучшее время, чтобы начать новую жизнь со вторника.",
    "Навигатор уверенно повёл меня в озеро.",
    "Кактус на подоконнике пережил уже три диеты хозяина.",
    "Собака съела домашнее задание, потому что оно было про колбасу.",
    "В лифте пахло чужими выходными.",
    "Я купил тренажёр, и теперь на нём отлично сушится бельё.",
    "Робот-пылесос снова застрял под диваном и, кажется, обиделся.",
    "Весь вечер выбирал фильм, а потом лёг спать.",
    "Пароль должен содержать цифру, букву и слёзы пользователя.",
    "Бабушка считает, что интернет лечится перезагрузкой роутера. И она права.",
    "Велосипед стоял в прихожей так давно, что стал частью интерьера.",
    "Холодильник открыли в сотый раз, но еды там больше не стало.",
    "Совещание, которое могло быть письмом, длилось два часа.",
    "Будильник прозвенел, а сон досмотреть так и не дал…",
    "Вчера я решил лечь пораньше, а сегодня читаю об этом отчёт в 3 часа ночи.",
    "Попугай выучил мелодию звонка и теперь звонит всем сам.",
    "Инструкция к шкафу была толще, чем сам шкаф.",
    "Кофе без сахара, без молока и, к сожалению, без кофе.",
    "Отпуск закончился быстрее, чем зарядка у телефона.",
    "Мой план на выходные: ничего не планировать. Пока получается.",
    "Сосед по даче вырастил тыкву размером с его \"Жигули\".",
    "Электричка пришла вовремя, и все пассажиры растерялись.",
    "Кот уронил со стола всё, кроме того, что действительно стоило уронить.",
    "Нашёл в старой куртке сто рублей и почувствовал себя миллионером.",
    "Лето прошло - я даже не успел в него переодеться.",
    "Мама позвонила спросить, не замёрз ли я. В июле.",
    "Решил не спорить с навигатором и приехал в соседний город.",
    "Ёжик в тумане искал лошадку, а нашёл вайфай.",
    "Сегодня я был продуктивен: переставил иконки на рабочем столе.",
]

# Several lines of narration, no dialogue.
LONG_NARRATION = [
    "Утро.\nКофе.\nПонедельник.",
    "Купил новый ноутбук.\nНастроил его за выходные.\nТеперь не помню, зачем покупал.",
    "Жена попросила вынести мусор.\nЯ вынес.\nТеперь она просит вернуть пакет с документами.",
    "Пришёл на работу пораньше.\nОфис закрыт.\nСегодня суббота.",
    "Сварил суп.\nПосолил.\nПопробовал.\nПосолил ещё раз.\nЗаказал пиццу.",
    "Сидят два кота на крыше и смотрят на луну.\nОдин говорит, что она сырная.\n"
    "Второй молчит - он на диете.",
    "Воскресенье.\nДождь.\nПлед.\nКнига.\nЧай.\nКот.\nТишина.\nСосед включает дрель.\n"
    "Снова тишина.\nСнова дрель.\nЯ беру книгу.\nИ ухожу к маме.\nТам тоже ремонт.",
]

# Hyphen dialogues.
HYPHEN_DIALOGUES = [
    "- Ты купил хлеб?\n- Я купил торт. Это почти хлеб, только праздничный.",
    "- Доктор, я всё забываю!\n- С каких пор?\n- Что с каких пор?",
    "- Почему ты опоздал?\n- Будильник решил, что мне нужно выспаться.",
    "- Как твоя диета?\n- Отлично, уже третий день начинаю её с понедельника.",
    "- Ты где?\n- Уже выхожу.\n- Ты же ещё в пижаме!",
    "- Сколько стоит этот кактус?\n- Пятьсот рублей.\n- А без колючек?\n- Это огурец, он дешевле.",
    "- Папа, а почему небо синее?\n- Спроси у мамы, она всё знает.",
    "- Вы нашли мой зонт?\n- Нашли, но он ушёл домой сам - дождь кончился.",
    "- Как дела на работе?\n- Как в сказке: чем дальше, тем страшнее.",
    "- Ты помыл посуду?\n- Я её замочил. На неделю.",
    "- Что ты делаешь?\n- Жду вдохновения.\n- А оно знает, что ты ждёшь?",
    "- Почему кот сидит на ноутбуке?\n- Он тоже работает удалённо.",
]

# Em-dash dialogues.
DASH_DIALOGUES = [
    "— Ты почему не спишь?\n— Считаю овец, но одна всё время сбивается.",
    "— Ты завтракал?\n— Да, кофе.\n— Это не завтрак.\n— Тогда два кофе.",
    "— Ты спишь?\n— Неее, я просто закрыла глаза и слушаю дождь...\n"
    "— Но дождя нет!!!\n— Я его слушаю по памяти.",
    "- Сеть быстрого питания «Вкусно — и точка» открыла кафе прямо в библиотеке.\n"
    "- Теперь книги будут читать с кетчупом?",
]

# Narration that sets the scene, interrupts, or follows a dialogue.
MIXED = [
    "Звонок в дверь:\n- Здравствуйте, я сантехник!\n- А я вас не вызывал…\n"
    "- Ничего, я подожду, пока вызовете.",
    "- У меня кот каждое утро будит меня в пять утра, представляете?\n"
    "Я ложусь - он спит, встаю - он спит! И ведь кто-то меня будит!\n"
    "Лично я его ни разу за этим не видел...",
    "Вечер пятницы. Офис пустеет. Уборщица выключает свет.\n"
    "В углу за компьютером сидит последний сотрудник.\nОна подходит.\n"
    "- Молодой человек, все уже ушли!\nОн поднимает глаза и отвечает:\n"
    "- Я не сотрудник, я \"стажёр\".\n"
    "- А что же вы тогда тут делаете так поздно? - удивляется уборщица.\n"
    "- Жду, когда меня возьмут на работу.",
    "Маленькая пекарня. Утро. Два пекаря спорят о рецепте.\nЗаходит покупатель:\n"
    "- А где булочки с маком?\nПекарь, не отрываясь от теста:\n- А зачем вам с маком?\n"
    "- Понимаете, я их каждый день беру, уже привык.\n"
    "- Вы посмотрите на него! Мак кончился ещё в среду, а он только сейчас заметил!",
    "На собеседовании:\n- У вас в резюме написано, что вы стрессоустойчивы?\n"
    "- Да, я уже третий год живу с котом.",
]


def corpus() -> list[tuple[str, str]]:
    texts = NARRATION + LONG_NARRATION + HYPHEN_DIALOGUES + DASH_DIALOGUES + MIXED
    return [(f"invented:{index:02}", text) for index, text in enumerate(texts)]


def main() -> int:
    items = corpus()
    document = {
        "capturedOn": "invented",
        "source": "texts written for this corpus in Scripts/make_parser_parity_corpus.py",
        "splitBy": "prototype/demo_anecdote.py parse_turns",
        "anecdotes": [
            {
                "id": guid,
                "text": text,
                "turns": [
                    {"speaker": speaker, "text": line}
                    for speaker, line in parse_turns(text)
                ],
            }
            for guid, text in items
        ],
    }

    with open(FIXTURE, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=1)

    turns = sum(len(a["turns"]) for a in document["anecdotes"])
    dialogues = sum(
        1
        for a in document["anecdotes"]
        if any(t["speaker"] != "narrator" for t in a["turns"])
    )
    print(f"{len(items)} texts, {turns} turns, {dialogues} with dialogue -> {FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
