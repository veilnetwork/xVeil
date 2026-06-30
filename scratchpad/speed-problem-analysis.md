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
