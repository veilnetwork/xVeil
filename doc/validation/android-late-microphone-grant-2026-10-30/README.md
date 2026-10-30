# Первый звонок: позднее разрешение микрофона Android

Дата: 2026-10-30. Исправление поверх xVeil `2b5a666a`; нативный SDK
`08b67a6e` не пересобирался. В SDK `3b891089` Dart API veil_media добавлен additive
`trySetMicMuted`: возвращает настоящий результат существующего C ABI.
Прежний void `setMicMuted` сохранён. Без push, релиза и изменений реле.

## Подтверждённый дефект

На Blackview с новым отдельным QA-профилем начат P2P видеозвонок на Mac.
Микрофон Android включён; Mac намеренно muted. Оба runtime permission изначально
закрыты. Ответ на первый настоящий системный prompt намеренно отложен минимум
на восемь секунд. По журналу базовой сборки:

1. Общий permission preflight заканчивается через штатные 3 с.
2. Нативный audio start пытается открыть запись без RECORD_AUDIO, возвращает
   false; CallService завершает connecting с `mediaStartFailure`.
3. В срезе +10,254 с оба call slot уже очищены, оба grant ещё false.
4. После этого ОС выдаёт разрешения; звонок уже закончился.

Это воспроизведённый сбой старта, а не доказанная причина исторического
обрыва через 25,094 с и не доказанная причина жалобы Windows 10 на тихий звук.
В предыдущем раунде оба микрофона были muted, поэтому этот путь не проверялся.

## Исправление

CallMicrophonePermission держит начальный capture muted, пока настоящий ответ
ОС и попытка typed foreground service не завершились. Receive pipeline и
сигнализация запускаются в прежнем бюджете. После grant восстанавливается
**текущий** mute intent только того же call/engine/media epoch. Hangup,
замена engine/звонка и отказ не открывают запись. Действия mic toggle во время
prompt также проходят через тот же permission gate.

CallMicrophoneState не подменяется фиктивным пользовательским mute: приложение
сохраняет намерение человека отдельно от временно закрытого capture. Отказ ОС
оставляет receive-only режим. Уже разрешённый, но неисправный audio device
по-прежнему даёт отказ audio start. Поздний нативный отказ при unmute проверяется
через `trySetMicMuted` и записывается как неуспех в диагностике.

Таймауты 3-секундного preflight, 8/30-секундного media start и liveness не
увеличены. Wire, ratchet, mailbox и политика реле не менялись. Это не адаптация
потерь и не изменение усиления аудио.

## Проверки

- **310 Flutter tests passed**: microphone/camera state, Android foreground,
  CallService, group media, receive activity/route operations, export ceremony,
  diagnostic journal/background.
- Новые microphone state тесты: pending grant, отказ, изменения mute в обе
  стороны, hangup, новый call/engine и уже выданное разрешение. Проверяется
  возможность receive-only старта при недоступном input; это модель ADM отказа,
  не отдельный запуск прежнего бинарника. Красное воспроизведение — физический
  прогон базового APK, описанный выше.
- Один Flutter/native FFI smoke с маленькой C fixture: реальный Dart wrapper
  получает false при native refusal, true после retry, mute не блокируется,
  disposed engine не вызывает native. Это не аппаратный audio test. Первоначальный
  обычный Dart runner не поддержал Flutter/dart:ui dependency; зачтён только
  исправленный Flutter runner. Smoke запускается явно, не входит в обычное
  автоматическое обнаружение SDK unit-тестов без fixture.
- Python AOT gate: реальный production journal с diagnostics=true/false;
  приватные canary не экспортируются, без opt-in evidence пустое.
- Анализ пяти изменённых Dart-файлов: No issues found. Android profile/AOT
  собран со staged native SDK, SHA всех native media/storage/core проверены;
  hardware/media test hooks и низкая PoW difficulty не включались.

В диагностике добавлены только source-owned события microphonePermission /
cameraPermission и state -1/0/1 (ожидание/отказ/grant). Последний результат
каждого сохраняется при переполнении сетевого кольца. Пути, тексты ОС, имена,
контакты и содержимое микрофона в эти события не попадают.

Дополнительно собран release-mode APK с diagnostics=true, debug API=false и
release raw logging=false. Настоящий AOT APK прошёл
`scripts/verify-diagnostic-artifact.py`: structured instrumentation присутствует,
raw Dart log sink отсутствует. Он подписан только локальным QA debug key,
не устанавливался и не распространялся; физические звонки выше используют
отдельный profile stand APK с приватным developer logging.

Проверка правильно отклонила profile-вариант, где non-product logging активен
даже при release raw logging=false. Промежуточная ошибочная метка успеха из
драйвера, который не остановился на ненулевом exit code, отозвана. Итоговая
метка создана только после verifier с check=True и проверки подписи. Это
исправление квалификации артефакта, не изменение рабочего logger policy.

## Физический результат

На том же отдельном QA package установлен текущий production Dart и Android
код. Системные разрешения отозваны только у этой синтетической инсталляции;
OS prompts снова подтверждались через настоящий Android UI, без `pm grant`.
Контейнер и ratchet между попытками не откатывались. Первоначальный node PoW
завершился до звонков и не включался в их времена. Первое ограниченное ожидание
драйвера истекло во время mining; процесс был жив и использовал CPU. Без
перезапуска дождались готовности; этот timeout не считается падением узла.

В первом повторе +10,204 с оба звонка **active**, оба grant ещё false. После
выдачи разрешения capture автоматически запустился; звонок оставался active
до штатного отбоя около 90 с. На последнем срезе Mac принял **1187 audio RTP**,
Android/Mac отправили **1918/1824 video frames**, оба получали видео. Отсутствие
аудиопакетов в обратную сторону ожидаемо: микрофон Mac был выключен.

Во втором повторе микрофон Android выключается через API во время открытого
permission prompt. После позднего grant оба endpoint оставались active до
39,618 с, mic-on на Android false, audio RTP у обоих получателей **0**;
Android/Mac отправили **419/854 video frames**. Журнал подтвердил применение
grant с captureMuted=true. Итоговые счётчики и teardown записаны в `result.json`.

Речь и картинки не записывались; автоматические RTP/кадровые счётчики не
доказывают разборчивость или субъективную громкость. Другие OEM, длительный
фон, Win10 и историческое завершение 25 с этим не закрыты.

## Уточнение сертификатного наблюдения

Повтор с QA-only export stage logs на исходной production логике показал:
файл 3146 байт точно совпадает с показанным сертификатом; native result,
Dart result и finally пришли; видимая Continue после прокрутки сработала,
затем обычный onboarding завершился. Отсутствие `focusable` не является
`disabled`; прежняя попытка нажимала скрытую кнопку. Вывод о подтверждённом
зависании снят. Рабочий export-код не менялся; для итогового APK вся QA-only
стадийная трассировка удалена. Прежний отчёт исправлен с сохранением объяснения.

Сырые UI/журналы/идентификаторы и SHA лежат в приватном каталоге. Публичный
`result.json` содержит только агрегаты и результаты проверок. Итоговый teardown
подтвердил выход приложений, отсутствие microphone service после отбоя, удаление
отдельного QA package/его сертификата и forward. TCP LISTEN/UDP owners отсутствуют,
bind с SO_REUSEADDR проходит; первый bind без reuse встретил TIME_WAIT и не
использовался как свидетель живого приложения. SHA прежнего QA APK, его preferences,
общая stand metadata, radio/whitelist независимо проверены; основные приложения
не заменялись. Удалён примерно 1 ГиБ собственных build/.dart_tool файлов;
сохранены проверенные baseline/candidate и диагностический release-mode APK.
Закрытая копия исходников стенда также удалена. Контейнеры не откатывались.
