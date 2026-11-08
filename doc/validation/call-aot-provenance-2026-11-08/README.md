# Коррекция происхождения Dart в Mac-стенде

**Ошибка стенда подтверждена.** Подмена kernel_blob.bin не обновляла
выполняемый Mac Dart. Использованный bundle работал с profile AOT, загружал
`App.framework/Versions/A/App` с `_kDart*Snapshot*` symbols. В actual process
mapping присутствовал этот AOT image. Его SHA одинаков в повторных копиях;
новые receipt strings отсутствуют в AOT и присутствуют только в неиспользуемом
свежем kernel. Compile-time QA marker AOT — прежний `qa-resume-20261106`.
UUID arm64 FlutterMacOS engine совпадает с текущим official profile cache,
а не release cache. Это ошибка проверки выбранного Dart artifact.

## Границы коррекции

Отозваны утверждения о текущем Mac Dart/JIT в [b599 series](../call-route-physical-2026-11-08/README.md)
и [c567 series](../call-fast-ack-physical-2026-11-08/README.md). Их packet/native
observations относятся к старому Mac profile AOT с выбранной квалифицированной
FFI, а Android AOT обновлялся. Поведение пары не доказывает отказ fast ACK в
двух обновлённых клиентах. Последний Mac-only diagnostic kernel тоже не
выполнялся, поэтому отсутствие decision codes не было отказом receipt gate.

Нативные библиотеки отдельно проверялись по SHA и actual mapping; их
происхождение этим не опровергнуто. Unit/standalone Dart tests этой ошибки
bundle не имеют. Прежние сетевые измерения сохраняются как измерения реально
запущенной смешанной пары, с исправленной областью применимости; причинный
эффект новых Mac app-правок по ним не заявляется. Старому AOT не назначен
исходный commit только по строке версии.

## Предотвращение повторения

Authenticated `/health` теперь сообщает compile-time identity **активной**
Dart программы: version, source revision, lib source digest, mode, diagnostics
flag. Это debug-hook-only metadata, не данные контейнера или окружения.
Драйвер обязан сравнить с compiler inputs до unlock/call; missing или stale
identity — отказ qualification. Для profile engine нужно обновлять весь
profile `App.framework` и проверять mapping его `App`, а не kernel рядом.

21 hook/auth/parameter tests прошли, analyzer чист. Runtime проверка нового
profile AOT — следующий шаг; текущие trace-kernel данные не зачтены.
Оба test Cores/collectors/apps остановлены, production/телефон восстановлены.
Push/релиза нет.
