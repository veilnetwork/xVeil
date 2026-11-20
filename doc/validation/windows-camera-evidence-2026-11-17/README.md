# Native camera evidence in structured diagnostics

The structured report previously retained camera-start success, a running flag
and Dart preview counters. Those observations could not distinguish a reader
waiting for its first sample from samples refused during conversion, or retain
the native reason after a failed source object was released. The original
Windows 10 report remains unattributed; this change prepares data collection.

## Retained evidence

The one-to-one native engine now exports a numeric capture snapshot. The MF
capturer protects it with a short mutex; no device I/O or callback runs under
that mutex. Counters reset on a new capture attempt. After stopping or releasing
a failed source, the engine retains the last snapshot until another attempt.
Other camera backends return unavailable evidence by default, not a failure.

| Field | Meaning |
| --- | --- |
| `camera_capture_status` | MF stage/termination category; -1 unavailable, 1 opening, 2 reading, 3 explicit stop, 4 unavailable source, 5 reader creation failure, 6 unusable format, 7 failed read, 8 terminal reader flag, 9 EOF, 10 failed format-change recovery; 0 reserved for idle |
| `camera_capture_hresult` | Unsigned 32-bit method result where retained, otherwise -1; the terminal reader flag can accompany HRESULT 0 |
| `camera_capture_reads` | Completed `ReadSample` calls, including null/error/terminal results; not reads currently blocked in the driver |
| `camera_capture_samples` | Samples admitted past terminal/type-change guards, including intentional pacing skips |
| `camera_capture_frames` | Frames handed to the camera callback; not proof of encoding, transport or rendering |
| `camera_capture_dropped` | Buffer/conversion refusals; intentional pacing skips are excluded |

The app retains these fields at camera start, observed capture termination and
periodic media sampling. A failed start keeps its evidence before the periodic
timer can run. Snapshot collection at start is disabled with diagnostics.
HRESULT is currently retained for COM/reader creation, failed reads and terminal
flags; activation/format failures can still carry unknown -1.

The journal accepts only integers in explicit ranges (status -1..10, HRESULT
-1..4294967295, counters 0..1000000000). Unknown fields, strings, driver text,
device IDs, paths, pictures and native timestamps are omitted. No capture,
negotiation, route, automatic restart or preference policy is changed.

## Qualification

- **17 native checks pass, zero skips:** source-reader terminal/error evidence,
  conversion refusal with no claimed successful frames, explicit-stop evidence,
  and all existing format/recovery controls. Real MF objects back the controlled
  reader. Conversion stand-ins count/refuse calls; they do not simulate pixels.
- **385 Flutter tests pass with diagnostics, and 385 with diagnostics disabled,**
  across six suites. They cover startup refusal, capture-end propagation through
  the real application controller/service, consent/posture, legacy snapshots,
  invalid/private values, retention after ring eviction and the disabled path.
- **One AOT artifact test passes** for both build flags: it executes compiled
  production journal code, checks exported fields and private canaries, and
  checks the artifact instrumentation gate. `dart analyze lib test` is clean.
- A fresh **full Windows x64 DLL**, ten translation units, was built from 79
  frozen/hash-checked producer inputs with the existing pinned WebRTC SDK.
  Source digest, binary provenance, SDK-library hash and non-header compiler
  flags match. The PE guard accepts all 107 required/optional-policy lookups;
  the binary passes the private-data artifact check.
- Two physical Windows 11 component cases pass: 352×198/15/150 and
  640×360/60/900 (requested width/height/FPS/kbps). Local/decoded polling updates
  before and after recovery are 10/10 and 10/10 for the first case, 11/10 and
  11/10 for the second. Requested FPS is not a measured camera rate.

The physical probe checks reading status with positive capture counters, retains
explicit-stop evidence, then selects a deliberately nonexistent camera. That
failed attempt retains source-unavailable status after releasing the capturer,
has zero fresh counters and an unknown HRESULT. A subsequent default-camera
start delivers fresh local and decoded progress. No real device is disabled or
reconfigured. The synthetic callback transport never enters an application.

```powershell
python test/native/windows_camera_dll_probe.py --media-dll <verified-DLL> --transport-shim <owned-shim-DLL> --use-physical-camera --expect-capture-diagnostics
```

The optional diagnostic flag keeps the probe usable for earlier DLLs. Without
it, its original camera/codec controls do not qualify the new evidence fields.
Help and refusal on a non-Windows host are also checked before native loading.

This is source/metadata and native component qualification: no GUI application,
ordinary signaling, real network call, audible audio, installed AOT package or
original Windows 10 hardware is qualified. Physical tests start no audio, retain
no images and use no user profile. No windows are launched or focused and no
input is injected; the user's existing app stays running.

Both Windows supervisors and their children exit. All 79 inputs, the binary and
SDK library are verified again before removing the owned Windows SDK, source,
compiler and probe directories. One small verified DLL/provenance pair remains
locally; the pre-existing SDK archive is unchanged. Nothing is installed,
pushed or released. New immutable engine pins and final packages remain needed.

## Коды отказа открытия и формата

В Veil `0dc13e14` зафиксирован числовой HRESULT при отказе инициализации
Media Foundation, перечисления или открытия источника, чтения либо проверки
выходного формата. Выбор отсутствующего устройства получает `MF_E_NOT_FOUND`.
Неподдерживаемый или некорректный формат получает `MF_E_INVALIDMEDIATYPE`.
Если запрос нового формата отклонён, но текущий формат читается и пригоден,
захват продолжается. Имена устройств и текст ошибок в отчёт не добавлены.

Контрольная Windows 11 сборка без правки дала три отказа в проверках
диагностики. Это отсутствующий источник, неподдерживаемый формат при смене
режима и ошибка чтения нового формата. На исправлении прошли все 29
нативных проверок и 786 связанных Flutter-тестов с включённой диагностикой.
Пересобранный DLL проверен по 81 исходному входу, SHA библиотеки WebRTC
и таблице 107 экспортов. На физической камере Windows 11 оба профиля
получили свежие кадры и декодировали их до и после отказа отсутствующего
источника. В обоих случаях выходной код сохранился после закрытия
захвата. Медиа не записывались.

Локальный архив `xveil-windows-x64-0.13.104-camera-0dc13e14.zip` содержит
новый `veil_media.dll` и прежний диагностический код запуска из
`0b858dc5`. Сверены SHA-256 архива, его содержимое и отсутствие путей
из домашних каталогов. Физическая проверка относится к DLL с тестовым
транспортом. Полный архив и камера пользователя на Windows 10 ещё
не проверены.
