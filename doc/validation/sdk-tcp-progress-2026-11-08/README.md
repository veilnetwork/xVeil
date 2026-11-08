# NETCALL-01: TCP byte progress в opt-in SDK trace

**Добавлена диагностика; устранение NETCALL-01 не заявляется.**
После [контроля профиля сокетов](../sdk-socket-profile-control-2026-11-08/README.md)
SDK теперь снимает Linux/Android TCP_INFO sent/acked/received/retransmitted
bytes, число текущих повторов RTO и backoff. Это накопительные счётчики
TCP-соединения, а не отдельного звонка, доставки кадра или слышимости речи.
Socket binding дополнен readback MSS, send buffer и TCP_NOTSENT_LOWAT.
Socket options, wire, аудио, retry policy и криптографические барьеры не менялись.

Дополнительные поля читаются только внутри фактически возвращённой ядром
длины. Короткий ответ означает `None`, поддерживаемый нулевой счётчик —
`Some(0)`. Native-endian UAPI offsets проверены предшествующим Android NDK
контролем. На Apple новые Linux-счётчики остаются `None`; readback LOWAT
проверен на macOS. Диагностика включается существующим operator opt-in,
не добавлена в анонимный пользовательский экспорт.

## Проверки

* Новый тест настоящего TCP echo на Poco сначала упал на прежнем SDK:
  данные переданы и проверены, но `sent_bytes` отсутствует в снимке.
* После исправления на Poco прошли 12 тестов `tcp_trace::`, включая echo,
  readback LOWAT 4096, сохранность wire/options и все усечённые префиксы
  TCP_INFO. Native test binary собран заново, его SHA отличается от красного.
* macOS: 11 тестов этой группы; Linux-only echo не засчитан как Mac-проверка.
* Scoped release Clippy — без предупреждений.
* Flutter journal tests — 19; AOT privacy gate — 1 тест с двумя сборками
  diagnostics on/off. Частные ключи и числовые canary не экспортируются.

Android fixtures/processes удалены, main/QA APK и QA root container не
изменились. Приложения и радио для unit-проверки не запускались/не менялись.
Сборки наблюдали реальный внешний mount и свободное место; cache targets
других checkout не использовались. До сборки удалены только два прежних
собственных rebuildable probe target, около 0,8 ГБ.

Следующий шаг — пересобранная FFI и настоящий звонок Poco↔Mac через два
изолированных Core с минимальным host polling. Unit echo не квалифицирует
этот путь. Исходные журналы и socket metadata остаются private.
Коммиты без подписи, push/релиза нет.

Продолжение: [физическая проверка на Poco](../sdk-tcp-progress-call-2026-11-08/README.md).

Счёт journal tests уточнён по machine report: 19 успешных видимых tests,
а не 20. Повтор для проверки счётчика не считается дополнительным покрытием.
