# Автоматическая нейтральная release-сборка — 2026-11-12

Продолжение [macOS native privacy проверки](../macos-native-source-privacy-2026-11-12/README.md).
Инструменты подготовки подключены к обычному `builder.py`.

## Изменение сборочного пути

| Этап | Поведение |
|---|---|
| Нативные producers | Выполняются в исходном checkout, как прежде |
| Подготовка | Новая защищённая физическая workspace; копируются source/platform/assets и только library outputs из Cargo targets, без их кешей |
| Dart packages | Locked pub setup, затем neutral package roots; Flutter получает `--no-pub` |
| Дочерний builder | Повторяет проверки/стадирование inputs, выполняет Flutter и оставшуюся упаковку; producer-команды не дублируются |
| Метаданные | Native version labels передаются от исходного checkout через marker; отсутствие `.git` в копии не заменяет их на `?` |
| Готовый артефакт | Обязательный scan домашних source URI и пути текущего сборщика, включая UTF-16 |
| Экспорт | Проверяются также скопированные байты и переносимость links; прежний каталог заменяется только после успеха |
| Диагностика и очистка | Внешние Apple dSYM сохраняются отдельно в защищённом `build/private-symbols/`; временные sources/Cargo targets удаляются |

Путь включён для всех пяти release targets. Debug собирается на прежнем месте.
Ad-hoc macOS config также получает `--no-pub` и исходные native versions.
Это не бинарная замена строк и не обфускация. Нативные compiler prefix maps и
source/provenance проверки media остаются необходимыми.

Child marker проверяет собственный source path и принадлежность отдельного
Cargo target этой workspace. Старый SDK target и shared cache не становятся
рабочим target новой копии. Настроенный producer target имеет приоритет перед
обычным fallback; отсутствие настройки/пустое значение используют fallback.
Directory aliases распознаются и на Python до появления `Path.is_junction`;
для SHA используется чтение блоками без нового требования `hashlib.file_digest`.

## Проверки границ

Одиннадцать orchestration/plan tests прошли на macOS и Windows 11 без skips.
Это управляемые tests оркестрации, не замена настоящей Flutter-сборки:

- Ошибка child, домашний URI и native home path не заменяют прежний артефакт.
- Отказ финального rename восстанавливает прежний каталог и удаляет partial.
- Absolute link в старую workspace не экспортируется как будущий broken link.
- Изменение staged source не меняет оригинал; временная workspace удаляется.
- Переносятся library outputs, а не содержимое Cargo cache; explicit target
  выигрывает у старого fallback.
- Native labels сохраняются без Git; dSYM отделены от публикуемого приложения.
- Все release branches, включая signed/unsigned Apple paths, сохраняют final
  privacy gate и `--no-pub`; debug dispatch не меняется.

Workspace/package-root/checker regressions также включены в release `checks`,
а builder и настоящая Windows compiler-проверка — в Windows CI job.
Новые CI jobs удалённо не запускались в этом цикле.

## Дополнительный подтверждённый дефект Windows compiler flags

FFI producer использовал clang-cl remap, но Flutter step — GNU spelling флага.
Последний также запускает native VPN helper. Исправлено использованием MSVC
driver environment и в этом шаге.

Проверка настоящим clang-cl компилирует узкий и широкий `__FILE__` из каталога
под home, с пробелом в пути. Правильные caller flags намеренно очищены при
создании env, чтобы не скрывать дефект. На baseline `72aa04d2` FFI-контроль
проходит, **Flutter subtest даёт один assertion-failure**, errors/skips — 0.
После правки три метода / оба compiler paths прошли на Windows без skips.
На macOS Windows compiler method отдельно считается skipped.

## Настоящая Windows release-сборка

Первый end-to-end запуск новой оркестрации собрал обычный `--release` через
настоящий staged `builder.py`: pub, remap, Flutter/CMake/MSBuild, VPN helper,
проверки и упаковка. Входы — отдельная QA-копия с актуальным Dart frontend и
SDK source; исходные проверенные SDK/HV/media inputs подготовлены заранее.
Первоначальные native producer-команды родителя в этом опыте не повторялись.

Результат за **277,43 с**: **41 член / 86 379 397 байт**, домашних URI **0**,
пути текущего сборщика **0**. SDK FFI, hidden-volume, media и Wintun сохранили
байты проверенных inputs. VPN helper собран заново в отдельном Cargo target;
равенство всех DLL прежней profile-сборке не заявляется. Обычный release в
этой серии не запускался и не устанавливался пользователю.

Второй проход на текущих helpers с QA compile flags завершился за **257,13 с**
и также прошёл artifact scan. Автоматическое открытие контейнера через soak hook
для release не подходит: `_hookBuildAllowed` намеренно исключает этот режим.
Ослабления этого ограничения не добавлялись; открытие контейнера не засчитано.

## Пойманная регрессия экспортера: Windows ACL

Попытка запуска через задачу с обычным токеном выявила отказ ещё при проверке
EXE. У опубликованного каталога отсутствовал ACE текущего user SID; доступ
получала только группа Administrators. Это произошло с mode-0700 temporary
directory, созданной из elevated Python. Исходный profile-каталог и его parents
сохраняли user ACE. Задача закончилась до появления отслеживаемого PID.

Экспортер теперь явно задаёт user-SID ACL Windows-каталогу перед публикацией.
После применения того же исправления задача с limited token запустила процесс:
53,3 с alive/responding. GUI-окно не подтверждено, контейнер не разблокирован.
Этот результат не объявляется проверкой интерфейса или звонков.

Текущий `_publish_directory` затем повторно экспортировал сохранённый обычный
release-комплект. Отдельная interactive task с **AdminToken=false** прочитала
EXE и AOT с ожидаемым SHA. Повторный privacy scan сохранил нули. В положительный
Windows regression test добавлена проверка user ACE каталога **и** вложенного
файла; все 11 builder tests и 5 workspace tests прошли без skips.

Собственный процесс/задачи, холодная копия и профиль удалены. Исходные QA inputs,
canonical frontend и его native artifacts прошли прежнюю SHA-проверку.
В отдельном build-каталоге восстановлен обычный release; изменённые QA proofs
не используются как описание текущего артефакта. Два build-прохода здесь не
означают два пройденных runtime-сценария.

Полное прохождение нового пути на Android/Linux/Apple ещё не заявляется:
прежние нейтральные QA-сборки этих платформ не использовали весь новый builder.
Источник Windows 10 жалобы на исходящие звук/камеру и аватары этим не закрыт.

## Релизный остаток

Нужны финальная квалификация остальных platform jobs и обновление семи media
pins. Пока они устарели, source-digest guard должен блокировать их использование.
Работа не отменяет порядок выпуска зависимостей перед приложением.
Ничего не пушилось и не публиковалось. Приватные inputs, аккаунты, адреса,
ключи, журналы, реальные совпавшие пути и бинарники в Git не включены.
