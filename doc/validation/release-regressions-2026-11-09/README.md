# Исправления по полному релизному прогону

Релиз ещё не опубликован. Полный анализ исходного дерева был чистым, но
полный Dart suite выявил две регрессии и несогласованные предусловия тестов.

## Обычная коррекция порядка при удалении

Body-less correction из обычного canonical mirror ошибочно использовала
барьер подготовленной history-публикации. Если delete уже сканировал журнал
и удерживал storage scrub, correction завершалась ошибкой вместо того,
чтобы дописать безвредные метаданные; tombstone всё равно должен побеждать.

Барьер сохранён у prepared ordering batch с `beforeCommit`, включая
удаление во время асинхронного admission callback. Обычная correction
возвращена к существующей семантике oversized body-less пути. Проверены
оба сценария: correction не восстанавливает удалённое сообщение после
scrub/reopen; prepared batch не публикует unadmitted metadata.

## Принятая реакция при закрытии

Уточнение consent-cache сделало `disposed` частью любой проверки контактной
ревизии. Поэтому inbound reaction, уже допущенная в lane и ожидающая
contact read, пропадала при dispose, хотя lifecycle реакций явно дожидается
этой lane до закрытия storage.

Только admitted reaction может завершить чтение при drain. Проверка актуальной
контактной ревизии сохранена; положительный realtime cache не пополняется
после dispose. Offer/P2P и остальные новые control admission по-прежнему
отказывают закрытому owner. Новые inbound frames не обходят входной gate.

## Исправления проверки

- Native-only варианты теперь явно требуют `XVEIL_HV_DYLIB`, как остальные
  native gates. Без библиотеки — отдельный skip, а не ложный провал продукта.
  С явно выбранной библиотекой ошибка загрузки продолжает проваливать тест.
- Скан subprocess перечисляет Windows-only opt-in audio helper. Его sampler
  отказывает до reader на остальных платформах; guard не ослаблен для иных
  новых subprocess.
- Snapshot-тест проверяет актуальный контракт: вся transfer image durable
  до первого live send, live attempts сериализованы и awaited при обычной
  отправке. Отказ инжектируется на реальном atomic commit, а не на обходящемся
  после transfer-batching single-frame override. Проверено отсутствие отправок
  и видимой неполной копии при отказе, затем успешный повтор.

## Проверка

- Исходный полный прогон зафиксировал assertion failures; он не зачтён зелёным.
- Ordering/append, reactions, consent-close и mobile subprocess guards:
  **83 passed / 17 skipped**; native варианты в этом запуске не заявлены.
- Consent/reactions и policy races с явно выбранной release HVS eceb915:
  **113 passed**, включая native варианты. SHA библиотеки и source revision
  совпали с retained build proof; новый бинарник этим не подменялся.
- Native expiry/archive/resume gate на той же библиотеке:
  **22 passed / 3 skipped** (отдельные download-resume opt-in сценарии).
- Актуальные group source tests: **4 passed**.

Повторный полный локальный прогон: **7 842 passed / 454 skipped**; анализ Flutter
чистый. Финальные версии зависимостей и release CI остаются отдельными гейтами;
эти результаты не заменяют проверку tagged tree.

## Опубликованная hidden-volume 2.7.0

Полная платформенная CI-матрица прошла до тега. Проверены подпись Sigstore
с точной identity релизного workflow и контрольные суммы всех 12 опубликованных
бинарников. Опубликованная библиотека macOS arm64 побайтово совпала с CI-библиотекой,
на которой дополнительно прошли **155 проверок xVeil без пропусков**: consent,
reactions, независимая контактная политика, ordering recovery и append batches,
включая native-варианты. Это свежая 2.7.0, а не прежняя локальная библиотека.

Затем полный Flutter suite с явно заданной опубликованной библиотекой HVS:
**8 097 passed / 199 skipped**, анализ Flutter чистый. Это включает ранее
перечисленные native-проверки; числа отдельных прогонов не суммируются.
Оставшиеся opt-in сценарии не объявлены пройденными.

Источник: [hidden-volume v2.7.0](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.7.0),
[предрелизная матрица](https://github.com/veilnetwork/hidden-volume/actions/runs/42566337821).
