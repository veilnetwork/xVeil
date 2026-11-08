# NETCALL-01: частые TCP snapshots внутри NIC-пауз

**NETCALL-01 открыт. Добавлена диагностика, исправление пауз не заявляется.**
[Предыдущий capture](../sdk-nic-gaps-2026-11-08/README.md) оставлял внутри
секундных NIC DATA silences по одному TCP snapshot или ни одного. Дельты
sender counters строго внутри тех окон нельзя было доказать.

## Диагностика

SDK `bbcd967a`: отдельный операторский `VEIL_DIAG_TCP_FINE=1` / Android
`debug.xveil.tcp_fine=1`, **только при включённом RT trace**. Дополнительная
запись не чаще раза в 100 мс на connection, lease 180 с без продления,
8192 fine rows на весь процесс; затем прежний секундный режим. Socket queries
не добавлены: сохраняются уже снимавшиеся snapshots. Wire/options, retry,
аудио и авторизация не менялись. Это private operator log, не пользовательский
анонимный отчёт; payload, адреса и приложение-роль не добавлены.

Mac — 13 tests, Poco — 14, без ignored в выбранной группе; остальные filtered
cases не считаются пройденными. Реальный TCP проверяет wire и обе opt-in gates,
включая неверное значение `true`; общий лимит и lease проверены отдельно.
Scoped release Clippy и 19 diagnostic journal tests прошли. Эти counters
по-прежнему не входят в anonymous export allowlist.

## Настоящий звонок

Poco ↔ Mac, P2P явно запрещён, два изолированных Core `e974cebe`.
Новая Android FFI; Mac FFI заморожена на `c8f4929b`; frontend/media/HVS прежние.
Сборка проверена по замороженным исходникам и SHA, 208 C exports и прочие
ZIP payload не изменены, signer/16-KiB alignment проверены. Native journal
снят только с PID QA-приложения; наблюдались **2235 fine snapshots**.
Точная побайтная проверка установленного candidate APK в живом процессе
отдельно не выполнялась; новая диагностика наблюдается по PID, packaging
provenance и успешной установке. Проверка rollback APK до/после выполнена.

Wi-Fi 15 с → Cellular 90 с → Wi-Fi 15 с. Внутри интервалов host не опрашивал
телефон; collector работал локально. Host ADB оставался включён — это не
контроль влияния самого ADB daemon. Звонок сохранился, audio counters обоих
концов продвинулись. Слышимость человеком и Windows не проверялись.

На Cellular native RX age до 1261 мс у Poco / 1154 мс у Mac. Два непрерывных
Mac RX plateau: нижние границы **1025,657 / 1018,180 мс**. Строго внутри
сформированы 9 разных audio cells; все 9 найдены в позднем authenticated RTP.
18 физических копий прошли first write до конца plateau: RTP→write
1,605–3,872 мс, write→flush 0,060–0,439 мс. Все 18 matching Core reads точно
после plateau; read→authenticated frame 0,029–0,371 мс. Остальной трафик звонка
не объявляется полностью доставленным по этим девяти клеткам.

По authenticated reader binding все 18 копий сопоставлены с TCP flows
двух Core. В каждой из четырёх flow/plateau наблюдений: NIC DATA silence
1109,985–1360,128 мс, затем matching read за 0,108–6,728 мс. Длительных
наблюдаемых sequence holes рядом с reads нет. В первой паузе есть ACK-only
packets; это не полное отсутствие всех пакетов.

**Новое звено:** после clock bounds внутри соответствующих NIC DATA silences
остались 4/4 и 2/2 sender snapshots. Во всех четырёх наблюдениях `acked_bytes`
стоит, `sent_bytes` растёт: 4999/5255 и 1217/1023 Б. В первой паузе ещё растут
`retransmitted_bytes`: 433/586 Б; во второй — 0. Во всех выбранных snapshots
`notsent_bytes=0` — это не обещание непрерывно пустой очереди между ними.
Дельты относятся к TCP flow, несущему нужные audio records, а не исключительно
к байтам конкретного RTP. Это четыре наблюдения, не четыре независимых сбоя.

Так подтверждено продвижение счётчика отправки ядра телефона **внутри** окна,
когда DATA ещё нет в capture Core. Сам факт физического выхода через модем
этим не доказан. Участок ОС/драйвер/модем/провайдер не разделён; ни увеличение
окна аудио, ни уменьшение Core read timeout из этого не следуют. Следующий
контроль — транспорт/путь с тем же телефоном, а не новая задержка в приложении.

## Границы и teardown

20140/20135 TCP rows разобраны, parser controls (wrap, hole, duplicate, idle,
DSACK) прошли. У выбранных flows одна SYN generation, коллизий peer ports нет.
Kernel capture drops — 0; filter count больше captured на 10/1 packets,
поэтому безусловная completeness не заявлена.

Оба Core, capture/subscribers и owned state/config/binaries удалены;
production PID/binary/config независимо сверены. Mac после grace потребовал
SIGKILL и точно завершён; runtime удалён, signature проверена. QA APK,
обычный APK и root QA container совпали с SHA до теста; microphone permission,
P2P choice, fine/record/opaque properties и исходная validated Wi-Fi сеть
восстановлены. Collector groups завершены, собственные порты освобождены.
Raw captures, clocks, IDs, bindings, digests и ключи остаются private.
Push/релиза нет.
