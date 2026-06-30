# Onion byte-stream throughput — итог оптимизации

Дата стенда: 2026-06-30.

## Результат

- Исходно: около 135 КБ/с.
- Финальная конфигурация одной pinned anonymous circuit:
  - MSS: 318 Б;
  - receive window: 896 КБ;
  - pacing batch: 24 сегмента;
  - cumulative ACK: каждые 32 DATA, но не позднее 5 мс;
  - gap/duplicate/FIN ACK отправляются немедленно;
  - congestion growth считает подтверждённые байты, а не ACK-пакеты.
- 37,158,021 Б:
  - steady: 2.80–3.01 МБ/с;
  - примерно 13.8 с от `stream-serve` до готового файла;
  - zero resend / RTO / relay drops.
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
6. Pinned circuit жил дольше relay idle TTL и становился stale. Добавлен
   подтверждённый refresh каждые 120 с с grace-периодом старой цепочки.
7. Recreated hub использовал случайный registration key для прежнего cookie;
   relay first-registration-wins блокировал новую цепочку. Registration key
   теперь стабильно выводится из identity key; cookie переведён на v2 domain.

## Проверенные границы

- 1 МБ receive window: throughput не вырос, RTT прыгал до 445 мс — лишняя
  очередь. Финальный выбор: 896 КБ.
- Batch=16 давал почти точный timer ceiling:
  `16 × 318 Б / ~2 мс ≈ 2.54 МБ/с`.
- Batch=24 поднял steady примерно до 2.8–3.0 МБ/с без потерь.
- Relay и клиенты не упираются в CPU; drop counters остаются нулевыми.

## Изменённые компоненты

- `veil-session`: очереди, encrypted batching и безопасный writer admission.
- `veil-onion-stream`: pacing batches, delayed/cumulative ACK, byte-counted
  congestion growth, RTT diagnostics.
- `veil-node-runtime`: stable onion-stream registration key.
- `veilclient-ffi`: exact circuit MSS, circuit refresh/lifecycle и tuned config.

Все 27 тестов `veil-onion-stream` и 235 тестов `veil-session` проходили после
основных изменений; финальные numeric tuning changes также успешно собраны для
macOS и Android.
