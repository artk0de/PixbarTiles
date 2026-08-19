"""Cases pinning the female-speaker rule.

These are the acceptance set for the Swift port too: the same inputs must give
the same verdicts there, or the app will not sound like the prototype it was
signed off from.

Run: python3 test_gender.py
"""
import sys

from demo_anecdote import speaker_genders

CASES: list[tuple[str, list[str], dict[str, str]]] = [
    # --- the signal we are actually after -------------------------------
    (
        "a woman speaking about herself",
        ["Ты спишь?", "Неее, я просто закрыла глаза и слушаю дождь..."],
        {"actor1": "female"},
    ),
    (
        "reflexive -лась counts",
        ["Ну что?", "Я улыбнулась и ушла."],
        {"actor1": "female"},
    ),
    (
        "the verb may come before the pronoun",
        ["Где была?", "Опоздала я на работу."],
        {"actor1": "female"},
    ),
    # --- men, so the female voice is not handed out by default ----------
    (
        "a man speaking about himself",
        ["Здравствуйте! Я подъехал…", "Иду."],
        {"actor0": "male"},
    ),
    (
        "masculine reflexive",
        ["Я умылся и побрился.", "Молодец."],
        {"actor0": "male"},
    ),
    # --- the traps that make a bare -ла suffix unusable -----------------
    (
        "a noun ending in -ла is not a verb",
        ["Я сила!", "Ну-ну."],
        {},
    ),
    (
        "a feminine verb about somebody else does not out the speaker",
        ["Она закрыла дверь, а я ушёл.", "И что?"],
        {"actor0": "male"},
    ),
    (
        "distance kills it: the verb is four tokens from the pronoun",
        ["Дверь закрыла соседка сверху, я слышал.", "Ага."],
        {"actor0": "male"},
    ),
    (
        "no first-person pronoun at all, so no verdict",
        ["Пришла, увидела, победила.", "Классика."],
        {},
    ),
    (
        "меня is not я",
        ["У меня сила воли железная.", "Проверим."],
        {},
    ),
    # --- stability ------------------------------------------------------
    (
        "a line carrying both signals decides nothing — it is reported speech",
        ["Я пришёл домой. Потом я устала от всего этого.", "Бывает."],
        {},
    ),
    (
        "first signal wins, so a speaker does not change sex mid-anecdote",
        ["Я устал.", "Ну?", "Вчера я купила машину."],
        {"actor0": "male"},
    ),
    (
        "the narrator is never assigned a sex",
        ["Заходит женщина в бар и говорит, что она устала."],
        {},
    ),
]


def turns_from(lines: list[str]) -> list[tuple[str, str]]:
    """Actor lines are dash-marked, exactly as the feed writes dialogue."""
    from demo_anecdote import parse_turns

    return parse_turns("\n".join(f"— {line}" for line in lines[:-1] + [lines[-1]])
                       if len(lines) > 1 else lines[0])


def main() -> int:
    from demo_anecdote import parse_turns

    failures = 0
    for name, lines, expected in CASES:
        # A single line with no dash is narration; several lines are a dialogue.
        text = "\n".join(f"— {l}" for l in lines) if len(lines) > 1 else lines[0]
        actual = speaker_genders(parse_turns(text))
        if actual == expected:
            print(f"  ok    {name}")
        else:
            failures += 1
            print(f"  FAIL  {name}")
            print(f"        expected {expected}")
            print(f"        actual   {actual}")

    print(f"\n{len(CASES) - failures}/{len(CASES)} pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
