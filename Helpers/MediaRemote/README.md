# SimpleIslandMR — «что играет» для модуля «Медиа»

С macOS 15.4 MediaRemote отвечает только процессам Apple. `/usr/bin/perl` — платформенный бинарник Apple, поэтому
модуль запускает `perl -e '<загрузить dylib и вызвать simpleisland_mr_run>' SimpleIslandMR.dylib` (DynaLoader), и
наша библиотека работает «как perl» (docs/TECH.md §1). Код свой, ~250 строк ObjC.

* Сборка: `scripts/build-media-helper.sh [каталог]` (по умолчанию — каталог отладочного бинарника
  `.build-main`, свой scratch — `SIMPLEISLAND_SCRATCH`); `scripts/build-app.sh` кладёт её в
  `SimpleIsland.app/Contents/Resources` (блок `# --- media ---`) и подписывает той же идентичностью, что и `.app`.
* Поиск библиотеки в приложении: `$SIMPLEISLAND_MR_DYLIB` → `Contents/Resources` → каталог исполняемого файла.
* Режимы (`SIMPLEISLAND_MR_MODE`): `stream` (по умолчанию; JSON-строки в stdout, команды строками в stdin:
  `play|pause|toggle|next|prev|stop|seek <с>|speed <x>|refresh|sendto <bundle> <код>`, конец stdin → выход;
  первой строкой — `{"type":"caps","sendToApp":bool}`), `get`, `probe`, `thumb`
  (самотест: уменьшить картинку из `$SIMPLEISLAND_MR_THUMB`).
* Обложку помощник уменьшает сам (ImageIO, ≤ 600 px, JPEG 0,85; ≤ 600 px и ≤ 512 КБ — как есть; не уменьшилась и
  > 2 МБ — не шлёт): строка — сотни КБ, а не десятки МБ base64 исходного PNG (самотест: PNG 3000×3000 17 МБ →
  600×600, base64 98 КБ). `artworkId` — по исходным байтам. Нужны `-framework ImageIO -framework CoreGraphics`.
* Протокол — в шапке `SimpleIslandMR.m`. Swift-сторона — `Sources/MediaModule/MediaRemoteSource.swift`
  (перезапуск с паузой 2→60 с; три быстрых падения подряд или код 3 «MediaRemote недоступен» → AppleScript).

* **`swift build` библиотеку не собирает.** Без ручного `scripts/build-media-helper.sh` отладочный бинарник
  работает только через AppleScript (Музыка, Spotify); в настройках модуля тогда видно предупреждение.

Проверено 14.11.2026 на macOS 15.5: `probe` и `get`/`stream` (чтение) из perl — данные приходят (Chrome, обложка
JPEG 768×768). Команды (play/pause/next/prev/seek/speed) **не проверялись** живьём — чтобы не трогать воспроизведение
пользователя; номер команды скорости (19, `kMRMediaRemoteOptionPlaybackRate`) — по памяти [догадка]. Поэтому
Swift-сторона ждёт подтверждения скорости по `PlaybackRate` 2 с; нет — откатывает и прячет кнопку для приложения.

Chrome (проверено 14.11.2026, видео на паузе во вкладке): шлёт уведомление раз в секунду с `playing:true`, тем же
`ElapsedTime` и новыми `Timestamp`/`CurrentPlaybackDate`/`ContentItemIdentifier`, через раз — без `ArtworkData`.
Помощник отсеивает такие повторы (было ~2 строки/с, стало 4 строки за 15 с) и через 2,5 с застывшей позиции отдаёт
`"playing":false,"stalled":true` — компакт перестаёт анимироваться, позиция не откатывается.

Ручная проверка чтения:
```sh
scripts/build-media-helper.sh /tmp/mr
SIMPLEISLAND_MR_MODE=get /usr/bin/perl -e 'use DynaLoader; my $h=DynaLoader::dl_load_file($ARGV[0],0) or die;
  DynaLoader::dl_install_xsub("main::run", DynaLoader::dl_find_symbol($h,"simpleisland_mr_run")); run();' /tmp/mr/SimpleIslandMR.dylib
```

`sendto` (work/keys, 15.11) — медиаклавиши «последнему музыкальному приложению», не Музыке/Spotify:
`MRMediaRemoteSendCommandToApp(код, NULL, NULL, bundle, 0, NULL, NULL)`. Сигнатура — по чужим разборам [догадка]:
аргументы подобраны так, чтобы и при 6-аргументной версии на места очереди/completion пришли NULL. **Вживую не
проверялось.** Если помощник выходит в течение 3 с после `sendto`, Swift-сторона (`MediaRemoteSource.sendToAppBroken`)
до конца запуска больше его не шлёт и клавиши для таких приложений идут системе.
