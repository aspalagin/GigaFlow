# Внешние компоненты

GigaFlow использует перечисленные ниже проекты. Зависимости устанавливаются отдельно, веса модели скачиваются при настройке среды. Их исходники и веса не включены в этот репозиторий.

| Компонент | Использование | Лицензия и источник |
| --- | --- | --- |
| GigaAM, Salute Developers | Исходная модель распознавания речи | [MIT](https://github.com/salute-developers/GigaAM/blob/main/LICENSE), [проект](https://github.com/salute-developers/GigaAM) |
| gigaam-mlx, aystream | Реализация GigaAM для MLX | [MIT](https://github.com/aystream/gigaam-mlx/blob/20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac/LICENSE), [исходники закреплённой версии](https://github.com/aystream/gigaam-mlx/tree/20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac) |
| GigaAM-v3-e2e-rnnt-mlx, aystream | Веса и токенизатор RNNT | [Карточка модели с лицензией MIT](https://huggingface.co/aystream/GigaAM-v3-e2e-rnnt-mlx) |
| MLX, Apple | Вычисления на Apple Silicon | [MIT](https://github.com/ml-explore/mlx/blob/main/LICENSE), [проект](https://github.com/ml-explore/mlx) |
| Hammerspoon | Необязательная привязка кнопки мыши | [MIT](https://github.com/Hammerspoon/hammerspoon/blob/master/LICENSE), [проект](https://www.hammerspoon.org/) |

Для воспроизводимости закреплены:

- `gigaam-mlx`: commit `20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac`.
- `aystream/GigaAM-v3-e2e-rnnt-mlx`: revision `decfca492069ea30fb5ead79c4516d50c16d93ea`.
- Python-зависимости: версии в [requirements.lock.txt](requirements.lock.txt). Каждая зависимость сохраняет собственную лицензию; приведённая таблица не заменяет полный список лицензий установленной среды.

GigaFlow — независимый проект; он не связан с Wispr Flow и не включает его код или графические материалы. Превью капсулы получены из собственного интерфейса GigaFlow.
