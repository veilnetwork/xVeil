# Onion byte-stream throughput — итог оптимизации

Дата стенда: 2026-06-30.

## Результат

- Исходно: около 135 КБ/с.
- Текущая checked-in конфигурация одной pinned anonymous circuit:
  - MSS: 318 Б;
  - receive window: 896 КБ;
  - pacing batch: 12 сегментов;
  - cumulative ACK: каждые 16 DATA, но не позднее 5 мс;
  - gap/duplicate/FIN ACK отправляются немедленно;
  - congestion growth считает подтверждённые байты, а не ACK-пакеты.
- Rust synthetic clean-circuit regression теперь защищает порог **≥2.0 MiB/s**
  на текущем профиле (150 ms RTT, MSS 318, window 896 KiB, batch=12, ACK×16).
- Published pinned-circuit режим больше не кладёт sender node id в cleartext
  envelope на rendezvous relay: обычные cells идут как opaque `peer_tag`,
  а SYN/SYN_ACK несут зашифрованный receiver-only peer intro.
- Более агрессивная ступень batch=24 / ACK×32 на 37,158,021 Б давала:
  - steady: 2.80–3.01 МБ/с;
  - примерно 13.8 с от `stream-serve` до готового файла;
  - zero resend / RTO / relay drops.
  Она оставлена как измеренный верхний ориентир, но checked-in профиль сейчас
  консервативнее, чтобы снизить риск переполнения bounded relay/session queues.
- 237,765,788 Б на предыдущей консервативной ступени 768 КБ / batch=16:
  - около 2.50 МБ/с end-to-end;
  - refresh pinned circuit посередине передачи прошёл без паузы;
  - zero resend / RTO / relay drops.

## Найденные причины

1. Старый pacing выпускал максимум один MSS за миллисекундный tick. На реальном
   Android/tokio timer wake около 2 мс это давало жёсткий предел.
2. Session pipeline терял или разрывал encrypted stream при переполнении:
   маленькие TX/PQ/wire очереди, pop/encrypt до проверки writer capacity и
   трактовка временного `Full` как смерти сессии.
3. Каждый маленький encrypted frame уходил с чрезмерным padding overhead.
   Frames теперь шифруются группой и используют общий padding bucket.
4. Каждый ACK занимает такую же фиксированную onion-cell, как DATA. ACK×32
   существенно уменьшил reverse traffic и per-cell работу rendezvous.
5. Slow-start и congestion avoidance росли на ACK-пакет, а не на число
   подтверждённых байт. ACK thinning поэтому искусственно замедлял разгон.
6. Pinned circuit жил дольше relay idle TTL и становился stale. Refresh теперь
   делается только после idle, не посреди активной передачи; старая цепочка
   держится grace-периодом, чтобы ACK/data уже открытых stream'ов не black-hole.
   Новый stream-handshake на старом/тихом outbound path быстро переоткрывает
   цепочку.
7. Recreated hub использовал случайный registration key для прежнего cookie;
   relay first-registration-wins блокировал новую цепочку. Registration key
   теперь стабильно выводится из identity key; cookie переведён на v2 domain.

## Проверенные границы

- 1 МБ receive window: throughput не вырос, RTT прыгал до 445 мс — лишняя
  очередь. Финальный выбор: 896 КБ.
- Batch=16 давал почти точный timer ceiling:
  `16 × 318 Б / ~2 мс ≈ 2.54 МБ/с`.
- Batch=24 поднял steady примерно до 2.8–3.0 МБ/с без потерь.
- Batch=8 в synthetic-регрессии давал только ~1.91 MiB/s, слишком близко к
  старому 1.5 MiB/s потолку.
- Checked-in batch=12 держит synthetic-регрессию выше 2.0 MiB/s и оставляет
  safety margin против очередей реле/сессии относительно batch=24.
- Relay и клиенты не упираются в CPU; drop counters остаются нулевыми.

## Изменённые компоненты

- `veil-session`: очереди, encrypted batching и безопасный writer admission.
- `veil-onion-stream`: pacing batches, delayed/cumulative ACK, byte-counted
  congestion growth, RTT diagnostics.
- `veil-node-runtime`: stable onion-stream registration key, published rendezvous
  ad resolution for stream circuits, decrypt helper for protected peer intro.
- `veilclient-ffi`: exact circuit MSS, circuit refresh/lifecycle, tuned config,
  published-mode `peer_tag` + encrypted SYN/SYN_ACK intro.

## Текущая автономная проверка

`scripts/onion-stream-synthetic.sh` не требует телефона, UI-кликов или живых
seed-реле. Сейчас он гоняет:

- `veil-onion-stream` fault injection и полный sans-IO набор;
- `veilclient-ffi --features node-embedded anon_stream::tests`, включая strict
  opt-in, размер protected envelope и binding encrypted-intro plaintext к tag;
- Flutter content-stream range/reoffer/resume/download-to-file regressions,
  включая пустой/частичный plaintext destination и truncated source;
- `dart analyze` для затронутых Dart-файлов и `bash -n` для soak scripts.

Последний полный прогон после protected-intro правок: **passed**.

## Оставшиеся границы

- Stream cookie всё ещё детерминированный (`stream-cookie-v2`) и виден R как
  стабильный target cookie. Убрать это малой локальной правкой нельзя: R должен
  знать target cookie до первого stream cell. Нужна протокольная миграция:
  published stream-cookie в rendezvous ad или preflight invite через обычный
  rendezvous path.
- Финальная уверенность всё ещё требует real-device прогона phone ↔ desktop ↔
  3 seed-реле: synthetic ловит регрессии логики, но не доказывает radio/ADB,
  Android process lifecycle и реальные obfs4/session очереди.

## 2026-07-01: parallel range + outbound circuit pool на real device

Новый практический speed fix: app-level range parallelism теперь подкреплён
нативным outbound circuit pool. До этого `p=8/10/12` открывал несколько
`ReliableStream`, но `CircuitCells` кэшировал один `CircuitEntry` на peer, так
что все DATA/ACK сходились в один rendezvous/circuit bottleneck. Исправление:

- `veilclient-ffi` хранит per-peer pool outbound circuits, обычно по одному на
  receiver rendezvous R;
- SYN/SYN_ACK выбирает route round-robin;
- `(dst_node, stream_id) -> CircuitRoute` sticky mapping удерживает все
  последующие DATA/ACK/FIN/RST того же reliable stream на том же route/peer_tag;
- knob: `VEIL_ONION_STREAM_CIRCUIT_OUTBOUND_POOL` /
  Android `debug.veil.onion_stream_outbound_pool`, default 3;
- soak knob: `SOAK_ONION_STREAM_OUTBOUND_POOL`.

Real phone(Android sender) → desktop receiver, 64 MiB, `pool=3`, target range
512 KiB, plaintext save-to-file, SHA verified:

| profile | result | notes |
| --- | ---: | --- |
| p8, Android new / desktop old | 1.185 MiB/s active | Android had routes=3/3, desktop still old dylib; ACK path not pooled |
| p8, both new | 1.422 MiB/s active | SHA ok, no reset/resume |
| p10, both new | 1.524 MiB/s active | SHA ok, no reset/resume |
| p12, both new | 2.462 MiB/s active, 1.561 MiB/s wall | SHA ok, no reset/resume; best observed |
| p16, both new | 1.600 MiB/s active | SHA ok, no reset/resume, but tail stall; worse than p12 |

Checked-in Dart default changed from range parallelism 8 to 12. Higher fanout
remains opt-in.

Updated interpretation of the single-chain ceiling:

- RTT/receive-window are not the primary blocker. A single stream can grow
  inflight/cwnd, but then tends to hit reset/RTO/long holes under sustained
  pressure.
- Parallel range streams over one cached circuit helped only partially. The
  decisive jump came after ACK and DATA directions could use multiple outbound
  rendezvous routes.
- Remaining single-chain investigation should isolate one stream with debug
  summaries enabled and compare `pool=1` vs `pool=3`, especially sender RTO,
  relay/session reset peer, and whether the shared DATA pacer or one relay queue
  is the true single-route bottleneck.

## 2026-07-01: single-chain RTO repair fix после parallel pool

Дополнительная причина старого `~135 KiB/s`/зависаний оказалась не только в
параллелизме. Forced single-chain (`pool=1`, `SOAK_PREFER_RENDEZVOUS=c92b85df`,
range disabled) показал два RTO-сценария:

1. **no-SACK RTO после rewind**: если весь unsacked flight уже перемотан обратно
   в `pending`, следующий RTO мог случиться на tiny retransmission/probe flight.
   Старый `ssthresh = flight/2` схлопывал окно до нескольких KiB, после чего
   поток полз в congestion avoidance.
2. **SACK RTO с большим SACKed tail**: receiver держит high-seq данные, sender
   видит большой `inflight`, но classic RTO ставит `cwnd=1 MSS`. В итоге repair
   proven holes идёт слишком редко, а `inflight >> cwnd` держит stream в длинном
   plateau.

Правка в `veil-onion-stream` включена только для circuit profile
(`rto_rewind_no_sack=true`):

- no-SACK RTO считает `ssthresh` не только от текущего tiny flight, а от
  `max(flight, min(cwnd, rwnd))`;
- SACK RTO не перематывает весь flight, но сохраняет reduced usable `cwnd` и
  запускает SACK-aware `mark_holes(true)` для paced repair;
- обычный non-circuit/classic RTO по-прежнему схлопывает `cwnd` до 1 MSS.

Unit/sim проверки:

- `cargo test -p veil-onion-stream --lib` — passed, добавлены тесты на
  no-SACK floor, classic RTO и circuit SACK repair window;
- `cargo test -p veil-onion-stream --test sim` — passed.

Real-device проверки после пересборки desktop dylib + Android arm64 `.so`:

| profile | result | notes |
| --- | ---: | --- |
| single stream, `pool=1`, forced `c92`, 16 MiB | 0.800 MiB/s active, 0.457 MiB/s wall | SHA ok; был plateau на 4 MiB, затем stream сам восстановился и дошёл до конца |
| p12 range, `pool=3`, 64 MiB | 2.133 MiB/s active, 1.600 MiB/s wall | SHA ok; `fault_status=none`, Android outbound pool `routes=3/3` |

Вывод: parallel pool остаётся основным практическим speed path к ≥1.5 MiB/s, но
single-chain потолок теперь понятнее: одиночный route всё ещё склонен к
SACK/dup-ACK recovery plateau под давлением, однако catastrophic RTO collapse
починен. Следующий слой single-chain расследования — почему forced single route
создаёт большие SACKed хвосты/паузы: relay/session queue depth, ACK route jitter
или sender pacing против одного rendezvous.

Проверенный и откатанный эксперимент: circuit-only повторный fast-retransmit
probe для уже retransmitted head-hole. Идея была не ждать coarse RTO, если
dup-ACK/SACK продолжает доказывать большой tail. Live forced `c92` стало хуже:
на 16 MiB transfer receiver накопил большой out-of-order tail, advertised `rwnd`
упал примерно до 200 KiB, sender остался с `inflight≈4 MiB`, `sack≈12.5k` и
повторными RTO. Эксперимент откатан; полезный вывод сохранён: ключевой
single-route pathology — потерянный/задержанный head-hole при почти заполненном
receiver out-of-order buffer. Следующий кандидат — не слепой re-probe, а
управление receiver out-of-order pressure / SACK recovery pacing / route queue
depth так, чтобы один route не заполнял окно хвостом за пропавшей дырой.

## 2026-07-01: deterministic head-hole repro + итог по параллельности

Добавлен локальный scripted sim:
`circuit_profile_stubborn_head_hole_completes_without_reset`.

Что он моделирует:

- circuit profile, MSS как в onion cell;
- DATA идёт A→B, ACK/SACK идут обратно без потерь;
- один ранний head DATA seq дропается;
- первый repair этого же seq тоже дропается;
- большой tail уже доставлен и удерживается в out-of-order buffer.

До последней правки такой сценарий мог зависнуть до reset/timeout: SACK RTO
вызывал `mark_holes(true)`, но scanner пропускал уже `retransmitted` head-hole,
поэтому второй repair для самой старой дырки не ставился. Это хорошо совпало с
live-симптомом forced single route: receiver держит MiB хвоста, sender видит
SACKed tail, но прогресс почти не идёт.

Правка:

- добавлен `mark_oldest_unsacked_for_rto()`;
- circuit SACK RTO после `mark_holes(true)` дополнительно помечает самый старый
  unsacked segment на resend, даже если он уже был retransmitted;
- это ограничено circuit profile через существующую ветку
  `rto_rewind_no_sack=true`; classic profile не менялся.

Локальные проверки после правки:

- `cargo test -p veil-onion-stream --test sim circuit_profile_stubborn_head_hole_completes_without_reset -- --nocapture`
  — passed, `payload_ms=Some(14160)`, `close=14235`, `tx_cells=13195`,
  `max_inflight=445836`;
- `cargo test -p veil-onion-stream --lib` — passed;
- `cargo test -p veil-onion-stream --test sim` — passed.

Real-device после пересборки desktop dylib + Android arm64 `.so`:

| profile | result | notes |
| --- | ---: | --- |
| single stream, `pool=1`, forced pref `c92`, 16 MiB | interrupted after long plateau | route фактически пошёл через `c6`; после RTO видно `resend=2`, то есть новая ветка repair сработала, но `snd_una` двигался только на 318 B, `rto` вырос 20s→40s→60s; desktop receiver держал `oo_bytes≈2.1 MiB`, `srtt≈201 ms` |
| p12 range, `pool=3`, 64 MiB | 2.000 MiB/s active, 1.362 MiB/s wall | SHA ok, `fault_status=none`; desktop pool `routes=3/3`, Android pool `routes=2/3`, download hook done in 35660 ms |

Итог:

- Практический speed path — параллельность: range parallelism 12 + outbound
  circuit pool 3 уже стабильно даёт класс `>=1.5 MiB/s` и сохраняет SHA.
- Потолок одной цепочки теперь сужен до lower-layer/route pathology: RTT не
  секунды (`srtt≈200ms` на receiver side), а зависание выглядит как потерянная
  head-hole repair на конкретном route при большом out-of-order tail.
- Следующий single-chain этап: не добавлять слепые extra reprobes, а
  инструментировать/чинить relay/session/route queue health и/или ограничивать
  out-of-order pressure для одного route. Кандидаты: per-route delivery counters
  у splice, route failover/reopen при repeated SACK-RTO без `snd_una` progress,
  и более жёсткий cap на отправку хвоста, когда receiver advertised window
  съедается out-of-order буфером.

## 2026-07-01: добивание outbound parallelism — fresh-grace для ads

В успешном `p12/pool3` прогоне после RTO-fix Android иногда открывал только
`routes=2/3`, хотя ошибок `open`/`confirm` не было. Лог показал:

```text
outbound stream rendezvous filter ... matched=true ads 6->3 fresh=3->2
outbound circuit pool ready ... routes=2/3
```

Причина: sender-side фильтр свежести stream rendezvous ads допускал только
примерно 2 секунды skew между `valid_from` разных relay ads. На холодном старте
и при мобильном publish/confirm три relay ads могут публиковаться с большим
разбросом, поэтому третий здоровый route отбрасывался ещё до попытки открыть
circuit.

Правка:

- добавлен `STREAM_RENDEZVOUS_AD_FRESH_GRACE_SECS = 30`;
- stale filter сохранён, но допускает умеренный skew публикации;
- безопасность опирается на уже существующий `CIRCUIT_RETIRE_GRACE=600s`: старые
  receive circuits не закрываются мгновенно, поэтому недавно более старый ad не
  должен превращаться в blackhole для in-flight stream.

Проверки:

- `cargo check -p veilclient-ffi --features node-embedded` — passed;
- `git diff --check` и `git -C third_party/veil diff --check` — passed;
- пересобраны desktop dylib и Android arm64 `.so`;
- real-device `64 MiB`, `p12`, `pool=3`, sender Android:
  - final size `67108864`;
  - SHA source/download:
    `fa17a78af5b05e2b4a3d0af6f4599711706f3f05d1c2645ccda23ba27b9c6cdb`;
  - active `2.207 MiB/s`, wall `1.600 MiB/s`;
  - `fault_status=none`;
  - Android DATA outbound pool теперь `routes=3/3`
    (`3d3575c9`, `c6ace22e`, `c92b85df`);
  - desktop ACK outbound pool в этом прогоне был `routes=2/3`, потому что сам
    Android inbound pinned circuit стартовал с `2 registration(s)`; runtime
    intentionally не refresh'ит inbound под активной передачей, чтобы не
    повторить старый 54% stall.

Итог по parallel speed path: практическая параллельность для направления файла
добита — DATA side открывает 3/3 routes и даёт стабильный класс `>2 MiB/s`
active с SHA-ok. Симметричное `3/3` для ACK side лучше добивать не hot-refresh'ем
в середине transfer, а pre-transfer warmup/health-gate: дождаться, что оба
приложения опубликовали все 3 stream rendezvous ads до первого большого offer.

## 2026-07-01: pre-transfer warmup и asymmetric pool

Добавлен harness-only warmup, без изменений production runtime:

- debug hook `GET /warmup_onion` конструирует `MessagingService`, тем самым
  поднимает anonymous stream hub и запускает background open pinned circuits;
- `SOAK_WAIT_ONION_REGISTRATIONS=N` в `scripts/onion_stream_soak.sh` после
  unlock вызывает `/warmup_onion` на обеих сторонах и ждёт в логах
  `PINNED CIRCUIT ... N registration(s)` до начала transfer;
- добавлены side-specific harness knobs:
  `SOAK_ANDROID_ONION_STREAM_OUTBOUND_POOL` и
  `SOAK_DESKTOP_ONION_STREAM_OUTBOUND_POOL`.

Почему это понадобилось: первый gated-run без warmup показал, что Android сам
дошёл до `3 registration(s)`, а desktop до transfer не создавал stream hub.
Значит обычный `/wait_ready` не является доказательством onion readiness.

Проверки:

| profile | result | notes |
| --- | ---: | --- |
| 16 MiB, `pool=3/3`, warmup gate `3`, p12 | 2.667 MiB/s active | SHA ok; обе стороны inbound `3 registration(s)`; Android DATA pool `3/3`, desktop ACK pool `3/3` |
| 64 MiB, symmetric `pool=3/3`, warmup gate `3`, p12 | 0.985 MiB/s active, 0.762 MiB/s wall | SHA ok; обе стороны `3/3`, но desktop session reset на `c6ace22e` и `c92b85df`, много zero-rate intervals |
| 64 MiB, symmetric `pool=2/2` pref `3d,c92`, warmup gate `3`, p12 | 0.941 MiB/s active, 0.831 MiB/s wall | SHA ok; DATA/ACK pools `3d+c92`, без явных reset, но plateaus остались |
| 64 MiB, asymmetric Android DATA `pool=3`, desktop ACK `pool=1`, pref `3d,c92,c6`, warmup gate `3`, p12 | 1.939 MiB/s active, 1.255 MiB/s wall | SHA ok; Android DATA pool `3/3`, desktop ACK pool `1/1` via `3d3575c9`; no `session.primary_closed` in target grep |

Вывод:

- Full 3/3 — хороший readiness invariant, но не обязательно fastest: если ACK
  side тащит нестабильные relay sessions, benefit от DATA fanout съедается
  reset/reconnect/plateau.
- Лучший устойчивый новый профиль — асимметрия: широкий DATA fanout и узкий
  стабильный ACK route.
- Следующий production-grade кандидат: не статический asymmetric knob, а
  health-aware route selection. Для DATA можно держать fanout, а для ACK/control
  route выбирать relay с минимальными reset/plateau признаками; reset-prone
  routes временно охлаждать вместо слепого round-robin.

## 2026-07-01: native ACK route split и проверка parallelism после отката SYN_ACK

В `veilclient-ffi` добавлен native split route-class:

- `RouteClass::Bulk` для DATA/SYN/SYN_ACK/RST;
- `RouteClass::Ack` только для чистых ACK;
- `VEIL_ONION_STREAM_CIRCUIT_ACK_OUTBOUND_POOL` /
  `debug.veil.onion_stream_ack_outbound_pool`, default `1`;
- ACK route-cache отделён от Bulk route-cache, чтобы ACK не наследовал
  round-robin DATA route.

Важная проверка: попытка считать `SYN_ACK` control/ACK оказалась неверной. В
download-паттерне responder после `SYN_ACK` отправляет payload, поэтому
`SYN_ACK=Ack` случайно сжимал DATA side до `routes=1/1`. Реальный прогон
`soak-64m-p12-pool3-ack1-synack-*` завис на `0` после reset на `c92b85df`.
Правка: `SYN_ACK` возвращён в Bulk; ACK split оставлен только для чистых ACK.

Проверки после отката `SYN_ACK`:

| profile | result | notes |
| --- | ---: | --- |
| 16 MiB, p12, pool=3, ack_pool=1, warmup gate `3/3` | 1.455 MiB/s active, 0.571 MiB/s wall | SHA ok; обе стороны bulk `routes=3/3`; no reset |
| 64 MiB, p12, pool=3, ack_pool=1, warmup gate `3/3` | 1.730 MiB/s active, 1.422 MiB/s wall | SHA ok; `fault_status=none`; обе стороны bulk `routes=3/3`; no reset |
| 64 MiB, p18, pool=3, ack_pool=1, warmup gate `3/3` | 1.488 MiB/s active, 1.143 MiB/s wall | SHA ok; no reset; хуже p12 из-за большего plateau/repair pressure |

Итог:

- Параллельность уже доказанно работает: p12 + pool=3 проходит 64 MiB с SHA-ok и
  держит класс `>=1.5 MiB/s` active; лучший зафиксированный прогон остаётся
  `2.207 MiB/s active / 1.600 MiB/s wall`.
- Увеличение только Dart range parallelism (`p18`) не улучшает результат:
  bottleneck уже в route/relay/repair health, а не в нехватке воркеров.
- Следующий шаг для “добить параллельность” — health-aware route selection:
  временно охлаждать relay route при reset/длинном zero-progress plateau и не
  давать одному слабому route тормозить весь striped download.

## 2026-07-01: route health plumbing + защита от underfilled pool

Добавлен первый production-safe слой route health:

- `NodeServices::send_relay_chain_frame()` теперь возвращает bool от
  `SessionTxRegistry::send_to()` вместо молчаливого игнорирования
  closed/full first-hop session;
- `open_data_circuit()` и `send_circuit_cell()` возвращают `NoRelays`, если
  frame до first-hop не был enqueued;
- `anon_stream` хранит `rendezvous_node` в `CircuitEntry/CircuitRoute`;
- при circuit-cell enqueue failure route временно охлаждается на 60s:
  cached stream route удаляется, outbound entry retired, следующий ARQ resend
  может выбрать другой R;
- outbound open path также учитывает cooldown и не тратит pool slot на cooled R,
  если есть альтернатива.

Отдельно вскрылась ещё одна причина просадки: warmup ждал `3 registration(s)`,
но sender иногда resolve'ил receiver ads раньше, чем видел все 3 stream-cookie
ads. В таком прогоне Android DATA открыл только `routes=2/3` без `3d3575c9`:

```text
outbound stream rendezvous filter ... matched=false ads 2->2
outbound circuit pool ready ... routes=2/3
```

Итоговая защита: для `pool_target > 1` outbound open теперь не принимает
underfilled usable ad set (`< pool_target`), а возвращает retryable error.
Handshake/ARQ повторяет open позже, когда DHT/cache уже видит полный stream-ad
набор. ACK pool=1 этим не затрагивается.

Проверки:

- `cargo check -p veilclient-ffi --features node-embedded` — passed;
- `flutter analyze lib/debug/soak_hook.dart` — passed;
- `bash -n scripts/onion_stream_soak.sh`, `git diff --check`,
  `git -C third_party/veil diff --check` — passed;
- пересобраны desktop dylib и Android arm64 `.so`.

Real-device:

| profile | result | notes |
| --- | ---: | --- |
| 64 MiB, p12, pool=3, ack_pool=1, route cooldown only | 1.306 MiB/s active, 1.067 MiB/s wall | SHA ok, no reset; Android DATA opened only `routes=2/3` (`c92+c6`), because sender saw only 2 ads |
| 64 MiB, p12, pool=3, ack_pool=1, underfilled retry | 1.778 MiB/s active, 1.067 MiB/s wall | SHA ok; both sides `matched=true`; both bulk pools `routes=3/3`; no reset/cooldown event |

Вывод:

- Параллельность теперь не только “может быстро”, но и меньше зависит от race
  между registration и ad visibility: underfilled `2/3` больше не должен
  закрепляться как рабочий pool для большого transfer.
- Текущий verified класс остаётся `~1.7–2.2 MiB/s active` на 64 MiB с SHA-ok.
- Следующий слой для максимума: протащить нижний session/reset health ещё ближе
  к route scoring (или добавить splice delivery counters), потому что
  `session.primary_closed` всё ещё виден только в runtime logs, не как
  структурированный signal в `anon_stream`.

## 2026-07-01: session-close generation для stale circuit routes

Чтобы `session.primary_closed` перестал быть только строкой в runtime log,
добавлен минимальный структурированный signal без парсинга логов:

- `NodeRuntime/NodeServices/SessionRuntimeContext` теперь имеют общий
  `session_close_generations: peer -> generation`;
- generation увеличивается в cleanup после `runner.run().await`, сразу после
  `session_tx_registry.unregister(peer)` и до `dispatcher.on_session_closed`;
- `NodeServices::session_close_generation(peer)` доступен higher layers;
- `CircuitEntry/CircuitRoute` запоминают generation своего `first_hop` на момент
  open;
- перед enqueue cell `anon_stream` проверяет, не изменился ли generation
  first-hop session; если изменился, route считается stale, sticky cache
  очищается, outbound entry retired, R уходит в cooldown на 60s, а cell
  считается dropped для ARQ retry.

Это ловит класс “circuit handle жив, но first-hop relay session уже churned”
раньше, чем длинный file transfer упрётся в невидимый blackhole. Важно:
generation keyed по `first_hop`, а лог/route keyed по rendezvous `R`; в тестовой
сети они часто совпадают, но лог stale event печатает оба значения.

Проверки:

- `cargo check -p veilclient-ffi --features node-embedded` — passed;
- `flutter analyze lib/debug/soak_hook.dart` — passed;
- `bash -n scripts/onion_stream_soak.sh`, `git diff --check`,
  `git -C third_party/veil diff --check` — passed;
- пересобраны desktop dylib и Android arm64 `.so`.

Real-device:

| profile | result | notes |
| --- | ---: | --- |
| 16 MiB, p12, pool=3, ack_pool=1 | 2.667 MiB/s active, 0.593 MiB/s wall | SHA ok; Android DATA `routes=3/3`; desktop saw `send failure: NoRelays` on `3d3575c9`, route cooldown сработал, доставка не сломалась |
| 64 MiB, p12, pool=3, ack_pool=1 | 2.133 MiB/s active, 1.488 MiB/s wall | SHA ok; both sides `routes=3/3`; no reset/stale/cooldown event |

Итог:

- Практический parallel path снова подтверждён на 64 MiB: `>2 MiB/s active`,
  SHA-ok, `fault_status=none`.
- Теперь есть два структурированных route-health сигнала:
  1. immediate `send_to=false` / `NoRelays` при enqueue;
  2. session-close generation change для long-lived stale route handles.
- Оставшийся single-chain потолок всё ещё требует отдельной диагностики:
  нужны per-route/relay delivery counters или splice-level accounting, чтобы
  видеть не только “session умерла”, но и “route жив, но не продвигает
  `snd_una`/receiver reassembly”.

## 2026-07-01: no-progress route failover + стабилизация p12/pool3

Добавлен ещё один health signal на уровне onion-stream:

- `veil-onion-stream::Event::DataRto { consec_rto, snd_una }`;
- `CellDuplex::on_data_rto()` / `CellSender::on_stream_data_rto()`;
- в `anon_stream` repeated DATA RTO (`consec_rto >= 2`) для published bulk
  stream охлаждает sticky route на 60s, удаляет outbound entry и даёт ARQ
  переотправить через другой R.

На реальном стенде этот callback не сработал в happy-path прогонах, но он
закрывает класс “route alive, enqueue ok, но `snd_una` не движется”.

После этого нашли две независимые причины нестабильной скорости:

1. **Self-inflicted range resume storm.** При `p12` дефолтный
   `streamRangePayloadIdle=3s` был слишком коротким: отдельный 512 KiB range
   мог легально молчать несколько секунд, пока другие ranges дренились через
   общий onion/circuit budget. Результат — десятки `swarm-range resume`:

   ```text
   swarm-range resume ... got=397677/524288 after: TimeoutException ... idle after ...
   ```

   Дефолт поднят до 10s. Это убрало ложные partial-range reopen storm без
   отключения retries.

2. **Stream-cookie ad underfill.** Receiver публикует несколько rendezvous ads,
   но sender иногда видел только 1 stream-cookie ad из 3, хотя обычные receiver
   ads для других R уже были валидны. Старое поведение: если нашёлся хотя бы
   один stream-cookie ad, остальные receiver ads отбрасывались, и Android DATA
   деградировал до `routes=1/3`.

   Исправление: stream-cookie ads остаются приоритетом, но если их меньше
   `pool_target`, outbound open добирает валидные receiver ads на других R.
   Это согласуется с inbound `CIRCUIT_RETIRE_GRACE`: старые receive circuits
   намеренно живут достаточно долго, чтобы in-flight streams не blackhole'ились.
   Underfilled pool теперь деградирует только когда реально нет usable R.

Проверки:

- `cargo check -p veilclient-ffi --features node-embedded` — passed;
- `flutter analyze lib/debug/soak_hook.dart lib/state/messaging.dart` — passed;
- `bash -n scripts/onion_stream_soak.sh`, `git diff --check`,
  `git -C third_party/veil diff --check` — passed;
- пересобраны desktop dylib и Android arm64 `.so`.

Real-device:

| profile | result | notes |
| --- | ---: | --- |
| 64 MiB, p12, pool=3, idle=3s | 0.955 MiB/s active | SHA ok, но 46 `swarm-range resume` из-за 3s idle |
| 64 MiB, p12, pool=3, idle=10s, fresh fallback only | 1.333 MiB/s active | SHA ok, no resume/reset, но Android DATA `routes=1/3` |
| 64 MiB, p12, pool=3, idle=10s, stream-ad supplement | 1.829 MiB/s active, 1.362 MiB/s wall | SHA ok; both sides `routes=3/3`; no resume/reset/stale/no-progress |

Финальный проверенный лог:

```text
scratchpad/soak-64m-p12-pool3-supplement-20260701-155235
final_size_bytes=67108864
active_elapsed_sec=35
avg_mib_per_sec=1.829
fault_status=none
SHA256 source == download
Android bulk routes=3/3
Desktop bulk routes=3/3
```

Итог:

- Параллельный путь p12 + native pool=3 снова проходит целевой класс
  `>=1.5 MiB/s` на 64 MiB с byte-perfect доставкой.
- Из текущих наблюдений главный практический bottleneck был не “не хватает
  воркеров”, а route visibility/health: ложные range timeouts и underfilled
  rendezvous pool резко опускали скорость без повреждения данных.
- Single-chain ceiling всё ещё не закрыт как исследование: нужен отдельный
  phase с per-route delivery counters/splice accounting, чтобы объяснить,
  почему один circuit стабильно ниже суммарного p12/pool3.

## 2026-07-01: single-long контроль после стабилизации p12/pool3

После того как parallel path стал проходить 64 MiB на `p12/pool3`, отдельно
проверили “один длинный stream” (`STREAM_RANGE_ENABLED=false`) и
последовательный `p1` range, чтобы отделить app-level range overhead от
реального потолка одной цепочки.

### p1 range, pool=1

Лог:

```text
scratchpad/soak-16m-single-p1-pool1-summary-20260701-155859
```

Результат:

- 16 MiB доставлены, SHA ok;
- `active_elapsed_sec=79`, `avg_mib_per_sec=0.203`;
- фактически это 32 независимых range-stream по 512 KiB;
- driver summary без потерь/RTO: `srtt≈158–164ms`,
  `inflight≈80–130 KiB`, `cwnd≈120–180 KiB`, `rwnd=4 MiB`,
  `resend=0`, `consec_rto=0`.

Вывод: p1 range надёжен, но медленный из-за последовательной нарезки по
коротким streams. Это не демонстрирует физический потолок одного stream.

### single long stream, pool=1

Лог:

```text
scratchpad/soak-16m-single-long-pool1-summary-20260701-160215
```

Результат:

- быстро дошёл примерно до 4 MiB на диске;
- затем receiver завис на `payload idle after 4244662/16777216B`;
- sender в это время уже queue/write продвинулся до ~12 MiB и позже упал:
  `payload write idle at 12058624/16777216`;
- sender driver: DATA RTO/no-progress на том же stream:
  `consec_rto=2..5`, `snd_una` не двигался, route охлаждался и
  переоткрывался;
- receiver параллельно видел ACK/return-path проблему:
  `send failure: NoRelays` на outbound route;
- retry receiver после первого idle не смог нормально resume: следующие stream
  attempts часто заканчивались `no manifest (sender not serving)`, пока первый
  заблокированный serve ещё ждал свой `write()` timeout.

Проверка гипотезы “просто мало ACK routes”:

```text
scratchpad/soak-16m-single-long-pool3-ack3-summary-20260701-160749
```

`outbound_pool=3`, `ack_pool=3`, но `STREAM_RANGE_ENABLED=false`. Результат
хуже: payload дошёл только до `5783B`, файл на диске остался 0, и обе стороны
быстро получили `route no-progress`. Значит single-long stall не лечится
простым увеличением ACK pool: новый stream на той же long-stream модели всё
равно может попасть в no-progress route.

Добавлена небольшая app-level mitigation для диагностики/resume:

- если source можно открыть независимо на каждый stream (durable `sourcePath`
  или stored blob), а `streamRangeParallelism=1`, sender разрешает один
  дополнительный active serve (`limit=2`);
- это даёт retry шанс получить manifest/resume, пока старый writer ещё ждёт
  `payload write idle`;
- shared live cursor не расширяется сверх configured limit, чтобы не вернуть
  старую проблему cursor thrash.

Контроль:

```text
scratchpad/soak-16m-single-long-pool1-rescueslot-20260701-161148
```

Результат:

- attempt 1 дошёл до `3670016B` на диске и получил
  `payload idle after 3826714/16777216B`;
- receiver выставил resume point `piece=14 offset=3670016`;
- attempt 2 действительно отправил `resume=3670016`, но тот же pool=1 route
  ушёл в `route no-progress`, после чего прогресс не восстановился;
- старый sender writer умер только через 120s:
  `payload write idle at 11534336/16777216`.

Итог single-chain:

- практический быстрый путь должен оставаться `range enabled + p12/pool3`:
  он резюмируемый, проверяет куски и уже показал `1.829 MiB/s active` на 64 MiB;
- одиночный длинный stream не просто медленный: на pool=1 он превращает route
  blackhole в долгий app-level stall, потому что monolithic stream держит
  sender write до 120s и retry идёт через тот же ограниченный route budget;
- чтобы **исчерпывающе** объяснить физический потолок одной цепочки, следующий
  слой диагностики должен быть ниже приложения: per-route delivery counters на
  sender/receiver/R или splice-level accounting (`cell sent`, `cell delivered`,
  `ACK returned`, `session enqueue failed`) по rendezvous/first-hop.

## 2026-07-01: autonomous device soak уточнение — stream path vs legacy chunk path

После добавления debug-hook automation прогнали phone(Android sender) →
desktop(receiver) без ручных кликов: launch, hook unlock, source staging,
send_file, wait_offer, download_file, size/SHA.

Сначала обнаружился harness bug:

- Android cold Gradle/Rust build не успевал поднять hook за 120s;
- `onion_stream_soak.sh` после таймаута всё равно пытался делать `/unlock`;
- результат был misleading `curl: (52) Empty reply from server`.

Исправление: soak теперь явно падает, если desktop или Android debug hook не
стал ready, и печатает health/log tails. Это не speed fix, но убирает ложные
“app crashed on unlock” симптомы.

Дальше важное разделение путей:

1. `SOAK_STREAM_RANGE_ENABLED=true`, `p12`, `pool3`, но
   `SOAK_PLAIN_FILE_STREAM` не был включён.
   Фактически download пошёл по legacy piece/chunk path:

   ```text
   scratchpad/soak-auto-8m-p12-pool3-rerun-20260701-162853
   ```

   Результат:

   - записалось ровно 6 pieces = `1,572,864B`;
   - дальше receiver циклил `re-request ... pieces [6,7,8,9]`;
   - sender отвечал `pieceRequest ... CHUNK-granular ... -> serving`;
   - прогресс на destination не двигался больше минуты.

   Вывод: без `XVEIL_PLAIN_FILE_STREAM=true` soak может тестировать старый
   datagram/chunk fetch, а не новый reliable stream/range speed path.

2. Явный stream path:

   ```text
   scratchpad/soak-auto-8m-stream-p12-pool3-20260701-163234
   SOAK_PLAIN_FILE_STREAM=true
   SOAK_STREAM_RANGE_ENABLED=true
   SOAK_STREAM_RANGE_PARALLELISM=12
   SOAK_ONION_STREAM_OUTBOUND_POOL=3
   ```

   Результат:

   - `swarm-range start ... workers=12 target_bytes=524288`;
   - `download_file done in 4091ms`;
   - `final_size_bytes=8388608`;
   - source SHA == downloaded SHA:
     `450baa18e507a83496d777ca353ff0267bcc99936088d3313aae9a7ec3461d17`;
   - `fault_status=none`.

   Monitor interval was 10s, so summary `active_elapsed_sec=1` is not a good
   fine-grained throughput metric for this small file; the hook log gives the
   more useful wall for the download call (~4.1s). The important result is
   correctness: no empty file, no eternal spinner, SHA ok.

3. Большой автономный контроль тем же harness’ом:

   ```text
   scratchpad/soak-auto-64m-stream-p12-pool3-20260701-163524
   SOAK_AUTO_TRANSFER=1
   SOAK_STREAM_RANGE_ENABLED=true
   SOAK_STREAM_RANGE_PARALLELISM=12
   SOAK_ONION_STREAM_OUTBOUND_POOL=3
   ```

   Результат:

   - `final_size_bytes=67108864`;
   - source SHA == downloaded SHA:
     `fe27818497cee8b27c8447b0b04a2aa992ebb63b315e98ba38447f27d47d09fe`;
   - `avg_mib_per_sec=2.065` active, `wall_avg_mib_per_sec=1.561`;
   - `fault_status=none`;
   - transfer hook completed with `downloaded size: 67108864`.

   Важная диагностика: transfer завершился корректно, но ближе к хвосту Android
   всё равно зафиксировал несколько
   `outbound route no-progress ... via R=3d3575c9 first_hop=c92b85df`.
   Range-параллельность/route pool это переживает, но для single-route потолка
   это остаётся главным следом: отдельный route может black-hole/охлаждаться,
   а быстрый режим выигрывает за счёт независимых range-stream и других routes.

Harness default update: for `SOAK_AUTO_TRANSFER=1`, if the caller did not set
`SOAK_PLAIN_FILE_STREAM`, the soak script now defaults it to `true`. Production
app default remains conservative; the automation default is chosen so speed
soaks exercise the intended reliable stream/range path. To test legacy chunk
path explicitly, set `SOAK_PLAIN_FILE_STREAM=false`.

4. Повторный 64 MiB autonomous контроль после добавления route `path=...`
   диагностики:

   ```text
   scratchpad/soak-auto-64m-pathdiag-p12-pool3-20260701-164015
   SOAK_AUTO_TRANSFER=1
   SOAK_STREAM_RANGE_ENABLED=true
   SOAK_STREAM_RANGE_PARALLELISM=12
   SOAK_ONION_STREAM_OUTBOUND_POOL=3
   ```

   Результат:

   - `final_size_bytes=67108864`;
   - source SHA == downloaded SHA:
     `1f44161ff0ddc869202fd124e898622e08106fe66e2cf639bd056f8be086d28f`;
   - `avg_mib_per_sec=2.133` active, `wall_avg_mib_per_sec=1.561`;
   - `fault_status=none`;
   - desktop `download_file done in 34666ms`;
   - был один range resume:
     `p74..75 got=401506/524288 after 10s idle`, после чего файл успешно
     добрался и SHA совпал.

   Route pool на Android открыл три outbound circuit:

   ```text
   R=3d3575c9 path=c92b85df>3d3575c9 open_confirm=138ms
   R=c6ace22e path=c92b85df>c6ace22e open_confirm=111ms
   R=c92b85df path=3d3575c9>c92b85df open_confirm=186ms
   ```

   В этом прогоне `route no-progress` не повторился, поэтому full-path
   диагностика пока подтвердила только состав route pool, но не поймала сам
   blackhole. Практический вывод не меняется: быстрый режим уже держится на
   параллельных range-stream + pool3 + resume/retry; single-route root cause
   ещё нужно добивать отдельной низкоуровневой диагностикой.

5. Single-route diagnostic probe с route counters:

   ```text
   scratchpad/soak-auto-16m-single-route-stats-rerun-20260701-165501
   SOAK_AUTO_TRANSFER=1
   SOAK_STREAM_RANGE_ENABLED=false
   SOAK_ONION_STREAM_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_ACK_OUTBOUND_POOL=1
   SOAK_DOWNLOAD_TIMEOUT_MS=240000
   ```

   Harness fix по дороге: `SOAK_WAIT_ONION_REGISTRATIONS=1` раньше искал ровно
   `1 registration(s)`, поэтому ложно падал на рабочей строке `3
   registration(s)`. Теперь readiness проверяет `latest_count >= target`.

   Результат:

   - destination дошёл только до `3,932,160B` (`15` pieces из `64`);
   - transfer hook завершился HTTP 504 после bounded timeout;
   - first receiver route:

     ```text
     desktop -> android:
       R=3d3575c9 path=c6ace22e>3d3575c9
       send failure: NoRelays
       stats: data_cells=1 data_bytes=48 control_cells=731 send_failures=1

     android -> desktop payload:
       R=3d3575c9 path=c6ace22e>3d3575c9
       route stats at age=2s:
         data_cells=8192  data_bytes=2604420
         data_cells=16384 data_bytes=5209476
       no-progress at age=33s:
         data_cells=21203 data_bytes=6741759 consec_rto=2 rto_events=1
     ```

   - receiver observed only `payload idle after 4036598/16777216B` and committed
     `3,932,160B`;
   - sender old serve kept writing until
     `payload write idle at 11796480/16777216` after 120s;
   - retry attempts reached sender often enough to log repeated
     `manifest inline ... -> 7084a345`, but receiver side still failed with
     `Bad state: no manifest (sender not serving)`; later sender-side retries
     failed with `Future not completed`.

   Interpretation:

   - this is not a receive-window or app file-save bug: bytes move fast at first,
     then one route loses/black-holes enough contiguous stream traffic to trigger
     no-SACK RTO;
   - single long stream recovery is poor because the old writer can keep its
     flow-controlled write alive for 120s while receiver retry streams fail to
     establish a clean manifest/payload exchange;
   - range mode avoids the failure class by using short independent streams,
     per-range timeout, route pool and retry. It is not just “more bandwidth”;
     it also isolates a bad stream/route to one range.

   BBR note: kernel BBR on obfs4/TCP hops would not control this end-to-end ARQ
   stream or detect route blackholes. An app-level BBR-like controller may still
   be useful later for queue/pacing, but the captured failure is currently
   dominated by route/stream liveness and retry isolation, not by a clean
   congestion equilibrium.

6. Fresh range-parallelism matrix после route counters:

   ```text
   p8 :  scratchpad/soak-auto-64m-route-stats-fast-p8-pool3-20260701-170902
   p12:  scratchpad/soak-auto-64m-route-stats-fast-p12-pool3-20260701-170116
   p18:  scratchpad/soak-auto-64m-route-stats-fast-p18-pool3-20260701-170337
   ```

   Все три прогона корректно доставили `64 MiB`, source SHA == downloaded SHA,
   `fault_status=none`. Скорость и tail stalls:

   | parallelism | active MiB/s | wall MiB/s | range resumes | route no-progress | route cooled |
   | --- | ---: | ---: | ---: | ---: | ---: |
   | 8  | 1.049 | 0.901 | 5  | 3 | 2 |
   | 12 | 1.280 | 1.049 | 10 | 0 | 1 |
   | 18 | 0.790 | 0.696 | 16 | 0 | 0 |

   Выводы:

   - больше workers не помогает: `p18` усилил tail stalls и стал заметно хуже;
   - на текущем стенде `p12` остаётся лучшей из трёх точек, но всё ещё ниже
     прежнего best run (`~2.1 MiB/s active`) и ниже целевого устойчивого
     `>=1.5 MiB/s`;
   - `p8` показал меньше range resumes, но три `route no-progress` на
     desktop→android control/request path:

     ```text
     R=c6ace22e path=c92b85df>c6ace22e first_hop=c92b85df
     data_cells=67 data_bytes=3216 control_cells=13019 consec_rto=2
     ```

   - `p8`/`p12` также ловили desktop→android `NoRelays` on send failure на
     outbound route, при этом Android→desktop payload routes продолжали слать
     десятки MiB без RTO.

   Поэтому следующий фокус — не fanout, а liveness/selection control path:
   почему small request/ACK/control streams on desktop→android periodically lose
   route/session, while bulk payload in the reverse direction remains healthy.

7. Preflight live-session fix:

   Добавлен быстрый liveness-check первого hop перед использованием outbound
   route: если `CircuitRoute.first_hop` уже не имеет live session в
   `NodeServices`, route считается stale и переоткрывается/охлаждается до
   попытки `send_circuit_cell`. Это закрывает класс ложных маршрутов, которые
   внешне ещё не имели close-generation bump, но уже падали на отправке как
   `NoRelays`.

   Контрольный прогон:

   ```text
   scratchpad/soak-auto-64m-live-session-preflight-p12-pool3-20260701-171321

   SOAK_STREAM_RANGE_ENABLED=true
   SOAK_STREAM_RANGE_PARALLELISM=12
   SOAK_ONION_STREAM_OUTBOUND_POOL=3
   SOAK_WAIT_ONION_REGISTRATIONS=3
   SOAK_DOWNLOAD_TIMEOUT_MS=600000

   final_size_bytes=67108864
   source SHA == downloaded SHA
   active_elapsed_sec=30
   wall_elapsed_sec=41
   avg_mib_per_sec=2.133
   wall_avg_mib_per_sec=1.561
   fault_status=none
   ```

   Логи ровные: Android→desktop payload равномерно распределился по трём
   rendezvous routes (`3d3575c9`, `c6ace22e`, `c92b85df`), все route stats
   имеют `send_failures=0 rto_events=0`. В релевантном tail нет `NoRelays`,
   `route no-progress`, `route cooled` или resume storms.

   Практический вывод: целевой уровень `>=1.5 MiB/s` снова достигнут на
   64 MiB correctness run, и текущая лучшая точка — range-parallel p12 +
   outbound pool 3 + first-hop live-session preflight.

8. Post-compress reproducibility + first-hop refill:

   Повтор после сжатия хранилища сначала показал, что хороший p12 не был
   железно воспроизводим:

   ```text
   scratchpad/soak-auto-64m-post-compress-p12-pool3-20260701-172031

   source SHA == downloaded SHA
   avg_mib_per_sec=1.049
   wall_avg_mib_per_sec=0.901
   fault_status=none
   ```

   Причина была видна в route stats: две из трёх Android→desktop payload routes
   стартовали через один first-hop `c92b85df`; через ~5s он стал `live=false`,
   и обе routes одновременно ушли в stale/cooldown:

   ```text
   R=c6ace22e path=c92b85df>c6ace22e first_hop=c92b85df live=false
   R=3d3575c9 path=c92b85df>3d3575c9 first_hop=c92b85df live=false
   ```

   Дальше bulk фактически ехал по одной оставшейся route, поэтому скорость
   вернулась к одиночному потолку.

   Попытка жёстко отбрасывать duplicate first-hop при открытии пула оказалась
   слишком агрессивной:

   ```text
   scratchpad/soak-auto-64m-firsthop-aware-p12-pool3-20260701-172458

   source SHA == downloaded SHA
   routes=2/3
   avg_mib_per_sec=0.901
   wall_avg_mib_per_sec=0.703
   fault_status=none
   ```

   Она предотвращала коррелированный first-hop risk, но сразу урезала полезный
   fanout до 2 routes; на p12 это дало много range idle/resume.

   Финальная корректировка:

   - stale/RTO/send-failure охлаждает не только rendezvous R, но и first-hop;
   - route selection не выбирает cooled/dead first-hop, если есть живые варианты;
   - после stale/RTO/send-failure запускается background refill всего outbound
     pool;
   - duplicate first-hop при открытии пула не отбрасывается, а остаётся standby
     route с диагностикой.

   Контрольный прогон:

   ```text
   scratchpad/soak-auto-64m-firsthop-refill-p12-pool3-20260701-172950

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=31
   wall_elapsed_sec=41
   avg_mib_per_sec=2.065
   wall_avg_mib_per_sec=1.561
   fault_status=none
   ```

   Route logs:

   ```text
   duplicate first-hop c92b85df — keeping as standby
   outbound circuit pool ready ... routes=3/3
   send_failures=0 rto_events=0 on all three payload routes
   no route stale / no-progress / cooled / NoRelays in the transfer tail
   ```

   Практический вывод: текущая стабильная точка для тестового стенда —
   range-parallel p12 + outbound pool 3 + live-session preflight +
   first-hop cooldown/refill. Жёсткое “one route per first-hop” на стенде из
   трёх сидов вредно; правильнее сохранять полный pool и быстро пополнять его
   после реального first-hop death.

9. Range idle + fanout ceiling after first-hop refill:

   Повтор p12 без native rebuild, на старом range idle 10s:

   ```text
   scratchpad/soak-auto-64m-p12-repro-nobuild-20260701-173451

   source SHA == downloaded SHA
   avg_mib_per_sec=1.600
   wall_avg_mib_per_sec=1.255
   fault_status=none
   routes=3/3, send_failures=0, rto_events=0
   ```

   Route layer был чистый, но content layer ловил near-tail
   `swarm-range resume ... idle after 10s` на нескольких ranges. Это ложный
   app-level idle, не native route death.

   Поднятие range payload idle до 20s:

   ```text
   scratchpad/soak-auto-64m-p12-idle20s-nobuild-20260701-173718

   source SHA == downloaded SHA
   avg_mib_per_sec=2.065
   active_elapsed_sec=31
   fault_status=none
   routes=3/3, send_failures=0, rto_events=0
   ```

   На этом run не было range resumes; файл достиг expected size до
   post-size trigger wait. Поэтому дефолт `_streamRangePayloadIdleTimeout`
   поднят с 10s до 20s. Последующий прогон без явного env override подтвердил,
   что новый дефолт включился:

   ```text
   scratchpad/soak-auto-64m-p12-default20-nobuild-20260701-174521

   source SHA == downloaded SHA
   avg_mib_per_sec=2.065
   active_elapsed_sec=31
   fault_status=none
   ```

   В этом run были несколько cold-start range resumes at 20s, но native routes
   оставались чистыми (`send_failures=0`, `rto_events=0`) и active throughput
   сохранился.

   Fanout выше p12:

   ```text
   scratchpad/soak-auto-64m-p16-idle20s-nobuild-20260701-174008

   source SHA == downloaded SHA
   avg_mib_per_sec=1.600
   fault_status=none
   ```

   p16 корректно доставил файл, но стал медленнее и в конце вызвал route-level
   `no-progress`/RTO:

   ```text
   R=c92b85df path=c6ace22e>c92b85df consec_rto=2
   usable rendezvous ads 2/3
   first-hop c6ace22e cooled
   routes=1/3 refill attempts
   ```

   p14 оказался ещё хуже и был остановлен вручную после >70s без прогресса на
   диске:

   ```text
   scratchpad/soak-auto-64m-p14-idle20s-nobuild-20260701-174230

   progress.csv stayed at 0B
   Broken pipe on first-hop c92b85df
   outbound route stale live=false on desktop→android control path
   many swarm-range resume ... manifest truncated
   ```

   Практический вывод: на текущем 3-seed стенде sweet spot остаётся p12 /
   512 KiB ranges / outbound pool 3 / range idle 20s. Выше p12 начинается не
   полезный throughput gain, а route/control-path saturation: RTO на отдельных
   stream ids, first-hop cooldown/refill storms, `manifest truncated` на retry.

   Следующий bottleneck для Phase 2: не “добавить ещё workers”, а разобраться,
   почему control path/range-open на desktop→android и отдельные bulk streams
   начинают RTO при p14–p16. Возможные направления:

   - меньше control chatter на range retry/open;
   - per-first-hop/per-route worker budget вместо глобального fanout;
   - smarter route assignment для range workers, чтобы не перегружать один
     first-hop;
   - instrumentation очередей first-hop/session writer, чтобы отличить relay
     queue saturation от local writer/session churn.

10. Range open pacing experiment:

   Гипотеза: p14/p16 ломаются из-за одномоментного открытия большого числа
   range streams / retry streams, а не из-за steady-state payload fanout.

   Добавлен opt-in dart-define:

   ```text
   XVEIL_STREAM_RANGE_OPEN_PACE_MS
   ```

   Он сериализует только open/retry-open range streams внутри одного swarm.
   После тестов дефолт оставлен `0`: при `0` pacer вообще не подключается к
   hot path, чтобы не добавлять лишнюю сериализацию.

   p12 с фиксированным 25ms open pace:

   ```text
   scratchpad/soak-auto-64m-p12-openpace-nobuild-20260701-175126

   source SHA == downloaded SHA
   avg_mib_per_sec=1.067
   wall_avg_mib_per_sec=0.627
   fault_status=none
   open_pace_ms=25
   routes=3/3
   ```

   Файл доставлен корректно, но throughput сильно просел. Значит fixed open
   pacing нельзя включать по умолчанию.

   p12 после возврата к дефолту `open_pace_ms=0`:

   ```text
   scratchpad/soak-auto-64m-p12-openpace-default0-nobuild-20260701-175516

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=40
   wall_elapsed_sec=51
   avg_mib_per_sec=1.600
   wall_avg_mib_per_sec=1.255
   fault_status=none
   open_pace_ms=0
   ```

   Native payload routes clean: `send_failures=0`, `rto_events=0`, no
   route-stale/no-progress on Android payload side in the useful tail.

   p14 с мягким opt-in 5ms open pace:

   ```text
   scratchpad/soak-auto-64m-p14-openpace5-nobuild-20260701-175718

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=122
   wall_elapsed_sec=153
   avg_mib_per_sec=0.525
   wall_avg_mib_per_sec=0.418
   fault_status=none
   open_pace_ms=5
   ```

   Это улучшило correctness относительно p14 без pacing: hard zero-start /
   вечный `manifest truncated` превратился в eventual success. Но скорость
   развалилась, а логи всё равно показывали route/control saturation:
   `Broken pipe`, route stale live=false, degraded pool 2/3 и 1/3, range
   resumes after 20s, `Bad state: no manifest (sender not serving)`.

   Практический вывод: простое глобальное open pacing — диагностический
   инструмент, не решение. Он доказывает, что есть чувствительность к
   burst/open pressure, но не снимает steady-state saturation. Текущий
   production-safe дефолт: p12, 512 KiB ranges, range idle 20s, open pace 0.

   Следующее направление для роста выше p12: admission control не по общему
   числу workers, а по route/first-hop capacity. Нужен scheduler, который не
   допускает, чтобы retry/open шторм и payload streams одновременно забивали
   один first-hop или маленький native route pool. Для этого желательно
   протащить наверх route id / first-hop id или хотя бы live route stats, чтобы
   Dart мог распределять range workers по capacity вместо слепого глобального
   fanout.

11. First-hop liveness recovery + new p14 practical point:

   После сжатия хранилища baseline p12 был перепроверен:

   ```text
   scratchpad/soak-auto-64m-p12-after-compress-default0-20260701-180358

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=30
   avg_mib_per_sec=2.133
   wall_avg_mib_per_sec=1.561
   fault_status=none
   open_pace_ms=0
   ```

   Но последующие p12 runs показали, что это не guaranteed stable: при смерти
   first-hop / session churn route pool мог схлопываться, receiver уходил в
   `manifest truncated` / `no manifest (sender not serving)` retry storm, а
   старые sender-side serve streams держали slots до длинного write timeout.

   Внесены recovery-фиксы:

   - `veil-onion-stream`: добавлен stream-close callback из driver → mux →
     `CellSender`, чтобы native мог вести `active_streams` per route и чистить
     stream route cache при нормальном закрытии.
   - `veilclient-ffi`: route stats теперь логируют `active_streams`.
   - `veilclient-ffi`: при route `no-progress` охлаждается только rendezvous
     relay, а не весь first-hop. First-hop cooldown оставлен для `route stale`
     (`live=false`) и send failure, где смерть session доказана.
   - `veilclient-ffi`: freshly opened circuit не попадает в outbound pool, если
     после confirm его first-hop уже не имеет live session
     (`first-hop ... not live after confirm`).
   - Dart sender-side serve recovery: payload write idle снижен 120s → 30s, а
     для independent/durable serve source разрешён небольшой rescue cushion
     active serves (`parallelism + 4`, capped), чтобы retries могли получить
     manifest пока старые writers отваливаются.

   Проверки:

   ```text
   cargo check -p veil-onion-stream -p veilclient-ffi --features veilclient-ffi/node-embedded
   flutter test test/content_stream_transfer_test.dart
   dart analyze lib/state/messaging.dart
   git diff --check
   ```

   p12 после open-time first-hop preflight:

   ```text
   scratchpad/soak-auto-64m-p12-open-live-preflight-20260701-183017

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=40
   avg_mib_per_sec=1.600
   wall_avg_mib_per_sec=1.255
   fault_status=none
   routes=3/3
   no route stale / no-progress / pool degraded in useful tail
   ```

   Новый лучший practical point — p14:

   ```text
   scratchpad/soak-auto-64m-p14-open-live-preflight-20260701-183356

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=30
   wall_elapsed_sec=40
   avg_mib_per_sec=2.133
   wall_avg_mib_per_sec=1.600
   fault_status=none
   workers=14
   target_bytes=524288
   routes=3/3
   send_failures=0
   rto_events=0
   ```

   p16 remains above the safe ceiling:

   ```text
   scratchpad/soak-auto-64m-p16-open-live-preflight-20260701-183600

   source SHA == downloaded SHA
   avg_mib_per_sec=1.600
   wall_avg_mib_per_sec=1.049
   fault_status=none
   ```

   It completes, but route logs show multiple `route no-progress` events on two
   rendezvous routes and `outbound circuit pool degraded ... usable rendezvous
   ads 1/3`; one remaining route carries `active_streams=16`. Therefore p16 is
   not the default.

   512 KiB range target also remains the better default. A p14 probe with 1 MiB
   ranges completed correctly, but did not improve throughput and showed a
   dirty tail:

   ```text
   scratchpad/soak-auto-64m-p14-target1m-20260701-184034

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=31
   avg_mib_per_sec=2.065
   target_bytes=1048576
   ```

   Compared with p14/512 KiB (`2.133 MiB/s active`), larger ranges slightly
   reduce scheduling overhead but increase tail risk: this run needed
   `swarm-range resume` and later logged route no-progress.

   p15/512 KiB was tested as the boundary between the clean p14 plateau and the
   unstable p16 ceiling:

   ```text
   scratchpad/soak-auto-64m-p15-open-live-preflight-20260701-184308

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=30
   avg_mib_per_sec=2.133
   fault_status=none
   workers=15
   target_bytes=524288
   ```

   It also completed with correct SHA, but the logs contain
   `swarm-range resume` near pieces 196..197, then `route no-progress`,
   rendezvous cooldown, and pool degradation (`routes=1/3`). In the current
   code at the time of this run, the same no-progress path also cooled the
   route's first-hop, which could falsely penalise other rendezvous routes that
   happened to share that first-hop. This confirms p15 is a usable stress point,
   not the safe default.

   Current default moved from p12 to p14:

   ```text
   _defaultStreamRangeParallelism = 14
   _defaultStreamRangeTargetBytes = 512 KiB
   _streamRangePayloadIdleTimeout = 20s
   _streamRangeOpenPace = 0 by default
   ```

   Remaining bottleneck: p15/p16+ still overload route/control capacity under
   tail pressure; after RTO cooldown the native pool can temporarily collapse
   to one usable rendezvous route. Next speed work should focus on route-level
   admission or faster multi-route refill under cooldown, not simply raising
   global workers.

12. Route-aware admission after p15 boundary:

   Follow-up fix aimed at the p15/p16 ceiling:

   - `mark_route_no_progress` now cools only the rendezvous relay. First-hop
     cooldown is reserved for evidence that the first-hop/session itself is bad:
     `route stale` (`live=false` / close generation changed) and send failure.
     This prevents one congested/lossy rendezvous from poisoning another route
     that shares the same first-hop.
   - Bulk route selection remains round-robin among healthy candidates; the
     failed “always least-loaded” experiment is not reintroduced.
   - New soft admission cap:
     `VEIL_ONION_STREAM_CIRCUIT_BULK_ROUTE_ACTIVE_LIMIT`
     / Android property
     `debug.veil.onion_stream_bulk_route_active_limit`,
     default `0` (disabled). When enabled, a new Bulk stream is assigned only
     to a usable route whose `active_streams < limit`; if every usable route is
     saturated, the cell is dropped and ARQ retries while the background opener
     tries to refill the pool.
   - `scripts/onion_stream_soak.sh` exposes
     `SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT` plus per-side overrides, so
     live probes can compare `4/5/6/0` without recompilation.

   Local checks:

   ```text
   cargo check -p veil-onion-stream -p veilclient-ffi --features veilclient-ffi/node-embedded
   bash -n scripts/onion_stream_soak.sh scripts/onion-stream-hook-transfer.sh
   git diff --check
   git -C third_party/veil diff --check
   git -C third_party/hidden-volume diff --check
   ```

   Live evidence:

   ```text
   scratchpad/soak-auto-64m-p14-routecap5-nobuild-20260701-185329

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=71
   avg_mib_per_sec=0.901
   wall_avg_mib_per_sec=0.525
   bulk_route_active_limit=5
   ```

   `limit=5` is too conservative for the current stand. It preserved
   correctness, but Android repeatedly opened only `routes=2/3`, the cap held
   both routes at `active_streams=5`, early ranges timed out/resumed, and speed
   collapsed below the previous p14 plateau. Therefore it must not be the
   default.

   ```text
   scratchpad/soak-auto-64m-p14-routecap0-nobuild-20260701-185642

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=31
   avg_mib_per_sec=2.065
   wall_avg_mib_per_sec=1.255
   bulk_route_active_limit=0
   routes=3/3
   send_failures=0
   rto_events=0
   no swarm-range resume
   ```

   Keep the useful `no-progress => rendezvous-only cooldown` fix and the cap
   as an experiment/diagnostic knob, but leave the cap disabled by default.
   p16/512 KiB with cap disabled:

   ```text
   scratchpad/soak-auto-64m-p16-routecap0-rerun-20260701-190240

   source SHA == downloaded SHA
   final_size_bytes=67108864
   active_elapsed_sec=31
   avg_mib_per_sec=2.065
   wall_avg_mib_per_sec=1.561
   bulk_route_active_limit=0
   routes=3/3
   send_failures=0
   rto_events=0
   no swarm-range resume
   ```

   This invalidates the previous “p16 is above safe ceiling” result: the dirty
   p16 tail was largely caused by route cooldown/pool behaviour, not by an
   inherent global fanout limit at 16. p16 is now a valid stress point, but it
   did not beat the best p14 active throughput on this run; next speed probing
   should try p18/p20 with cap disabled, while keeping p14/p16 as known-good
   rollback profiles.

13. ACK/window-gating hypothesis, single-route debug:

   User raised a useful analogy: a prior stack hit a throughput ceiling because
   a lower layer effectively sent one small unit and waited for ACK/window
   progress before sending the next. The VPS-level variant of that issue was
   checked first:

   ```text
   seeds: 203.12.31.146 / .145 / .134
   tcp_syncookies=1, tcp_window_scaling=1, tcp_sack=1
   nstat: TcpExtSyncookiesSent=0, TcpExtListenOverflows=0
   active seed sockets: wscale:6,6
   ```

   So this is not the old Linux/Windows `syncookies=2 breaks wscale` failure.
   However the shape is similar inside our onion stack.

   Forced single stream, single outbound route, driver summaries enabled:

   ```text
   scratchpad/soak-auto-16m-single-pool1-debug-20260701-190434

   SOAK_STREAM_RANGE_ENABLED=false
   SOAK_ONION_STREAM_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_DEBUG_SUMMARY_MS=1000
   interrupted after stall
   downloaded_size=3407872 / 16777216
   ```

   Key sender-side summaries:

   ```text
   t≈1s:  inflight=39114   cwnd=63450    rwnd≈4192714 pending≈4.37MiB srtt=172ms consec_rto=0
   t≈2s:  inflight=897078  cwnd=1036212  rwnd≈4193668 pending≈4.37MiB srtt=242ms consec_rto=0
   RTO1:  inflight=0       cwnd=1199898  rwnd=4194304 pending≈6.79MiB srtt=633ms consec_rto=1
   RTO2:  inflight=0       cwnd=599949   rwnd=4194304 pending≈6.79MiB srtt=633ms consec_rto=2
   RTO3:  inflight=0       cwnd=299974   rwnd=4194304 pending≈6.79MiB srtt=633ms consec_rto=3
   ```

   Receiver side had full advertised window (`adv≈4194304`) and no out-of-order
   pressure (`oo_bytes=0`) at the visible summaries. The app then timed out:

   ```text
   stream-serve failed: payload write idle at 11272192/16777216
   stream-pull attempt 1 failed: payload idle after 3585141/16777216B
   outbound route no-progress ... consec_rto=2 ... rto_events=1 — cooled rendezvous
   ```

   Interpretation:

   - The bottleneck is not Dart intentionally waiting for ACK before each write:
     `write_all()` only queues into the driver; the sender had MiB of `pending`.
   - It is also not receiver flow-window exhaustion: `rwnd/adv` stayed near
     4 MiB.
   - The single route lost ACK/progress, triggering RTO, then cwnd reduction and
     long pacing/backoff while pending bytes remained. This is the onion-stack
     analogue of ACK-clock collapse: once a route stops yielding cumulative ACK
     progress, one stream can sit with data ready but no useful forward motion.
   - Parallel range streams over multiple rendezvous routes avoid the pathology
     by keeping other routes/streams productive; they do not yet explain/fix the
     single-route failure.

   Next single-route work should instrument one layer lower than
   `veil-onion-stream`: per-route splice delivery/queue counters at the
   rendezvous relay and/or `send_circuit_cell` enqueue/drop/backpressure timing.
   The key question is where DATA/ACK disappears or stalls after the initial
   MiB burst on one route.

14. Follow-up single-route diagnostic with relay-send error reasons:

   Added a non-behavioural diagnostic split below the dispatcher:

   - `SessionTxRegistry::send_to_result()` / `send_to_arc_result()` now expose
     `Missing | Full | Closed` while preserving the old bool API.
   - `onion-stream.circuit-data` summary now reports
     `send_err=missing:X full:Y closed:Z`.

   Test:

   ```text
   scratchpad/soak-auto-16m-single-senderr-20260701-191253

   SOAK_STREAM_RANGE_ENABLED=false
   SOAK_ONION_STREAM_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_ACK_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT=0
   SOAK_ONION_STREAM_DEBUG_SUMMARY_MS=1000
   SOAK_SIZE=16777216
   result: failed as expected, downloaded_size=2359296 / 16777216
   ```

   Key result: endpoint-side bounded `SessionTxRegistry` drops were NOT the
   observed failure in this run:

   ```text
   android: send_err=missing:0 full:0 closed:0 throughout
   desktop: send_err=missing:0 full:0 closed:0 throughout
   no LIMIT tx_queue logs
   ```

   The stream still was not stop-and-wait before failure:

   ```text
   sender before collapse:
   inflight=1383936 cwnd=1432908 rwnd=4184446 pending=4275593 srtt=880ms consec_rto=0

   later:
   consec_rto=1/2/3/4/5, pending≈5.9MiB, rwnd≈4MiB
   stream-serve failed: payload write idle at 9699328/16777216
   stream-pull attempt 1 failed: payload idle after 2517367/16777216B
   ```

   New smoking gun: the receiver desktop lost its session to the first hop used
   by the active return circuit:

   ```text
   [1782922666.805] WARN session.writer.write_error peer_id=c92b85df len=434 error=Broken pipe
   [1782922666.806] INFO session.close link_id=0x0000000000000001
   anonymity.rendezvous_recipient.event_driven_reregister registered with 2 rendezvous relays
   onion-stream[7084a345]: outbound route stale ... path=c92b85df>3d3575c9 first_hop=c92b85df live=false
   [1782922667.103] INFO session.open ... node_id=c92b85df
   anonymity.rendezvous_recipient.event_driven_reregister registered with 3 rendezvous relays
   ```

   Interpretation update:

   - The user’s “some layer waits for confirmation before more data” analogy is
     directionally right, but the wait is not in Dart/app writes and not in
     normal stream CC. Before the transport/session churn, the stream had >1 MiB
     in flight.
   - The actual collapse starts when the receiver-side transport session to a
     first hop breaks. After that, DATA/ACK progress through the receiver return
     circuit becomes inconsistent; the sender keeps data pending but cumulative
     ACK progress stalls, so NewReno/RTO backoff makes the stream effectively
     ACK-gated.
   - Endpoint `SessionTxRegistry` queue-full is ruled out for this run. The next
     suspect is stale rendezvous/circuit state after first-hop reconnect:
     relay R may continue splicing to an old return circuit until teardown/GC or
     until a fresher same-cookie registration fully replaces it. Need relay-side
     counters/logs on the seeds to see `splice_ok/fail`, `ret_relay_fail`, and
     send-error reason at the actual rendezvous/first-hop nodes.

   Next fix direction:

   1. On session close/reconnect, aggressively invalidate/rebuild affected
      receive circuits and make same-cookie refresh clearly replace old
      circuit bindings at R.
   2. Add/deploy relay-side circuit-data diag to the seed nodes (same
      `send_err` split) so the next single-route run proves whether R/first-hop
      is splicing into a stale/dead return circuit.
   3. Keep parallel range streams as the practical throughput path, but do not
      treat them as the root-cause fix for single-route ACK collapse.

15. Stable outbound peer-tag fix and 8 MiB single-route validation:

   Root cause refined: published-mode non-handshake cells carry only
   `[peer_tag][cell]`; the encrypted peer-intro is attached only to SYN/SYN_ACK.
   Before this fix, every newly opened outbound route generated a fresh random
   `peer_tag`. If an ACK route was rebuilt after a first-hop session close, the
   old stream's ACKs could start using a tag the remote side had never learned.
   The cell would be delivered but demux as an unknown/legacy sender, so the
   sender saw no cumulative ACK progress and fell into RTO/backoff.

   Fix:

   ```text
   veilclient-ffi anon_stream:
   - add hub-local outbound node -> peer_tag map
   - reuse one outbound peer_tag for all rebuilt routes to the same peer
   - keep inbound tag -> node map unchanged
   ```

   Validation run:

   ```text
   scratchpad/soak-auto-8m-single-stabletag-20260701-192759

   SOAK_STREAM_RANGE_ENABLED=false
   SOAK_ONION_STREAM_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_ACK_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT=0
   SOAK_ONION_STREAM_DEBUG_SUMMARY_MS=1000
   SOAK_SIZE=8388608
   ```

   Result:

   ```text
   source size/download size: 8388608 / 8388608
   sha256 both: d07eceb7ce49226ae2d42424cc1eba8dfa5837f7d9aac0407c8615d2d40c45ef
   final driver: pending=0, consec_rto=0, fin(req=true,sent=true,ack=true)
   ```

   Importantly, the test did hit the same transport churn class:

   ```text
   desktop: session.writer.write_error peer_id=c92b85df len=434 error=Broken pipe
   desktop: outbound route stale ... path=c92b85df>3d3575c9 first_hop=c92b85df
   android sender: one consec_rto=1 episode, then recovered and completed
   ```

   This is the strongest evidence so far that the previous single-route stalls
   were not caused by app-layer stop-and-wait, nor endpoint queue-full, but by
   route rebuilds changing the demux tag for an already-established stream.
   Stable per-peer tags allow ACK/DATA cells after a route switch to continue
   demuxing on the remote hub.

   Caveat: this run was reliable but slow (`active_elapsed=61s`,
   `avg_mib_per_sec=0.131`) because it intentionally forced one route/pool=1 and
   took an RTO. The speed path remains the parallel/range profile; next speed
   validation should rerun p14/p16/p18 with the stable-tag fix and compare:

   - correctness: SHA/size with no empty files/spinners
   - robustness: no `stream-pull failed`, no permanent `route no-progress`
   - throughput: target ≥1.5 MiB/s on the autonomous harness

16. Stable-tag speed validation: 64 MiB p16 passes target

   After the stable outbound peer-tag fix, reran the autonomous speed profile:

   ```text
   scratchpad/soak-auto-64m-p16-stabletag-20260701-193240

   SOAK_STREAM_RANGE_ENABLED=true
   SOAK_STREAM_RANGE_PARALLELISM=16
   SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT=0
   SOAK_SIZE=67108864
   ```

   Result:

   ```text
   source size/download size: 67108864 / 67108864
   sha256 both: ba071fd6faf05d2092698bdc055986b6ad15b77ea4f8d8d8e15dc64328510cd0
   final_size_bytes=67108864
   active_elapsed_sec=20
   avg_mib_per_sec=3.200
   wall_elapsed_sec=40
   wall_avg_mib_per_sec=1.600
   fault_status=none
   ```

   Focused log scan found no target-transfer symptoms for:

   ```text
   route no-progress
   stream-serve failed
   stream-pull attempt .*failed
   LIMIT tx_queue
   send_err=missing/full/closed
   Broken pipe
   ```

   Interpretation:

   - The latest fast run no longer looks like "one payload chunk waits for one
     ACK". Parallel range workers are keeping multiple reliable streams active,
     and the aggregate wall throughput reaches the original ≥1.5 MiB/s target.
   - Single-route remains slow by design/physics of the current onion-stream
     stack: NewReno window + SRTT pacing + delayed ACK + RTO recovery. When ACK
     progress is lost, it can collapse into an effectively ACK-gated/RTO-gated
     mode, which matches the user's syncookie/wscale-style intuition at the
     symptom level.
   - The concrete bug that made this catastrophic was not endpoint queue-full or
     app-layer stop-and-wait, but route rebuilds changing the published-mode
     peer tag for already-established streams. Stable per-peer tags fixed that
     class enough for p16/64 MiB to pass with correct SHA.

   Remaining work:

   1. Repeat p14/p16 at least once after cleanup to make sure the result is
      stable, not a lucky run.
   2. Keep the single-route investigation separate: instrument SRTT/pacing,
      ACK rate, actual inflight, and route/session churn to explain the low
      single-stream ceiling rather than hiding it behind range fanout.
   3. Production privacy polish: stable per-peer tags should rotate when no
      active streams need continuity, so route rebuild resilience does not turn
      into unnecessary long-lived linkability.

17. Repeat validation and no-progress cooldown tuning:

   Repeated the autonomous 64 MiB p16 run after the stable-tag fix:

   ```text
   scratchpad/soak-auto-64m-p16-stabletag-rerun-20260701-193721

   SOAK_STREAM_RANGE_ENABLED=true
   SOAK_STREAM_RANGE_PARALLELISM=16
   SOAK_ONION_STREAM_BULK_ROUTE_ACTIVE_LIMIT=0
   SOAK_MIN_MIB_PER_SEC=1.5
   ```

   Result:

   ```text
   source/download sha256:
   bfeb5890a012f0b341d7d06512b21cf788e40172afd04e0877f1446563688990

   final_size_bytes=67108864
   active_elapsed_sec=31
   avg_mib_per_sec=2.065
   wall_elapsed_sec=51
   wall_avg_mib_per_sec=1.255
   fault_status=none
   ```

   Focused stream/circuit scan found no target-transfer `route no-progress`,
   `stream-pull failed`, `stream-serve failed`, `LIMIT tx_queue`, non-zero
   `send_err`, transport `Broken pipe`, or RTO symptoms. The transfer was
   correct and fast in the active download phase; wall time was below 1.5 MiB/s
   because of offer/start overhead.

   Then tested p14 as a potential safer default:

   ```text
   scratchpad/soak-auto-64m-p14-stabletag-rerun-20260701-193931
   ```

   It completed with correct SHA, but hit real route/session churn and missed
   the speed gate:

   ```text
   desktop: session.primary_closed peer_id=c92b85df ... Connection reset by peer
   android: outbound route no-progress ... consec_rto=2 ... cooled rendezvous for 60s

   final_size_bytes=67108864
   avg_mib_per_sec=0.901
   wall_avg_mib_per_sec=0.696
   sha256 matched
   ```

   This was good evidence for reliability (file still arrived intact after
   churn) but bad for speed. The cooldown was too punitive for a 3-seed test
   network: a stream-level no-progress signal cooled a rendezvous relay for the
   same 60s used for a hard send failure, effectively removing a large fraction
   of parallel capacity for the rest of the transfer.

   Change:

   ```text
   CIRCUIT_ROUTE_NO_PROGRESS_COOLDOWN = 15s
   CIRCUIT_ROUTE_SEND_COOLDOWN remains 60s
   ```

   Validation after rebuilding native:

   ```text
   scratchpad/soak-auto-64m-p14-noprogress15-20260701-194302
   final_size_bytes=67108864
   avg_mib_per_sec=1.049
   wall_avg_mib_per_sec=0.780
   sha256 matched
   no target stream/circuit failures in focused scan
   ```

   The shorter cooldown did not hurt correctness, but p14 still did not meet
   speed target even without visible stream/circuit errors.

   Final p16 control on the rebuilt native:

   ```text
   scratchpad/soak-auto-64m-p16-noprogress15-20260701-194716

   source/download sha256:
   955b8adaf842a3a10b378ed8fd609e490b28fcc97cff76d982937352996b4858

   final_size_bytes=67108864
   active_elapsed_sec=21
   avg_mib_per_sec=3.048
   wall_elapsed_sec=41
   wall_avg_mib_per_sec=1.561
   fault_status=none
   trigger.status=0
   ```

   Focused scan was empty for:

   ```text
   session.primary_closed
   route no-progress
   stream-serve failed
   stream-pull attempt .* failed
   LIMIT tx_queue
   send_err=missing/full/closed
   transport Broken pipe
   payload/write idle
   DataRto/consec_rto
   ```

   Current operational conclusion:

   - p16 is the current speed profile that satisfies both file-save correctness
     and the ≥1.5 MiB/s target on the live phone↔desktop autonomous harness.
   - p14 is reliable but too slow on this stand; keep it only if we later need a
     more conservative profile.
   - The remaining open engineering question is still the single-route ceiling:
     p16/range fanout solves practical throughput, but we still need an
     isolated single-route experiment for ACK-rate/SRTT/pacing/inflight to
     explain why one route is so low.

18. Single-route FIN-tail RTO bug and regression check:

   Ran an isolated single-route diagnostic after the p16 success:

   ```text
   scratchpad/soak-auto-16m-single-diagnose-20260701-195001

   SOAK_STREAM_RANGE_ENABLED=false
   SOAK_ONION_STREAM_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_ACK_OUTBOUND_POOL=1
   SOAK_ONION_STREAM_DEBUG_SUMMARY_MS=1000
   SOAK_SIZE=16777216
   ```

   It completed with correct SHA, but the tail was pathological:

   ```text
   final_size_bytes=16777216
   wall_elapsed_sec=245
   active_elapsed_sec=234
   avg_mib_per_sec=0.068
   sha256 matched
   ```

   Key timeline:

   ```text
   stream-serve failed ... payload write idle at 11010048/16777216
   desktop: session.primary_closed peer_id=c6ace22e ... Connection reset by peer
   stream-pull attempt 2 failed ... payload idle after 14712394/16777216B
   ```

   Driver summary before the long stall showed the real single-route problem:

   ```text
   phase=Established
   pending=0
   inflight≈2.06MiB
   segs≈6496(sack=0 resend=1)
   fin(req=true,sent=true,ack=false)
   srtt=Some(829)
   rto=20000ms -> 40000ms -> 60000ms
   ```

   Interpretation:

   - This is not app-layer "one packet then wait for ACK" during the healthy
     part; before failure the stream had MiBs in flight.
   - After route/session churn, the sender had no SACK feedback and a FIN in
     the outstanding flight. The existing circuit no-SACK RTO rewind was gated
     by `!s.is_fin`, so the exact tail case disabled rewind. The stream then
     kept a huge phantom in-flight tail and repaired roughly one segment per
     exponentially backed-off RTO.

   Fix in `veil-onion-stream`:

   ```text
   - no-SACK rewind now allows a flight that contains DATA plus FIN
   - rewound FIN sets fin_sent=false so FIN is resent after the requeued DATA
   - late cumulative ACK for the old rewound FIN marks fin_acked without
     draining one extra byte from pending (FIN consumes sequence space, not a
     payload byte)
   - regression test: no_sack_rto_rewind_handles_fin_tail
   ```

   Unit verification:

   ```text
   cargo test -p veil-onion-stream no_sack_rto_rewind -- --nocapture
   # 2 passed: preserves earned window floor + handles FIN tail

   cargo check -p veilclient-ffi --features veilclient-ffi/node-embedded
   ```

   Live single-route after rebuilding native:

   ```text
   scratchpad/soak-auto-16m-single-fintailfix-20260701-195717

   final_size_bytes=16777216
   wall_elapsed_sec=102
   active_elapsed_sec=81
   avg_mib_per_sec=0.198
   sha256 matched
   ```

   This run still hit a serve-side idle timeout:

   ```text
   stream-serve failed ... payload write idle at 14155776/16777216
   desktop: session.writer.write_error peer_id=c6ace22e ... Broken pipe
   stream-pull attempt 1 failed ... stream EOF mid-piece 55
   ```

   But it did not reproduce the previous multi-minute FIN-tail stall; the
   transfer finished 2.4x faster (245s -> 102s) and remained correct.

   p16 regression check on the same native build:

   ```text
   scratchpad/soak-auto-64m-p16-fintailfix-20260701-200158

   final_size_bytes=67108864
   active_elapsed_sec=21
   avg_mib_per_sec=3.048
   wall_elapsed_sec=41
   wall_avg_mib_per_sec=1.561
   fault_status=none
   sha256 matched
   trigger.status=0
   ```

   Focused scan was empty for target-transfer:

   ```text
   session.primary_closed
   route no-progress
   stream-serve failed
   stream-pull attempt .* failed
   LIMIT tx_queue
   send_err=missing/full/closed
   transport Broken pipe
   payload/write idle
   DataRto/consec_rto
   ```

   Updated conclusion:

   - Practical file-save + autonomous harness + ≥1.5 MiB/s p16 goal remains
     satisfied after the engine fix.
   - One single route is still slow (~0.2 MiB/s after this fix) and still can
     hit serve idle under route churn, but the worst FIN-tail RTO pathology is
     fixed.
   - The next single-route optimization target is not BBR yet; it is the
     combination of large RTO defaults (`10s` minimum despite `srtt≈160-900ms`)
     and route churn/serve idle. Lowering circuit RTOs or surfacing a quicker
     stream reset on route no-progress should be tested carefully against p16.

20. 2026-07-01 — queue-full vs effective-window hypothesis, fast-retransmit
    floor, and stale-route reset experiment

   User hypothesis: the single-route ceiling resembles a broken effective
   window / stop-and-wait implementation, not a VPS bandwidth limit. Current
   evidence supports the shape, but the live bottleneck was not session
   `TX_QUEUE_FULL` in the latest runs.

   Changes kept:

   - `veil-node-runtime` now exposes detailed circuit send failure:
     `DataCircuitSendError::{NoRelays, QueueFull, PayloadTooLarge}`.
   - `send_circuit_cell_detailed()` maps session `SendToError::Full` to
     `QueueFull` instead of flattening it into `NoRelays`.
   - circuit stream sender maps `QueueFull` to `io::ErrorKind::WouldBlock`;
     the async stream driver keeps the encoded stream cell and retries it after
     1ms instead of silently dropping it and manufacturing stream loss.
   - stream fast-retransmit now applies the same earned-window floor as
     no-SACK RTO rewind while `rewind_high` is active. Stale dupACKs arriving
     after rewind still trigger repair, but cannot recut `ssthresh` down to a
     tiny post-rewind probe flight.
   - regression test:
     `dupacks_after_rewind_do_not_recut_ssthresh_to_tiny_flight`.

   Verification:

   ```text
   cargo check -p veil-onion-stream -p veil-node-runtime -p veilclient-ffi \
     --features veilclient-ffi/node-embedded

   cargo test -p veil-onion-stream -- --nocapture
   # 17 unit + 4 async_sim + 3 mux_fault + 13 sim passed
   ```

   Live single-route queue-full experiment:

   ```text
   scratchpad/soak-auto-16m-single-backpressure-nobuild-20260701-202204

   final_size_bytes=16777216
   sha256 matched
   active_elapsed_sec=111
   avg_mib_per_sec=0.144
   TX channel FULL=0
   first-hop TX queue full=0
   outbound route stale=1
   primary_closed=1
   payload write idle=2
   ```

   Conclusion: explicit `WouldBlock` is still the correct safety semantics for
   future queue-full events, but it was not the observed live limiter in this
   run.

   Live single-route after fast-retransmit floor:

   ```text
   scratchpad/soak-auto-16m-single-fastretx-floor-20260701-202701

   final_size_bytes=16777216
   sha256 matched
   bulk phase: ~3 MiB -> ~14.5 MiB in ~10s
   final avg_mib_per_sec=0.112 active / 0.098 wall due to tail stall
   ```

   Important positive signal: the previous post-RTO collapse to `ssth≈636..1908`
   no longer happened. The stream held a much larger repair window
   (`ssth≈392-409 KiB` in the tail), and the main bulk moved much faster.

   Remaining single-route problem in that run:

   ```text
   outbound route stale ... first_hop=c92b85df live=false
   stream-pull attempt 1 failed ... payload idle after 15319722/16777216B
   ```

   The last ~1.3 MiB waited for the app-level idle/resume path. This points to
   route/session churn and tail-hole recovery, not the old tiny-window collapse.

   Rejected experiment:

   - Tried returning a fast `ConnectionReset` from the circuit sender when a
     selected route was stale/broken.
   - Live run:

     ```text
     scratchpad/soak-auto-16m-single-stalereset-20260701-203314
     trigger failed with status 22
     progress stuck at 3145728/16777216
     stream-pull attempt 1 failed ... onion stream reset (0)
     repeated stream-serve failed ... Future not completed
     ```

   - Reverted that behavior. Current content-layer retry/open semantics do not
     tolerate this reset style yet. A future version needs coordinated
     route-failover/resume, not a raw stream reset at this layer.

   p16 regression after reverting stale-reset and rebuilding native:

   ```text
   scratchpad/soak-auto-64m-p16-after-floor-20260701-204036

   final_size_bytes=67108864
   sha256 matched
   fault_status=none
   avg_mib_per_sec=1.049 active
   wall_avg_mib_per_sec=0.780
   TX channel FULL=0
   primary_closed=0
   write_error=0
   payload write idle=0
   stream-pull attempt=0
   onion stream reset=0
   outbound route no-progress=2
   ```

   Delivery remains correct, but this p16 run was slower than the previous best
   (`3.048 MiB/s active`) because multiple range pieces hit 20s idle/resume and
   one rendezvous route reported no-progress. The speed goal is therefore not
   conclusively satisfied after this turn; current best practical path is still
   parallel range, while the next bottleneck is route no-progress / range-piece
   idle under route churn.

21. 2026-07-01: “похоже на stop-and-wait” оказалось RTO-floor/repair wait
-------------------------------------------------------------------------------

User hypothesis: the bottleneck may not be the VPS at all, but our stack waiting
for some confirmation before sending more data, similar to a TCP window-scale
breakage where throughput becomes `chunk / RTT`.

Diagnostic p16 run with native debug summaries:

```text
scratchpad/soak-auto-16m-p16-debug-stopwait-20260701-205115

size=16 MiB
workers=16
debug_summary=2000ms
fault_status=none
```

Key evidence:

```text
sender stream examples near the first bulk phase:
inflight≈100-188 KiB
cwnd≈195-478 KiB
rwnd=4 MiB
srtt≈326-499ms
consec_rto=0

receiver srtt≈147-227ms, delayed ACK active
```

So this is not classic one-cell stop-and-wait during the healthy part: streams
do have meaningful bytes in flight and windows are not collapsed to 1 MSS.

But the bad phase matched the user’s intuition at the repair layer. With the
old circuit defaults:

```text
rto=12000/10000/60000ms
```

a small hole/no-progress event parked a range worker until a 10s RTO, then a
20s backoff. In the logs this appeared as:

```text
swarm-range resume ... after TimeoutException 20s
stream-pull retry-open ...
```

This creates staircase throughput: burst of data, long idle plateau, then next
burst. The stand is idle, but the stack is waiting for repair timeouts.

Validation by config-only run:

```text
scratchpad/soak-auto-64m-p16-rto1s-20260701-205326

SOAK_ONION_STREAM_INIT_RTO_MS=2000
SOAK_ONION_STREAM_MIN_RTO_MS=1000
SOAK_ONION_STREAM_MAX_RTO_MS=10000

final_size_bytes=67108864
fault_status=none
active_elapsed_sec=20
avg_mib_per_sec=3.200
wall_elapsed_sec=50
wall_avg_mib_per_sec=1.280
```

Compared to the same p16 shape with 10s min RTO:

```text
scratchpad/soak-auto-64m-p16-real-after-floor-20260701-204647

avg_mib_per_sec=0.627 active
wall_avg_mib_per_sec=0.421
```

Conclusion: the immediate “ceiling” was not VPS bandwidth and not lack of BBR.
It was an overly conservative circuit RTO floor that turned small holes into
10-20s worker stalls. Defaults were changed to:

```text
circuit init/min/max RTO = 2000/1000/10000ms
```

The BBR discussion is still valid as future congestion-control work, but it is
not the next necessary fix. First keep the NewReno/SACK/RTO stack from parking
workers for seconds on paths whose measured SRTT is sub-second.

22. 2026-07-01: RTO defaults + practical fanout default после p16/p14 regressions
---------------------------------------------------------------------------------

After changing native circuit defaults, the soak harness also needed to set the
same RTO values explicitly for both sides. Otherwise a no-build desktop run
could keep using an older compiled dylib default while Android received the new
debug props.

Harness defaults now propagate:

```text
SOAK_ONION_STREAM_INIT_RTO_MS=2000
SOAK_ONION_STREAM_MIN_RTO_MS=1000
SOAK_ONION_STREAM_MAX_RTO_MS=10000
```

to both desktop env and Android props, unless explicitly overridden.

A control run with p16 and no explicit RTO override confirmed the defaults were
active, but p16 itself is not stable on the current stand:

```text
scratchpad/soak-auto-64m-p16-rto-default-20260701-205722

rto=2000/1000/10000ms on both sides
progress: 8 MiB -> long plateau -> 25.4 MiB -> long plateau
trigger.status=22
```

Symptoms:

```text
many outbound route no-progress
stream-serve failed ... onion stream reset (1)
swarm-range piece failed ... manifest truncated
swarm-range piece failed ... no manifest (sender not serving)
```

Interpretation: faster RTO fixed the old long repair wait, but p16 can create a
route/circuit retry storm. The content layer then opens many replacement streams
while routes are cooling/reopening, and the sender sometimes cannot serve a
manifest before the stream resets. This is a fanout/route-health problem, not
the old 10s RTO-floor problem.

Stable p12 verification with the same defaults:

```text
scratchpad/soak-auto-64m-p12-rto-default-20260701-210415

final_size_bytes=67108864
fault_status=none
active_elapsed_sec=41
avg_mib_per_sec=1.561
wall_elapsed_sec=61
wall_avg_mib_per_sec=1.049
```

There was one relay/session reset:

```text
session.primary_closed peer_id=c92b85df ... Connection reset by peer
```

but the transfer recovered and passed the speed gate.

p14, which had previously looked like a possible default, failed with the new
RTO/fanout behavior on this stand:

```text
scratchpad/soak-auto-64m-p14-rto-default-20260701-210619

progress: 8 MiB -> 14.1 MiB -> stuck until trigger.status=22
```

Therefore the practical application default was moved from 14 workers back to
12 workers:

```text
_defaultStreamRangeParallelism = 12
```

Validation after the default change:

```text
dart format lib/state/messaging.dart
bash -n scripts/onion_stream_soak.sh
git diff --check
cargo check -p veilclient-ffi --features veilclient-ffi/node-embedded
flutter test test/content_stream_transfer_test.dart
```

All passed. The Flutter stream test log shows the default being used as
`workers=12` for a large manifest-ref pull.

Current practical state:

- reliable file-save path: still correct in unit/integration and live p12;
- autonomous soak: works for p12 with SHA/size/fault gate and no manual RTO
  override;
- speed: p12 is just above the 1.5 MiB/s target on a reset-noisy run; p16 can be
  much faster (`3.2 MiB/s active`) but is not stable enough for default.

Next bottleneck: health-aware fanout. The stack needs to lower concurrency or
avoid routes when many streams hit `no-progress`, instead of continuing to open
new range streams into cooled/reopening rendezvous paths. Until then, p14/p16
should remain lab knobs, not default.

## 23. Capped adaptive p16: target reached without manual intervention

After the p16/p14 failures, the content range scheduler was changed to start at
the safe default fanout and only grow cautiously:

```text
requested workers=16
active_limit starts at 12
growth cap = default + 2 = 14
growth step = +1 after each clean 16 MiB
failure step = -1 on route/piece failures
```

Live Android -> desktop soak:

```text
scratchpad/soak-auto-64m-p16-adaptive-cap14-20260701-211956

final_size_bytes=67108864
fault_status=none
active_elapsed_sec=41
avg_mib_per_sec=1.561
wall_elapsed_sec=61
wall_avg_mib_per_sec=1.049
```

Progress samples:

```text
21:21:03  4 MiB
21:21:14  21.5 MiB
21:21:24  40.5 MiB
21:21:34  63.5 MiB
21:21:44  64 MiB complete
```

Relevant logs:

```text
swarm-range start ... pieces=256 workers=16 active_limit=12 ...
swarm-range adapt fanout ... workers=12->13 after 16777216B ok
swarm-range adapt fanout ... workers=13->14 after 16777216B ok
COMPLETE ... (67108864B) saved ...
```

Android route stats during the bulk phase show two rendezvous routes carrying
roughly half the file each, with no send failures and no RTOs:

```text
via R=c6ace22e ... data_bytes=31214689 send_failures=0 rto_events=0
via R=c92b85df ... data_bytes=31209594 send_failures=0 rto_events=0
```

One route hit `outbound route no-progress` near the tail, but only after the
bulk had already completed; the file saved correctly.

This supports the "effective window / ACK-gating somewhere in the stack"
hypothesis in shape, but not as a literal one-packet stop-and-wait in the
current bulk path:

- single-stream/circuit performance can still look RTT-window-limited;
- the stream engine itself has been observed with non-trivial inflight
  (`~100-188 KiB`) and live `cwnd`, so the problem is likely an interaction
  between circuit route health, backpressure, RTO repair, and file-layer stream
  fanout rather than pure TCP/VPS capacity;
- parallel range streams across different rendezvous routes bypass the small
  single-path effective window and meet the current 1.5 MiB/s target.

Remaining investigation: isolate a single-route synthetic test with direct
`srtt/rto/inflight/blocked_cell/route_queue` counters to find why one path has
such a low stable throughput ceiling, then decide whether to tune that layer or
keep parallel range striping as the production speed path.

## 24. Single-stream after RTO/backpressure fixes: no longer 135 KiB/s, but still below parallel

Two autonomous Android -> desktop runs with range striping disabled
(`SOAK_STREAM_RANGE_ENABLED=false`, `parallelism=1`, `outbound_pool=1`,
`ack_pool=1`) establish the current single-stream baseline.

Short 16 MiB run:

```text
scratchpad/soak-auto-16m-single-summary-20260701-212326

final_size_bytes=16777216
fault_status=none
active_elapsed_sec=10
avg_mib_per_sec=1.600
```

Longer 64 MiB run:

```text
scratchpad/soak-auto-64m-single-summary-20260701-212524

final_size_bytes=67108864
fault_status=none
active_elapsed_sec=50
avg_mib_per_sec=1.280
```

This disproves the old "single circuit is capped at ~135 KiB/s" as a current
steady-state statement. That cap was largely the old RTO/backpressure/repair
behavior. However, one stream still underfills the available windows:

```text
cwnd ≈ 1.43 MiB
rwnd ≈ 4 MiB
inflight ≈ 0.65-0.76 MiB
srtt ≈ 500-850 ms
rto = 1000 ms
send_failures = 0
rto_events = 0
```

The measured throughput matches the effective in-flight window:

```text
~0.7 MiB / ~0.55 s ≈ ~1.27 MiB/s
```

So the user's "syncookies/wscale-shaped" suspicion is correct in form: the
limit now behaves like an RTT-dependent effective-window cap. It is not a VPS
bandwidth limit and not literal one-packet stop-and-wait; it is a stack-level
underfill of `cwnd/rwnd`.

### Negative experiment: pacing catch-up

Hypothesis: `poll_transmit()` released one pacing budget per driver wakeup and
dropped missed 1 ms ticks, so scheduler jitter could keep `inflight` below
`cwnd`. A bounded catch-up patch was tried locally and deployed to the devices:
accumulate up to 4 missed ticks, capped by `max_pacing_batch`.

Live result:

```text
scratchpad/soak-auto-64m-single-pacecatchup-20260701-213047

final_size_bytes=67108864
fault_status=none
active_elapsed_sec=61
avg_mib_per_sec=1.049
```

It was slower than the previous single-stream baseline. Sender summaries showed
that `cwnd/ssthresh` fell to roughly `480 KiB / 461 KiB`, with no resets and no
RTO events. Interpretation: even bounded catch-up likely created enough
microburst/queue pressure to trigger loss/fast-recovery and shrink the usable
window. The patch was reverted; `cargo test -p veil-onion-stream` passed after
the revert.

Next single-route direction: do not blindly add catch-up/burst. Add explicit
driver/carrier counters for:

- actual pacing wake delay (`now - pace_next_ms`);
- budget released vs cells actually accepted;
- `WouldBlock` retry count and blocked-cell age;
- ACK inter-arrival / cumulative ACK advance;
- fast-recovery entry cause when `ssthresh` is cut without RTO.

That should identify whether the remaining underfill is scheduler loss,
ACK-clock shape, carrier queue pressure, or congestion-control window cuts.

## 25. Driver diagnostics: not local WouldBlock; spurious/early RTO is visible

Added debug-only driver summary fields:

```text
now=<driver-ms>
blocked_cell=<bool>
blocked_age=<ms>
wb_total=<count>
wb_retries=<count>
wb_recovered=<count>
```

This is emitted only when onion-stream debug summaries are enabled.

Validation:

```text
cargo test -p veil-onion-stream
```

passed after the diagnostic-only patch.

Live clean single-stream diagnostic run:

```text
scratchpad/soak-auto-16m-single-driverdiag-20260701-213745

final_size_bytes=16777216
fault_status=none
active_elapsed_sec=11
avg_mib_per_sec=1.455
```

Key sender summaries:

```text
now=4000 blocked_cell=false wb_total=0
inflight=1550886 cwnd=1690806 srtt=1177 rto=1221 rto_dl=5221

now=6150 blocked_cell=false wb_total=0
inflight=0 cwnd=1051626 ssth=1051626 consec_rto=1 srtt=1425 rto=3082
```

Interpretation:

- clean single-stream does not appear to be blocked by local carrier
  backpressure (`wb_total=0`);
- a large RTT/ACK delay spike can make the sender fire RTO and cut `cwnd`,
  even though there are no `send_failures`;
- this explains the observed `cwnd` cuts and the RTT-window-shaped throughput
  ceiling better than the old "one packet at a time" theory.

### Negative experiment: min RTO 2000 ms

Tried to suppress spurious RTO by raising only the live test's min RTO:

```text
scratchpad/soak-auto-64m-single-minrto2s-20260701-214139

SOAK_ONION_STREAM_INIT_RTO_MS=2000
SOAK_ONION_STREAM_MIN_RTO_MS=2000
SOAK_ONION_STREAM_MAX_RTO_MS=10000
```

The run was stopped after it stayed stuck at 3 MiB for more than a minute:

```text
session.primary_closed peer_id=c92b85df ... Connection reset by peer
stream-serve failed ... TimeoutException ... payload write idle at 11272192/67108864
```

Conclusion: simply raising the RTO floor is not acceptable. It may reduce
spurious RTOs on a merely delayed path, but it also delays failure/recovery when
a rendezvous/session path actually goes black. The next fix must classify the
case more precisely, e.g. route/session failure should fail fast and resume,
while ACK-delay/jitter should avoid cutting a healthy stream window too hard.

## 26. 2026-07-02: receiver-side fast failover — stall-abandon + tail hedging

Диагноз по прогонам `default-softloss` (0.901) / `default-quarantine` (1.032):
корректность стабильна, но скорость съедают два хвостовых механизма:

1. Range-воркер, чей stream попал на битый маршрут, ждёт ПОЛНЫЙ payload idle
   (10s) прежде чем abort+resume — хотя native на стороне отправителя ремапит
   такой stream уже через ~3s (consec_rto=2), а остальные воркеры в это время
   активно качают.
2. В хвосте передачи, когда pending пуст, свободные воркеры просто выходили —
   один застрявший range пиннил завершение до своего idle timeout.

Изменения (Dart, `lib/state/messaging.dart`):

- **Swarm progress tick**: каждый принятый payload chunk любого воркера
  инкрементирует общий счётчик; каждый range-читатель сравнивает его снапшот
  на момент своего последнего chunk'а.
- **Stall-abandon**: если swarm продвинулся, а этот stream молчит >=
  `XVEIL_STREAM_RANGE_STALL_ABANDON_MS` (default 2500ms), читатель бросает
  `_RangeStallTimeout`, abort'ит stream (это освобождает blocked FFI read и
  RST'ом отдаёт серв-слот отправителю) и резюмирует с `got` на свежем stream —
  native pool выбирает другой маршрут. Полный idle timeout (10s) остаётся для
  случая «глобально всё тихо» (route churn бьёт по всем — не буря resume'ов).
  Stall-abandon при got=0 ретраит НА МЕСТЕ (не проваливает range в
  requeue/фанаут-shrink), в отличие от старого «no manifest» пути.
- **Tail hedging**: свободный воркер (pending пуст) дублирует самый тихий
  in-flight range (молчит >= `XVEIL_STREAM_RANGE_HEDGE_MS`, default 3000ms) на
  свежем stream; первый успевший побеждает (pieces верифицируются, дубль
  байт-идентичен). Максимум 1 hedge на задачу, до 2 одновременно. Бонус: чанки
  хеджа оживляют progress tick, что даёт застрявшему оригиналу сработать по
  stall-abandon.
- Пороги инжектируются через конструктор + dart-define + soak env
  (`SOAK_STREAM_RANGE_STALL_ABANDON_MS`, `SOAK_STREAM_RANGE_HEDGE_MS`).
- Тесты: `content_stream_transfer_test.dart` +2 (stall-abandon при живом swarm;
  tail hedge при молчащем единственном range). Полный набор: 429 green.

Live A/B (Dart-only, native прежний, default p8/1MiB/routecap2):

| run | active MiB/s | события |
| --- | ---: | --- |
| stallhedge  | 1.255 | 2 stall-abandon (~2.5s вместо 10s), 4 hedge в хвосте, SHA ok |
| stallhedge2 | 1.049 | 2 stall-abandon, 2 hedge, SHA ok |

Оба механизма сработали как задумано, но скорость не выросла — потому что
вскрылся доминирующий native-баг (см. §27): quarantine-каскад выкашивал весь
outbound pool в середине передачи, и лечить хвосты было недостаточно.

## 27. 2026-07-02: quarantine-каскад — consec_rto не route-локален

Смок-ган в `stallhedge` логах Android (отправитель):

```text
no-progress remap    stream=29 via R=c6ace22e first_hop=3d3575c9 consec_rto=2 stream_rto_events=2
quarantine           stream=29 via R=c6ace22e first_hop=3d3575c9 consec_rto=3 stream_rto_events=3
quarantine           stream=29 via R=3d3575c9 first_hop=c92b85df consec_rto=4 stream_rto_events=1  <-- свежий маршрут!
circuit open failed ... first-hop 3d3575c9 cooled   (по кругу)
quarantine           stream=47 via R=c92b85df first_hop=c6ace22e consec_rto=5 stream_rto_events=1
```

`consec_rto` — кумулятивный счётчик STREAM'а: он не сбрасывается при remap на
другой маршрут (engine не знает о маршрутах, сброс только по прогрессу
snd_una). Условие `quarantine = consec_rto >= 3 || ...` поэтому карантинило
каждый следующий свежий маршрут после ОДНОГО RTO на нём (`stream_rto_events=1`),
и один больной stream за ~5 секунд охлаждал все 3 rendezvous + все first-hop
(20s cooldown) → пул схлопывался, скорость падала до одного выжившего маршрута,
новые open'ы падали «first-hop cooled».

Фикс (`veilclient-ffi/src/anon_stream.rs`, `mark_route_no_progress`): карантин
требует route-локальных улик — `stream_rto_events >= 2` НА ЭТОМ маршруте
(плюс прежние условия); мёртвая first-hop session карантинится сразу, как
раньше. Первый RTO на свежем маршруте даёт только мягкий remap этого stream'а.


## 28. 2026-07-02: pool-preserving guard + корень stall'ов = СИДЫ рвут сессии

Прогон `quarfix` (route-локальный гейт карантина, native пересобран):

```text
scratchpad/soak-auto-64m-quarfix-20260702-030002
avg_mib_per_sec=0.901 active, SHA ok
старт ~1.8 MiB/s, на 03:04:49 ДВА одновременных ЛЕГИТИМНЫХ карантина
(каждый с >=2 route-локальными RTO) охладили relay {3d,c92} + first-hop
{3d,c92} → R=c6ace22e недостижим (его пути идут через охлаждённые first-hop)
→ пул пуст ~20s, «circuit open failed: first-hop cooled» по кругу.
```

Вывод: route-локальный гейт нужен, но недостаточен — на 3-сидовом стенде
чистая пара quarantine всё равно может обнулить пул.

Фикс 2 — pool-preserving guard в `mark_route_no_progress`: перед охлаждением
(relay, first_hop) проверяется, останется ли хотя бы один usable open route
(не карантинный, не в cooldown, first-hop live). Если full-scope обнуляет пул —
масштаб понижается: только relay; если и это обнуляет — только remap без
cooldown. Retire circuits самого relay остаётся всегда (fresh reopen может
вылечить stale splice). Лог карантина теперь печатает
`cooled ... (relay=bool first_hop=bool)`.

Прогон `poolguard` (оба native-фикса):

```text
scratchpad/soak-auto-64m-poolguard-20260702-030919
avg_mib_per_sec=1.231 active, SHA ok, дип короче (7.3->12.6 MiB/10s к концу)
```

Сводка после Dart+native фиксов: 1.255 / 1.049 / 0.901 / 1.231 — корректность
железная, но дип в середине остаётся во ВСЕХ прогонах, и каждый раз совпадает с
`session.primary_closed peer_id=<seed> ... Connection reset by peer`.

**Корень найден на стороне СИДОВ**: лог seed .134 (c92b85df) в момент дипа
1782951128-1133 показывает `session.close link_id=...` БЕЗ primary_closed/
ошибки — сид сам закрывает сессию под bulk-нагрузкой, клиент видит RST через
27ms. Это ровно класс «bounded session queue Full трактуется как смерть
сессии», починенный в рабочем дереве veil-session (grouped encrypt, writer
admission, Full != death) — но задеплоенный сидовый бинарь от 2026-06-18/25
этих фиксов не содержит. Сиды также не имеют circuit-data диагностики (grep
пустой).

Следующий шаг: musl-пересборка из текущего дерева + staggered redeploy 3 сидов
(рецепт в memory fixb-keygiven-fetch-and-empty-dht-root), затем контрольные
прогоны.

## 29. 2026-07-02: seed redeploy = устранение mid-transfer дипов; цель достигнута

Musl-пересборка из текущего дерева
(`FEATURES=rocksdb-cold,tls-boring,production-seeds scripts/cross-build-linux-musl.sh`)
и staggered binary-only redeploy всех 3 сидов (identity/var/lib/veil не
тронуты, rollback-страховка, metrics-gate). Сиды получили: фиксы veil-session
(bounded queues, grouped encrypt, writer admission, Full != смерть сессии),
splice/circuit-data диагностику и весь onion-stream стек текущего дерева.

Контрольные прогоны (autonomous harness, default p8/1MiB/pool3/routecap2,
все Dart+native фиксы этой сессии, gate >=1.5 MiB/s):

| run | active MiB/s | wall | события |
| --- | ---: | ---: | --- |
| newseeds 64 MiB | **3.200** | 1.255 | 0 stall, 0 reset, 0 quarantine; SHA+cmp ok |
| newseeds-repeat 64 MiB | **2.133** | 1.032 | чисто; gate pass |
| newseeds-long 256 MiB | **1.571** | 1.391 | ровные 1.6-2.1 MiB/s все 163s; 0 reset; 14 мягких remap (все stream_rto_events=1 -> гейт корректно НЕ карантинил маршруты, пул 3/3 весь прогон); 3 tail hedge; CMP-OK |

До/после (64 MiB, default): 0.90-2.07 с 10-30s дипами -> 2.1-3.2 без дипов;
длинный 256 MiB стабильно выше цели 1.5 MiB/s.

Итоговый стек фиксов этой сессии:

1. (Dart) stall-abandon: заглохший range-stream бросается через 2.5s, если
   swarm живёт; resume с got на свежем маршруте.
2. (Dart) tail hedging: свободные воркеры дублируют самый тихий in-flight
   range в хвосте.
3. (native) quarantine только по route-локальным уликам (stream_rto_events>=2
   на ЭТОМ маршруте) — один больной stream больше не выкашивает пул.
4. (native) pool-preserving guard — cooldown никогда не обнуляет пул
   (downgrade full->relay-only->remap-only).
5. (сиды) redeploy текущего бинаря — корень mid-transfer дипов: старый сидовый
   бинарь рвал TCP/obfs4 сессию под bulk-нагрузкой (класс "queue Full =
   session death", давно починенный в клиентском дереве).

Открытое (следующий уровень скорости, если понадобится >3 MiB/s):
- поднять default fanout/range с p8/1MiB (стенд теперь чистый — старые выводы
  про p12-p16 надо перемерить на новых сидах);
- resume-попытка всё ещё может ждать manifest до 25s (stall-детектор покрывает
  только payload-фазу) — hedge это маскирует, но можно закрыть напрямую;
- circuit-data диагностика теперь есть и НА сидах — при следующем расследовании
  смотреть splice/queue счётчики там.

## 30. 2026-07-02: расследование потолка одной цепочки (чистые сиды)

Методика: single stream (range off, pool=1, ack_pool=1), debug-summary 1s,
A/B по направлениям (телефон-отправитель "p2d" и десктоп-отправитель "d2p"),
затем изоляция слоёв.

### Слой за слоем

1. **Не сеть.** Сырой TCP: Mac -> сид 12-14 MB/s (ssh /dev/zero);
   телефон <- сид 8-10.5 MB/s (curl HTTP c сида по Wi-Fi).路 из 2 хопов
   через сиды при этом давал 1.4-2.5 MB/s.
2. **Не потери и не окно в классическом смысле.** Driver summary на чистом
   прогоне: sack=0 resend=0 consec_rto=0 весь трансфер; cwnd растёт до 16 MiB
   (slow start не выходит); inflight упирается в rwnd=4 MiB; srtt стабильно
   ~2.2-2.4s при rttvar<100ms — это СТОЯЧАЯ ОЧЕРЕДЬ перед фиксированным
   узким местом (throughput = inflight/srtt точно сходится).
3. **Пейсер #1 (shared DATA pacer, 50µs/клетку на получателя).** Найден и
   исправлен баг: при пересыпе tokio::sleep (Android коалесцирует 1ms до
   ~4ms) расписание сбрасывалось к now и неиспользованный кредит СГОРАЛ —
   реальная скорость = 20 клеток / фактический сон вместо номинала
   (телефон ~4.6k cells/s = 1.45 MB/s, Mac ~8k = 2.5 MB/s — оба совпали с
   измеренным). Фикс: token bucket с burst-кредитом (64 интервала / >=5ms),
   расписанию разрешено отставать от now. Инверсное масштабирование
   подтверждено экспериментом pace=200µs: 2.50 -> 0.83 MiB/s.
4. **Пейсер #2 (движок, batch/tick).** pace_params() выдаёт budget на 1ms
   тик, но на Android реальный wake ~12.5ms -> 64 клетки/wake = 1.63 MB/s.
   Подтверждено: batch=256 (новая ручка) поднял p2d 1.61 -> 2.19.
   Добавлены env+Android-prop ручки: VEIL_ONION_STREAM_CIRCUIT_MAX_PACING_BATCH
   / debug.veil.onion_stream_max_pacing_batch (кап 512),
   VEIL_ONION_STREAM_CIRCUIT_DATA_PACE_US / debug.veil.onion_stream_data_pace_us
   (MIN_DATA_PACE_US 50 -> 10), + SOAK_* прокидка.
5. **Debug vs release native.** Обнаружена асимметрия стенда: Android .so
   собирается gradle'ом ВСЕГДА в release, а desktop dylib гонялся в debug.
   Release-десктоп поднял p2d 2.19 -> 2.80 (приёмная сторона); d2p не
   изменился (~2.3-2.4). Soak теперь по умолчанию SOAK_NATIVE_PROFILE=release
   (build-native.sh --release + production-seeds; debug остаётся опцией).
6. **Не сиды.** CPU-сэмплы в активной фазе: veil-cli на всех трёх сидах
   0-27% одного ядра, чаще 0%.
7. **Терминальный биндер: per-cell цена на ТЕЛЕФОНЕ.** Приложение ест
   130-160% CPU при single-chain 2.1 MB/s; per-thread профиль — БЕЗ одного
   забитого потока: 2-3 tokio-worker по 25-43%, 3 veil-ffi по 18-36%, Dart
   7-18%; system-wide sys=239% > user=136%. Т.е. доминируют
   сисколлы/wakeup'ы/переключения на каждую 384B клетку (7-9k cells/s),
   размазанные по потокам, а не крипта и не один цикл.

### Итоговая карта потолков (после всех фиксов)

| режим | скорость | биндер |
| --- | ---: | --- |
| single p2d (phone TX) | 2.13-2.80 MiB/s | per-cell CPU/sys на телефоне |
| single d2p (phone RX) | 2.26-2.50 MiB/s | per-cell CPU/sys на телефоне |
| shared pacer номинал | 6.06 MiB/s | 50µs/cell (теперь честный после token-bucket фикса; MIN опущен до 10µs) |
| p8 parallel | 1.5-3.2 MiB/s | телефон целиком (~11-12k cells/s) + шум маршрутов |

### Следующие уровни (за рамками этой сессии)

- Session-write батчинг конец-в-конец: слать НЕСКОЛЬКО готовых клеток одним
  writer-вызовом/одним TCP-сегментом (velocity: sys-время ~ на число
  вызовов, не байтов). Это главный кандидат снять телефонный потолок.
- Протокольный размер клетки (384B фиксирован форматом circuit cell) —
  анонимность/совместимость, отдельная миграция.
- BBR-шейпинг вместо 2x slow-start overdrive убрал бы стоячую 4MiB очередь
  (srtt 2.3s -> ~0.3s) — на throughput не влияет, но резко улучшит
  латентность конкурентного трафика и время реакции failover.

### Финальные контрольные прогоны после всех правок §30

Дефолты после сессии: engine max_pacing_batch (circuit) 64 -> 256,
token-bucket пейсер, стенд на release native (SOAK_NATIVE_PROFILE=release),
Android batch prop default 256.

| run | active MiB/s | notes |
| --- | ---: | --- |
| p8-final1 64 MiB (release build + batch256) | 2.133 | fault none, gate pass |
| p8-final2 64 MiB (повтор без rebuild) | 1.600 | fault none, gate pass |
| default-final 64 MiB (все новые дефолты, rebuild) | **3.200** | fault none, CMP-OK, gate pass |

Single-chain поднят с 1.455 до 2.13-2.80 MiB/s; parallel держит 1.6-3.2 при
цели 1.5. Терминальный биндер обеих цифр — per-cell sys-overhead телефона
(~2x sys vs user CPU при 7-9k cells/s); главный следующий шаг — батчинг
session-write (несколько клеток за один вызов/TCP-сегмент).

## 31. 2026-07-02: батчинг TX-пути — снятие per-cell потолка телефона

Реализация (продолжение §30, «следующий уровень»):

- `veil-onion-stream::CellDuplex::send_cells` / `CellSender::send_many` —
  батч-API с дефолтной поклеточной реализацией (sim/datagram пути не меняются).
- Драйвер собирает ВСЮ эмиссию движка за проход (`poll_transmit` до сухого,
  кап 512) в FIFO `outbound` и отдаёт carrier'у одним вызовом; WouldBlock
  оставляет непринятый хвост в очереди (та же ARQ-семантика, что старый
  одиночный blocked_cell, но пачкой).
- Hub (`CircuitCells::send_many` + `send_data_run`): ран однотипных DATA-клеток
  одного stream'а обслуживается ОДНИМ resolve маршрута + staleness-проверкой +
  pacer-резервом (`StreamDataPacer::wait_n` — один лок и один сон на ран) +
  одним bookkeeping-проходом. Скалярный путь (SYN/ACK/FIN/RST/интро) не
  тронут. До этого каждая 318B клетка платила 3-4 async-лока — при 7-9k
  cells/s это и был sys-доминированный потолок из §30.

Проверки: cargo test veil-onion-stream 40 green; veilclient-ffi lib 56 green;
flutter 429 green; все device-прогоны CMP-OK.

Замеры (⚠️ в §30/§31 ранние «6.400» от summary — артефакт 10s-гранулярности
монитора; здесь точные времена из hook-лога):

| конфиг | до батчинга | после |
| --- | ---: | ---: |
| single 16 MiB p2d | 2.13-2.80 | **3.82** (4.19s) |
| single 16 MiB d2p | 2.26-2.50 | **3.76** (4.25s) |
| single-long 64 MiB | 2.1 | **3.60** (17.8s) |
| range p8/1MiB 64 MiB | ~2.1 | 2.07-2.13 (range-накладные) |
| range p4/8MiB 64 MiB | — | **3.44** (18.6s) |

Range-режим с 1 MiB кусками перестал быть быстрым путём (64 manifest-раундов
на 64 MiB); крупные куски вернули его на уровень single-long при сохранении
resume/hedge/verify. Пейсер больше не биндер: 25µs не ускорил (2.86), потолок
теперь ~11-12k cells/s per-cell пути телефона (RX-сторона + остаточный TX).

Дефолты изменены (Dart): `_defaultStreamRangeParallelism` 8 -> 4,
`_defaultStreamRangeTargetBytes` 1 MiB -> 8 MiB, cap 2 -> 16 MiB.

Валидация новых дефолтов:

| run | результат |
| --- | --- |
| 64 MiB default | **3.56 MiB/s** (17.99s hook), CMP-OK, gate pass |
| 256 MiB long default | active 3.160, hook 138s (~1.86 сквозняком), fault none, CMP-OK |

Динамика за сессию (single-chain, 64 MiB класс): 1.28-1.46 -> 3.4-3.8 MiB/s
(~x2.5); длинный 256 MiB: active 1.571 -> 3.160.

Остаток потолка: per-cell обработка приёмной стороны (session RX decrypt ->
dispatcher -> mux inbox -> driver по одной клетке) — зеркальный батчинг RX;
затем протокольный размер клетки.

## 32. 2026-07-02: RX-батчинг — реализован, нейтрален в текущем шуме, оставлен

Зеркало §31 для приёмного пути (veil 5a9f3ff):

- `CellDuplex::recv_cells` — >=1 клетка + drain до 256 буферизованных за вызов
  (tokio `recv_many`, cancel-safe); драйвер обрабатывает burst за ОДИН оборот
  цикла (одна ACK/transmit-фаза и один reader-handoff на пачку вместо полного
  оборота на клетку). Дефолт — поклеточный (симы не тронуты).
- Demux `StreamMux`: recv_many + маршрутизация всей пачки под ОДНИМ
  routes-lock; SYN (новые streams) — по прежнему поклеточному пути. Порядок
  не меняется: в handshake DATA не предшествует SYN_ACK.
- FFI circuit feed: recv_many + один activity-mark на пачку.

Замеры и честный вердикт: во время замеров стенд стал бимодальным
(~7s либо ~13s на 16 MiB single НЕЗАВИСИМО от сборки — A/B со stash'ем
подтвердил: tx-only 6.94/13.24s vs rx-batch 7.06/13.42s). Один из трёх
маршрутов флапает в этот час; pool=1 иногда попадает на него. RX-батчинг
скорость не меняет в пределах этого шума — оставлен ради сокращения
wake/lock (важно для батареи/фоновой работы и как база для дальнейшего).
Корректность: 40 rust + 56 ffi green, все device-прогоны CMP-OK.

Финальная валидация полного билда (default p4/8MiB): 64 MiB за 24.4s
(~2.6 MiB/s в шумном окне), gate pass, fault none, CMP-OK.

Сводка сессии «потолок одной цепочки» (тихое окно стенда):
1.28-1.46 (утро, до всего) → 3.4-3.8 MiB/s single / 3.16 active на 256 MiB.
Оставшиеся направления: протокольный размер клетки (384B, анонимити-tradeoff),
BBR-шейпинг (латентность, не throughput), и починка/учёт флапающего маршрута
на стенде (bimodality ~7s/~13s при pool=1).
