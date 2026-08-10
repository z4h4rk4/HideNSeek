# HideNSeek

HideNSeek - Roblox-проект для игры в прятки, синхронизируемый через Rojo.
Текущая версия проекта делает основной упор на короткие раунды с ботом-Seeker,
Hider-игроками и NPC, экономикой Coins, визуальными следами Hider и тестовой
админ-панелью для быстрой настройки во время разработки.

## Быстрый старт

Установить инструменты из `aftman.toml`:

```powershell
aftman install
```

Установить Wally-зависимости. Сейчас `wally.toml` не содержит пакетов, но
команда оставлена как стандартный шаг для проекта:

```powershell
wally install
```

Один раз установить совместимый плагин Rojo в Roblox Studio:

```powershell
rojo plugin install
```

Запустить Rojo-сервер:

```powershell
rojo serve default.project.json
```

В Roblox Studio открыть плагин Rojo и подключиться к:

```text
127.0.0.1:34872
```

## Команды

```powershell
# Запустить live-синхронизацию со Studio
rojo serve default.project.json

# Собрать place-файл без запуска Studio
rojo build default.project.json --output build/HideNSeek.rbxlx

# Установить зависимости из wally.toml
wally install

# Проверить Luau-код
selene src

# Проверить форматирование
stylua --check src

# Отформатировать код
stylua src
```

Важно: `aftman.toml` сейчас закрепляет только Rojo `7.7.0`. Если `selene` или
`stylua` не найдены в терминале, их нужно установить отдельно или добавить в
`aftman.toml`.

## Структура Rojo

Актуальная карта проекта находится в `default.project.json`.

| Путь в репозитории | Roblox-сервис |
| --- | --- |
| `src/ReplicatedStorage` | `ReplicatedStorage` |
| `src/ServerScriptService` | `ServerScriptService` |
| `src/StarterPlayerScripts` | `StarterPlayer/StarterPlayerScripts` |
| `src/Workspace` | `Workspace` |
| без `$path` | `ServerStorage` |

Для подключённых сервисов включён `$ignoreUnknownInstances`. Это значит, что
объекты, созданные вручную в Studio, не удаляются во время live-синхронизации.
Особенно важно для карты, шаблонов в `ServerStorage`, звуков в `SoundService`
и `StarterPlayer.StarterCharacter`.

Папки `src/ReplicatedFirst`, `src/StarterGui`, `src/StarterCharacterScripts` и
`src/ServerStorage` сейчас не подключены в `default.project.json`. Если туда
будут добавлены исходники, нужно отдельно обновить Rojo-карту.

## Что должно быть в Studio

Эти объекты не создаются полностью из текущего репозитория, но нужны игре:

| Объект | Где находится | Назначение |
| --- | --- | --- |
| `HUB/SpawnHUB` | `Workspace` | Хаб и точка появления зрителей |
| `SpawnArena` | внутри каждой арены | Точка распределения участников раунда |
| `Map/Floor` | внутри каждой арены | Плоская навигационная геометрия пола |
| `Map/Walls` | внутри каждой арены | Стены для навигации, видимости и поиска |
| `StarterCharacter` | `StarterPlayer` | Шаблон для NPC Hider |
| `HunterCharacter` | `ServerStorage` | Шаблон для NPC Seeker (хантера) |
| `BatModel` | `ServerStorage` | Первый ручной Tool с `Handle.Attachment` |
| `CageModel` | `ServerStorage` | Второй ручной Tool: при попадании помещает Hider в клетку |
| `TrashCan` | `ServerStorage` | Третий Tool: выпускает `Effect` и оглушает игроков в секторе |
| `Coin` | `ServerStorage` | Шаблон монеты |
| `GoldBar` | `ServerStorage` | Шаблон золотого слитка |
| `cage` | `ServerStorage` | Модель клетки для пойманного Hider |
| `Smokes/smoke-01` | `ServerStorage` | Шаблон случайного дыма |
| `Smokes/fart` | `ServerStorage` | Шаблон эффекта бездействия |
| `Leaks/LeaksVFX` | `ServerStorage` | VFX для мокрых следов |
| `Leaks/Left`, `Leaks/Right` | `ServerStorage` | Декали или модели следов ног |
| `GoldSound` | `SoundService` | Звук подбора валюты |
| `TeleportSound` | `SoundService` | Звук телепорта |
| `FartSound` | `SoundService` | Пространственный звук эффекта бездействия |
| `HunterAggroSound` | `SoundService` (необязательно) | Свой пространственный звук обнаружения; без него используется встроенный короткий сигнал |

Для чистой сборки через `rojo build` Studio-only ассеты нужно либо держать в
place-файле, либо экспортировать и добавить в Rojo-карту. Live-синхронизация их
сохраняет благодаря `$ignoreUnknownInstances`.

## Настройка арены

Каждая арена должна содержать одну часть `SpawnArena`. Сервер выбирает одну
доступную арену перед стартом раунда, стараясь не повторять предыдущую арену,
если есть выбор.

Внутри арены нужен контейнер `Map` с двумя дочерними объектами:

| Имя | Тип | Требования |
| --- | --- | --- |
| `Floor` | `Folder`, `Model` или `BasePart` | Содержит плоские `BasePart`, по которым строится навигация |
| `Walls` | `Folder`, `Model` или `BasePart` | Содержит препятствия; учитываются даже при `CanCollide = false` |

Навигация NPC строится из прямоугольников `Map/Floor` и `Map/Walls`.
Наклонённые части отбрасываются: у пола и стен должен быть почти вертикальный
`UpVector`. `ArenaBounds`, ручные `NPCPath` и `PathfindingService` для текущей
навигации не используются.

Рекомендуемый размер `SpawnArena` - минимум `18 x 18` studs, чтобы семь
участников не появлялись слишком близко друг к другу. Спавн-слоты раскладываются
по сетке с шагом `4` studs.

## Раунды

Основные параметры лежат в
`src/ServerScriptService/Round/RoundConfig.lua`.

| Параметр | Сейчас |
| --- | --- |
| Минимум игроков | `1` |
| Длительность стартового отсчёта | `15` секунд |
| Переход участников на арену | последние `5` секунд стартового отсчёта |
| Длительность раунда | `90` секунд |
| Максимум Hider-слотов | `6` |
| Максимум Seeker-слотов | `1` |
| Bot Seeker mode | `true` |
| Шанс игрока стать Seeker | `0` |
| Скорость персонажей | `10` studs/s |
| Масштаб Seeker | `1.5x` |
| Максимум управляемых NPC | `6` |

Текущая логика ролей:

- В фазе `Waiting` все игроки находятся в хабе.
- В фазе `Starting` идёт 15-секундный отсчёт.
- Первые 10 секунд отсчёта участники остаются в хабе.
- На последние 5 секунд сервер выбирает арену, назначает роли и переносит
  участников к `SpawnArena`.
- При `BOT_SEEKER_MODE = true` реальные игроки занимают только Hider-слоты.
- Seeker создаётся как управляемый NPC.
- Пустые Hider-слоты заполняются NPC, пока не достигнуты лимиты.
- Игроки сверх лимита Hider-слотов остаются `Spectator`.
- В фазе `Round` Seeker освобождается, Hider продолжают прятаться.
- Если живых Hider не осталось, раунд заканчивается досрочно.
- После завершения все роли сбрасываются, игроки возвращаются в хаб.

Сервер создаёт `ReplicatedStorage.RoundState` и записывает туда атрибуты
`Phase`, `EndsAt`, `HiderCount`, `CaughtHiderCount`, `SeekerCount`,
`MaxHiders`, `MaxSeekers`, `BotSeekerMode`, `NpcAIEnabled`, `ActiveArena`,
`ActiveArenaSpawn`, `NpcPopulationOverrideEnabled`, `NpcTargetHiders`,
`NpcTargetSeekers` и `MaxAdminNpcs`. Клиентский `RoundTimer` читает основные
атрибуты и показывает
таймер, заполненность ролей и роль локального игрока.

## Видимость Hider

Во время `Round` персонажи с ролью Hider получают атрибут
`RoundHiderInvisible`. Для локального Seeker такие Hider скрываются, пока не
попали в условия обнаружения или клетку.

Hider остаётся видимым, если:

- он сам является локальным игроком;
- локальный игрок тоже Hider;
- Hider пойман и находится в клетке;
- сервер установил принудительную видимость;
- объект внутри модели помечен `RoundPreserveVisualWhenInvisible = true`.

Через `RoundPreserveVisualWhenInvisible` сохраняются видимыми VFX, следы,
подсветка и другие элементы, которые должны оставаться уликами даже при
невидимом теле Hider.

## Seeker: поле поиска, зрение и поимка

Параметры зрения находятся в `src/ReplicatedStorage/SeekerSearchConfig.lua`,
а параметры области поимки — в `src/ReplicatedStorage/CageConfig.lua`.

| Параметр | Сейчас |
| --- | --- |
| Радиус ближнего поиска | `3` studs |
| Дополнительный радиус впереди | `3` studs |
| Доля передних лучей | `1 / 4` от 64 лучей |
| Максимальная разница по высоте | `7` studs |
| Интервал серверной проверки | `0.1` секунды |
| Дистанция зрения | `12` studs |
| Дистанция сопровождения цели | `14` studs |
| Угол зрения | `80` градусов |
| Угол сопровождения | `105` градусов |
| Круговая дистанция внимания вблизи | `4.5` studs |
| Время подтверждения видимости | `0.15` секунды |
| Задержка потери цели | `0.65` секунды |

Клиент рисует вокруг каждого Seeker оранжевое поле поиска. Оно состоит из 64
сегментов: обычный круг имеет радиус `3` studs, а передний сектор получает
длину до `6` studs. Визуал обрезается стенами из `Map/Walls`, физическими
препятствиями и закрытыми дверями.

Сервер независимо проверяет смещённую вперёд область поимки и прямую видимость. В текущей
конфигурации устранять Hider может только управляемый NPC Seeker; игрок-Seeker
не является частью обычного режима.

Зрение отдельно от поимки. Если Hider попал в конус зрения или оказался почти
вплотную к Hunter, бот переходит через короткое состояние `Alert` в
преследование. Само зрение не помещает Hider в клетку. Игрок в клетке остаётся
видимой целью Hunter — клетка обездвиживает, но не защищает от поимки.

## Клетка и спасение

При попадании `CageModel` сервер использует `ServerStorage.cage`. Модель
клонируется вокруг цели в `Workspace.RoundCages` и получает `ProximityPrompt`.
`BatModel` по-прежнему только сбивает цель с ног.

Пока `CageModel` находится в руках, перед игроком отображается сектор `110°`
с максимальной дистанцией `4` studs. У сектора тонкий контур и слабая
полупрозрачная заливка. Цель, которую выберет сервер, дополнительно получает
яркую обводку. Клетка срабатывает только внутри сектора; стены по-прежнему
блокируют попадание.

Требования к модели клетки:

- точное имя: `cage`;
- класс: `Model`;
- внутри должна быть хотя бы одна `BasePart`;
- опциональный маркер `HiderPosition` может быть `Attachment` или `BasePart`;
- если есть `Door` или `Gate`, prompt будет прикреплён к нему.

Пойманный Hider:

- получает атрибут `SearchCaged`;
- фиксируется внутри клетки и не может двигаться или прыгать;
- не может атаковать, и другие игроки не могут ударить его;
- по-прежнему может быть пойман ботом-Hunter в его видимой области поимки;
- видим всем игрокам;
- остаётся в состоянии клетки после `Reset Character`;
- имеет `3`-секундный `ProximityPrompt` для спасения;
- может быть спасён живым Hider на расстоянии до `3` studs с line of sight.

Клетка существует `2.5` секунды. Над ней отображается маленький сегментированный
круг и число оставшихся секунд; по окончании таймера клетка автоматически
исчезает, а движение восстанавливается. При спасении, смене роли, поимке
хантером или завершении раунда она удаляется досрочно. Автоматическая поимка
ботом-Seeker работает отдельно: реальный игрок становится `Spectator`, а
пойманный NPC Hider удаляется с арены.

Нокаут от `BatModel` длится `0.7` секунды. Лежащий в нокауте Hider остаётся
доступен для поимки ботом-Hunter; для него используется корректная высота луча
видимости возле пола.

## TrashCan

`ServerStorage.TrashCan` должен быть `Tool` с `Handle.Attachment` и объектом
`Effect`, внутри которого есть `ParticleEmitter`. `Effect` может быть как
`BasePart`, так и контейнером без собственной позиции: во втором случае сервер
создаёт невидимую летящую деталь у `Handle`, переносит в неё частицы, проводит
эффект вперёд и удаляет его после завершения частиц.

Все остальные реальные игроки и NPC внутри сектора падают в полный нокаут на
`1.5` секунды: движение и анимации останавливаются, стрелявший игрок не
затрагивается. Стены блокируют попадание, а находящиеся в клетке персонажи
сохраняют защиту от обычного оружия. Сам стрелок не может ходить, поворачиваться
или прыгать, пока проигрывается `AllahBabah`.

Пока `TrashCan` выбран, на земле отображается такой же полупрозрачный сектор,
как у клетки, но его размер берётся из настроек `TrashCan`. При попадании цель
получает направленный и вращающий импульс, поэтому игроки и NPC действительно
падают и лежат, а не остаются вертикально в состоянии `PlatformStand`.

Дальность и полный угол сектора настраиваются отдельно в
`src/ReplicatedStorage/TrashCanConfig.lua`:

- `RANGE_STUDS = 12`;
- `ANGLE_DEGREES = 90`.

При выстреле проигрывается `AllahBabah`. В Studio поддерживается сохранённый в
`ServerStorage` `KeyframeSequence`; для опубликованной игры нужна одноимённая
`Animation` с заполненным `AnimationId` внутри `TrashCan` или `ServerStorage`.

## NPC и навигация

NPC создаются в `Workspace.RoundNPCs`: Hider из
`StarterPlayer.StarterCharacter`, а Seeker из `ServerStorage.HunterCharacter`.
Они помечаются атрибутом `ManagedRoundNPC` и получают те же базовые настройки
движения, что у игроков. Цветовая подсветка применяется только к NPC Hider;
Seeker сохраняет внешний вид, исходный масштаб и анимации `HunterCharacter`.

Hider NPC:

- двигаются во время `Starting` и `Round`;
- выбирают точки блуждания по навигационному графу;
- избегают повторного выбора одной зоны;
- после обнаружения переходят в режим побега;
- не двигаются, если находятся в клетке.

Bot Seeker:

- патрулирует углы и узлы карты;
- реагирует на видимость Hider;
- может идти на дым, звук бездействия и мокрые следы;
- при первом обнаружении резко поворачивается к Hider, показывает красный `!`
  и проигрывает пространственный alert-звук;
- после реакции `0.22` секунды преследует или активно ищет цель `3-5` секунд;
- в патруле и при расследовании улик использует скорость `5` studs/s;
- при прямом агре ускоряется до `7.5` studs/s, не меняя обычную скорость патруля;
- ловит Hider только внутри видимого поля поиска: до `3` studs вокруг и до
  `6` studs в переднем секторе, с учётом направления корпуса, стен и прямой
  видимости.

Навигационные параметры Hider и NPC Seeker находятся в
`src/ServerScriptService/Round/HiderConfig.lua`.

## Улики: дым, звук и мокрые следы

`RandomSmokeSetup.server.luau` публикует в `ReplicatedStorage` шаблоны
`RandomSmokeTemplate` и `FartTemplate` из `ServerStorage.Smokes`, а также
создаёт `RemoteEvent` `RandomSmokeTriggered`.

Для живых Hider:

- во время движения раз в случайные `3-5` секунд проигрывается `smoke-01`;
- если Hider стоит на месте `3` секунды, один раз проигрывается `fart`;
- `FartSound` клонируется из `SoundService` и проигрывается от
  `HumanoidRootPart`;
- таймер дыма идёт только во время движения;
- после начала движения эффект бездействия снова становится доступен.

`LeaksAssetsSetup.server.luau` публикует клиентские ассеты `LeaksVisualAssets`.
Если Hider наступает на часть с именем `Leak`/`Leaks` или атрибутом
`IsLeak = true`, он получает мокрый след:

- VFX у ног активен, пока Hider стоит на leak-поверхности;
- на leak-поверхности скорость Hider снижается до `25%` от обычной;
- сразу после выхода скорость поднимается до `40%` от обычной;
- после выхода следы создаются ещё до `7` секунд, одновременно плавно исчезая;
- скорость плавно восстанавливается вместе со следами и достигает обычной,
  когда они полностью исчезают;
- отпечатки появляются при движении от `1` stud/s;
- новый отпечаток ставится примерно каждые `2.2` studs;
- bot Seeker видит дым, звук бездействия и leak-следы по всей активной карте, независимо от поля зрения;
- пока такая улика существует, Seeker идёт к текущей позиции её владельца с
  патрульной скоростью; ускорение включается только после прямого обнаружения.

## Телепорты

`ArenaTeleportService` автоматически ищет в `Workspace` контейнеры с точным
именем `Teleport Pads`. Контейнер должен быть `Folder` или `Model` и содержать:

| Деталь | Назначение |
| --- | --- |
| `Pad1` | переносит персонажа к `Pad2` |
| `Pad2` | переносит персонажа к `Pad1` |

Телепорты работают для реальных игроков и управляемого NPC Seeker. AI может
включить входной Pad в маршрут, если прямого пути к цели нет, и после выхода
сразу перестраивает путь. NPC Hider порталами не пользуются. Пойманный Hider
с атрибутом `SearchCaged` телепортироваться не может.
После телепорта на персонажа ставится кулдаун `1` секунда, чтобы избежать
мгновенного обратного переноса. Клиент получает `ArenaTeleported` и проигрывает
`SoundService.TeleportSound`.

## Двери и коллизии

`DoorCharacterCollider` создаёт физические collision groups:

| Collision group | Использование |
| --- | --- |
| `Characters` | тела игроков |
| `RoundNPCs` | тела NPC |
| `DoorPushers` | невидимый цилиндрический прокси на персонаже |
| `Doors` | физические створки дверей |
| `SeekerSearchRaycasts` | raycast-проверки поиска и видимости |

Чтобы NPC могли толкать дверь, подвижная часть двери должна:

- быть `BasePart`;
- иметь `CanCollide = true`;
- находиться в collision group `Doors`;
- быть частью незаанкеренного assembly;
- при использовании петли может иметь `Attachment` с именем `Hinge1`.

Когда NPC упирается в дверь, сервер временно берёт network ownership assembly,
снимает сопротивление `HingeConstraint.ServoMaxTorque` и прикладывает импульс в
точку контакта.

## Экономика и предметы

Профиль игрока обслуживается серверными модулями в
`src/ServerScriptService/Currency`.

`CurrencyService` создаёт:

- `leaderstats`;
- `leaderstats.Coins`;
- атрибут `ProfileLoaded`;
- атрибут `ProfileLoadError` при ошибке загрузки.

Данные хранятся в DataStore `HideNSeekProfiles_v1` со scope `global` и ключом
`Player_<UserId>`. Стартовый баланс - `0`. Автосейв выполняется каждые `30`
секунд, а грязные изменения планируют сохранение через `2` секунды.

Менять `leaderstats.Coins` напрямую нельзя. Серверные игровые скрипты должны
использовать API:

```luau
local CurrencyService = require(
	game.ServerScriptService.Currency:WaitForChild("CurrencyService")
)

local ok, newBalance, reason = CurrencyService.AddCurrency(player, 1, "CoinPickup")
```

Доступные методы:

| Метод | Назначение |
| --- | --- |
| `IsLoaded(player)` | проверить, загружен ли профиль |
| `AwaitLoaded(player, timeoutSeconds?)` | дождаться загрузки |
| `GetCurrency(player)` | получить баланс |
| `CanAfford(player, amount)` | проверить покупку |
| `AddCurrency(player, amount, reason)` | начислить Coins |
| `SpendCurrency(player, amount, reason)` | списать Coins |
| `SaveNow(player)` | принудительно сохранить профиль |
| `Shutdown()` | сохранить профили при остановке сервера |

Collectibles:

| Предмет | Шаблон | Spawn area | Tag | Награда |
| --- | --- | --- | --- | --- |
| Coin | `ServerStorage.Coin` | `CoinSpawnArea` | `ClientSpinningCoin` | `1` Coin |
| GoldBar | `ServerStorage.GoldBar` | `GoldenBarSpawnArea` | `ClientSpinningGoldBar` | `3` Coins |

`CoinSpawnArea` и `GoldenBarSpawnArea` должны быть `Folder` или `Model`.
Каждая `BasePart` внутри spawn area используется как маркер позиции. Маркеры
скрываются и отключаются для физики. Монеты после подбора появляются снова
через `20` секунд, золотые слитки в текущем коде не респавнятся автоматически.

Для проверки DataStore в Studio нужно опубликовать experience и включить:

```text
Game Settings -> Security -> Enable Studio Access to API Services
```

## Клиентские системы

| Скрипт | Что делает |
| --- | --- |
| `RoundTimer.client.luau` | верхний HUD раунда, роли, таймер и слоты |
| `IsometricCamera.client.luau` | изометрическая камера для Hider/Seeker в `Starting` и `Round` |
| `SeekerSearchVisual.client.luau` | локальное поле поиска Seeker |
| `HiderVisibility.client.luau` | скрытие и раскрытие Hider для Seeker |
| `RandomSmoke.client.luau` | отображение дыма и fart-VFX |
| `LeaksVisuals.client.luau` | VFX мокрых следов и отпечатков |
| `CoinVisuals.client.luau` | вращение монет рядом с камерой |
| `GoldBarVisuals.client.luau` | вращение золотых слитков рядом с камерой |
| `CollectibleSound.client.luau` | звук подбора Coins/GoldBar |
| `TeleportSound.client.luau` | звук телепорта |
| `PlayerMovementAnimation.client.luau` | скорость проигрывания walk/run-анимаций |
| `BatAttack.client.luau` | переключаемые `BatModel`/`CageModel`/`TrashCan`; атака только через `AttackGui/AttackFrame/FistBtn` |

Изометрическая камера использует смещение `Vector3.new(0, 40, 10)`, FOV `35` и
автоматически возвращает стандартную камеру, когда игрок выходит из активной
роли или раунд заканчивается.

## Тестовая админ-панель

Админ-панель монтируется только для пользователей из
`src/ServerScriptService/AdminPanel/AdminConfig.lua`. Сейчас разрешён:

```text
10244668710
```

Панель открывается кнопкой `ADMIN` или клавишей `F2`. GUI создаётся сервером
только для разрешённого пользователя и содержит вкладки:

| Вкладка | Возможности |
| --- | --- |
| `Overview` | статус выбранного игрока, раунда и NPC |
| `Economy` | добавить Coins, снять Coins, сохранить профиль |
| `Player` | назначить роль, вылечить, нормализовать движение, respawn |
| `Round` | старт сейчас, завершить, перезапустить, изменить оставшееся время |
| `NPC` | быстрый spawn/clear по роли, точное число Hider/Hunter NPC, пресет `Only Hunters`, возврат к автоматическому составу, pause/resume AI |

Точный состав NPC ограничен шестью управляемыми NPC суммарно. Он хранится только
до остановки текущего сервера, переживает обычный restart раунда и применяется
при следующем выборе арены, если был задан в `Waiting`. Значения `0 Hiders / N
Hunters` создают состав только из Hunter NPC; игроки при автоматическом
`BOT_SEEKER_MODE` по-прежнему становятся Hider. Кнопка `Restore Automatic
Population` возвращает стандартные лимиты из `RoundConfig`.

Безопасность панели:

- сервер повторно проверяет allowlist на каждом вызове;
- для каждого администратора создаётся отдельный `RemoteFunction`;
- принимаются только известные действия и строгие схемы параметров;
- запросы ограничены кулдауном `0.25` секунды;
- опасные кнопки требуют повторного нажатия, а мутации имеют отдельные
  action- и общие resource-кулдауны;
- ответы кешируются по `RequestId`, чтобы повторная доставка не выполнила
  мутацию дважды;
- payload и ответ ограничены по размеру, а число NPC повторно проверяется и в
  `AdminService`, и в `RoundManager`;
- изменения Coins идут только через `CurrencyService`;
- управление раундом и NPC идёт через `RoundControl`.

При `BOT_SEEKER_MODE = true` роль Hunter (`Seeker`) остаётся NPC-only: сервер
отклоняет назначение игрока на эту роль, а кнопка в админке блокируется.

## Конфигурационные файлы

| Файл | Назначение |
| --- | --- |
| `Round/RoundConfig.lua` | длительности, лимиты ролей, скорость, масштаб Seeker, NPC |
| `Round/HiderConfig.lua` | навигация, патрулирование, побег, двери, AI-пороговые значения |
| `ReplicatedStorage/CageConfig.lua` | модели клетки, область поимки, её визуал, высота над полом и rescue |
| `ReplicatedStorage/TrashCanConfig.lua` | дальность и угол TrashCan, длительность нокаута и полёт эффекта |
| `ReplicatedStorage/SeekerSearchConfig.lua` | поле поиска, зрение и visibility-атрибуты |
| `Currency/CurrencyConfig.lua` | DataStore, лимиты баланса, ретраи загрузки/сохранения |
| `Currency/CollectibleConfig.lua` | теги collectible, награды и дистанция подбора |
| `AdminPanel/AdminConfig.lua` | allowlist админов, кулдауны, лимиты ввода |
| `ReplicatedStorage/MovementAnimationConfig.lua` | скорость playback walk/run-анимаций |

## Проверка перед коммитом

Минимальный набор:

```powershell
rojo build default.project.json --output build/HideNSeek.rbxlx
stylua --check src
selene src
```

Если проверяется только Rojo-структура, можно собирать во временный файл и
удалять его после проверки.

## Частые проблемы

| Симптом | Что проверить |
| --- | --- |
| Раунд висит в `Waiting` | есть ли игроки, `Workspace.HUB.SpawnHUB`, арена со `SpawnArena` |
| NPC не появляются | есть ли `StarterPlayer.StarterCharacter` и `ServerStorage.HunterCharacter` с `Humanoid` и `HumanoidRootPart` |
| NPC не двигаются | есть ли `Map/Floor` и `Map/Walls`, включён ли `NpcAIEnabled` |
| Seeker не видит стены | стены должны лежать внутри `Map/Walls`; `CanQuery` будет включён сервером |
| Двери не толкаются NPC | створка должна быть в collision group `Doors` и быть незаанкеренной |
| `BatModel`/`CageModel`/`TrashCan` не появляются | все объекты должны быть `Tool` в `ServerStorage` и содержать `Handle.Attachment` |
| Не работает клетка | есть ли `ServerStorage.cage` и хотя бы одна `BasePart` внутри модели |
| Нет дыма или fart-VFX | есть ли `ServerStorage.Smokes.smoke-01` и `ServerStorage.Smokes.fart` |
| Нет мокрых следов | есть ли `ServerStorage.Leaks.LeaksVFX`, `Left`, `Right`; поверхность помечена `Leak`, `Leaks` или `IsLeak = true` |
| Не начисляются Coins | опубликован ли experience и включён ли Studio Access to API Services |
| Звук подбора не играет | есть ли `SoundService.GoldSound` |
| Звук телепорта не играет | есть ли `SoundService.TeleportSound` |
