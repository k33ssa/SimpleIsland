# Сторонний код и идеи

| откуда | лицензия | что взято | где |
|---|---|---|---|
| [Hidden Bar](https://github.com/dwarvesf/hidden) (Dwarves Foundation) | MIT | идея и числа разделителя строки меню: свой `NSStatusItem`, длина развёрнутого — 2× ширины самого широкого экрана, не меньше 500 и не больше 10000 pt; пересчёт при смене экранов; `isVisible = true` при каждом создании (⌘-утащенный за строку значок система помечает невидимым). Код написан заново. | `Sources/MenuBarModule/MenuBarDivider.swift`, `MenuBarLogic.swift` (`MenuBarDividerMath`) |
| [Ice](https://github.com/jordanbaird/Ice) (Jordan Baird) | GPL-3.0 | **код не брали** — только понимание подхода: перенос чужого значка синтетическим ⌘-перетаскиванием с номером окна в полях события, временный показ спрятанного значка для клика | `Sources/MenuBarModule/MenuBarMover.swift` (своя реализация) |
| LyricsCore (собственный пакет автора, проект apple-music-native-lyrics) | MIT | движок текстов песен (разбор TTML/LRC, поиск и сопоставление, каскад источников, кэш); копия внутри репозитория, не сторонний код | `Vendor/LyricsCore` |

Текст лицензии MIT Hidden Bar:

```
MIT License

Copyright (c) 2019 Dwarves Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
