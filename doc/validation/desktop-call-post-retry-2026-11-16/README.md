# Повтор уведомления о входящем desktop-звонке

База `f9ca52a6`. Продолжение [desktop-alert пути](../desktop-incoming-call-alerts-2026-11-13/README.md).

## Подтверждено

Ключ desktop-alert отмечался обработанным до результата `showIfCurrent`.
При отказе или исключении native post повторный вызов `_syncDesktopAlert`
с тем же звонком сразу завершался по совпадению ключа. Живой ringing оставался
без системного alert; повторного offer или событий UI для ремонта быть не должно.

Два assertion-red на исходной базе: backend отказал один раз через false или
исключение, затем готов принимать post, но второй попытки нет. Использованы
настоящий CallService и fake notification backend. Это воспроизведение ошибки
политики приложения; временный отказ настоящей Windows в этом раунде не вызван
и причиной жалобы пользователя не объявляется.

## Изменение

После отказа post выполняются до трёх повторов через 1, 2, 4 секунды. На один
alert-ticket — максимум четыре попытки, один OS notification ID и прежняя
последовательная очередь. Обычные изменения состояния с тем же ключом не
обнуляют лимит. Успешный post не повторяется.

Повторы отменяются при завершении звонка, foreground, отключении уведомлений,
смене личности, preview-policy, новом звонке и dispose. Перед каждой попыткой
проверяются owner/call ID/startedAt/generation и готовность backend. Старый
отложенный post или cancel не может стереть уведомление нового звонка.
Политика hidden preview и фиксированный opaque payload сохраняются.
Ошибки фиксируются прежними числовыми `callAlert` outcomes, без исключений
или приватных полей в diagnostics.

Отказ инициализации backend здесь не перезапускается. В используемом Windows
plugin 3.1.1 initialize присваивает `late final` native handle до результата;
автоматический повтор initialize на той же instance не является безопасной
заменой повтору post. Есть отдельный контроль: неготовый backend не получает
циклические init/post от одного ringing. Восстановление backend после init
failure и видимость настоящего toast остаются отдельными границами.

## Проверки без перехвата управления

- 14 новых widget cases: false/exception, ограничение повторов, пять причин
  отмены, следующий caller, смена privacy-policy, неготовый backend, поздний
  отказ, скрытие в трей и групповой retry. Вместе с прежними — 24 cases.
- Scheduling проверяется виртуальными часами WidgetTester, не порогом реального
  времени. Долгий пост не порождает наложенных попыток.
- Для tray-интеграции смонтирован настоящий DesktopTrayHost вместе с
  CallLifecycleBridge и живым CallService. Подменены window/tray channels,
  preference/controller и источники истории: реальных профилей или OS-окон нет.
  Реальный обработчик close вызывает hide, не destroy/show/focus; после
  явно поданного hidden-lifecycle входящий offer вызывает ringing и post.
  После unmount window listeners отсутствуют. Preference persistence проверяет
  отдельный существующий close-to-tray test; native Windows события окна,
  видимость tray icon и фактического toast этим не доказываются.
- Итоговая серия с diagnostics и ранее верифицированной native HVS:
  **330 passed, 0 skipped / 23 файла**. Включает оба contact-decision исправления,
  атомарность/ACK/consent, reconnect, notifications, tray, camera state и chat UI.
- Analyzer runtime-файла и всего `test` чистый; diff check чистый. Новых ABI,
  native builds, engine pins и production deployment нет.

Первый вариант правки содержал неверный синтаксис catch и был отклонён
formatter до запуска тестов; это не product reproduction. Зачтённые red —
именно два assertion failures на прежнем runtime, green — итоговое дерево.

Все тесты headless, `TMPDIR=/private/tmp/`. Новые пользовательские app/stand
окна не запускались, Windows/телефон и real Mac app не использовались для
взаимодействия. Мышь, клавиатура и фокус не менялись. Изменение локальное,
без push/релиза; исходная жалоба Windows 10 остаётся открытой.
