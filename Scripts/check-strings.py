#!/usr/bin/env python3
# Ключи перевода совпадают с кодом: каждая строка, которую код выводит на экран,
# есть в обоих Resources/*.lproj/Localizable.strings. Первый шаг build.yml;
# у себя — ./Scripts/check-strings.py из любой папки репозитория.
#
# Ловятся оба пути локализации: явный localized(...) и литералы, которые SwiftUI
# локализует сам — Text("…"), Button("…"), TextField("…") (#12). Литералы с
# интерполяцией — не ключи, они отбрасываются. Как и литералы без единой буквы:
# "0" в пустом поле ввода и "—" в прочерке переводить нечем, а проверка
# требовала для них ключ и красила PR красным ни за что.
#
# Проверка в одну сторону: ключ, оставшийся в таблицах без кода, она не видит.
import io, os, pathlib, re, sys

os.chdir(pathlib.Path(__file__).resolve().parent.parent)

pat = re.compile(r'\b(?:localized|Text|Button|TextField)\(\s*"((?:[^"\\]|\\.)+)"')
code = set()
for p in pathlib.Path("Sources").rglob("*.swift"):
    for m in pat.finditer(io.open(p, encoding="utf-8").read()):
        key = m.group(1)
        if "\\(" in key or not any(c.isalpha() for c in key):
            continue
        code.add(key.replace("\\n", "\n"))
bad = False
for table in pathlib.Path("Resources").glob("*.lproj/Localizable.strings"):
    text = io.open(table, encoding="utf-8").read()
    keys = {k.replace("\\n", "\n") for k in re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}
    missing = code - keys
    if missing:
        bad = True
        print(f"{table}: нет ключей: {sorted(missing)}")
sys.exit(1 if bad else 0)
