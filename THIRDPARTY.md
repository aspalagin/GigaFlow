# Внешние компоненты

Исходный репозиторий GigaFlow не содержит веса модели или установленную Python-среду. Готовый **DMG содержит Python, библиотеки и модель**, чтобы приложение работало без настройки среды и загрузки дополнительных файлов после установки.

| Компонент | Использование | Лицензия и источник |
| --- | --- | --- |
| CPython 3.11 | Встроенный интерпретатор | [Лицензия Python](https://docs.python.org/3.11/license.html), исходный `LICENSE.txt` включён в runtime |
| python-build-standalone | Переносимая сборка CPython и её системные библиотеки | [Релиз 20261026](https://github.com/astral-sh/python-build-standalone/releases/tag/20261026); оригинальные уведомления о лицензиях сохранены отдельно для каждого компонента |
| GigaAM, Salute Developers | Исходная модель распознавания речи | [MIT](https://github.com/salute-developers/GigaAM/blob/main/LICENSE), [проект](https://github.com/salute-developers/GigaAM) |
| gigaam-mlx, aystream | Реализация GigaAM для MLX | [MIT](https://github.com/aystream/gigaam-mlx/blob/20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac/LICENSE), [исходники закреплённой версии](https://github.com/aystream/gigaam-mlx/tree/20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac) |
| GigaAM-v3-e2e-rnnt-mlx, aystream | Веса и токенизатор RNNT | [Карточка закреплённой модели](https://huggingface.co/aystream/GigaAM-v3-e2e-rnnt-mlx/tree/decfca492069ea30fb5ead79c4516d50c16d93ea), лицензия MIT GigaAM включена рядом с моделью |
| MLX, Apple | Вычисления на Apple Silicon | [MIT](https://github.com/ml-explore/mlx/blob/main/LICENSE), [проект](https://github.com/ml-explore/mlx) |
| Hammerspoon | Необязательная привязка кнопки мыши; само приложение Hammerspoon не входит в DMG | [MIT](https://github.com/Hammerspoon/hammerspoon/blob/master/LICENSE), [проект](https://www.hammerspoon.org/) |

## Уведомления о лицензиях в готовом приложении

В `GigaFlow.app/Contents/Resources/Runtime` сохранены:

- `Licenses/CPython-LICENSE.txt` — оригинальная лицензия CPython.
- `Licenses/PythonBuildStandalone/` — оригинальные лицензии компонентов переносимой сборки Python и `SOURCE.json` с источником и SHA256 её архива.
- `Licenses/GigaAM-MIT.txt` и `models/gigaam-v3-e2e-rnnt-mlx/LICENSE` — лицензия GigaAM.
- `python/lib/python3.11/site-packages/` — исходные уведомления и файлы лицензий установленных пакетов, включая их `*.dist-info/METADATA`.
- `runtime-manifest.json` — версии Python и пакетов, ревизия модели, сведения о нативных библиотеках и контрольные суммы файлов модели.

Пакеты имеют собственные лицензии; таблица выше не заменяет их полный список. Уведомления, необходимые сборщику runtime, находятся в [scripts/runtime-licenses](scripts/runtime-licenses). Некоторые уведомления python-build-standalone относятся к дополнительным компонентам upstream-сборки, независимо от того, использует ли их GigaFlow.

Для воспроизводимости закреплены:

- CPython `3.11.18`, python-build-standalone `20261026`, `aarch64-apple-darwin`.
- `gigaam-mlx`: commit `20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac`.
- `aystream/GigaAM-v3-e2e-rnnt-mlx`: revision `decfca492069ea30fb5ead79c4516d50c16d93ea`.
- Python-зависимости: версии в [requirements.lock.txt](requirements.lock.txt). Каждая зависимость сохраняет собственную лицензию; приведённая таблица не заменяет полный список лицензий установленной среды.

GigaFlow — независимый проект; он не связан с Wispr Flow и не включает его код или графические материалы. Превью капсулы получены из собственного интерфейса GigaFlow. Этот документ описывает внешние компоненты и не назначает лицензию собственному коду GigaFlow.
