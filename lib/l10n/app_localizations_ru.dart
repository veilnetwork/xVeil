// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppL10nRu extends AppL10n {
  AppL10nRu([String locale = 'ru']) : super(locale);

  @override
  String get appName => 'xVeil';

  @override
  String get actionContinue => 'Продолжить';

  @override
  String get actionBack => 'Назад';

  @override
  String get actionCancel => 'Отмена';

  @override
  String get actionDone => 'Готово';

  @override
  String get actionCopy => 'Копировать';

  @override
  String get actionUnderstood => 'Понятно';

  @override
  String get preparingTitle => 'Настраиваем ваш узел';

  @override
  String get preparingBody =>
      'Создаём идентичность на этом устройстве. Это может занять некоторое время — пожалуйста, подождите.';

  @override
  String get preparingFirstRunTitle => 'Создаём личность';

  @override
  String get preparingFirstRunBody =>
      'Разовая настройка — может занять до минуты (proof-of-work, чтобы личность нельзя было подделать). Выполняется только при первом запуске; дальнейшие переключения мгновенны.';

  @override
  String get preparingUnlockTitle => 'Открываем хранилище';

  @override
  String get preparingUnlockBody =>
      'Выводим ключ и расшифровываем на этом устройстве — намеренно медленно, чтобы противостоять подбору. Подождите немного.';

  @override
  String get onboardWelcomeTitle => 'Добро пожаловать в xVeil';

  @override
  String get onboardWelcomeBody =>
      'Децентрализованный мессенджер, устойчивый к цензуре. Без номера телефона. Без центрального сервера. Ваша личность и переписка остаются только у вас.';

  @override
  String get onboardChooseTitle => 'Настройка личности';

  @override
  String get onboardCreateIdentity => 'Создать новую личность';

  @override
  String get onboardCreateIdentitySub =>
      'Сгенерировать новый суверенный ключ на этом устройстве';

  @override
  String get onboardRestoreIdentity => 'Восстановить из фразы';

  @override
  String get onboardRestoreIdentitySub =>
      'Используйте 24 слова, чтобы восстановить существующую личность';

  @override
  String get onboardImportBackup => 'Импорт резервной копии';

  @override
  String get onboardImportBackupSub =>
      'Восстановить из зашифрованного файла резервной копии';

  @override
  String get recoveryTitle => 'Сохраните фразу восстановления';

  @override
  String get recoveryBody =>
      'Эти 24 слова — и есть ваша личность. Любой, у кого они есть, управляет ею; потеряете — восстановить будет невозможно. Запишите их на бумаге и храните в надёжном месте. Никогда не храните их в сети и не фотографируйте.';

  @override
  String get recoveryConfirm => 'Я записал(а) фразу восстановления';

  @override
  String get storageTitle => 'Как хранить ваши данные?';

  @override
  String get storageHiddenTitle => 'Скрытое пространство (рекомендуется)';

  @override
  String get storageHiddenBody =>
      'Переписка и ключи хранятся в зашифрованном контейнере с правдоподобным отрицанием. Противник, изъявший устройство, не сможет доказать, что данные вообще существуют.';

  @override
  String get storagePlainTitle => 'Открытое хранение';

  @override
  String get storagePlainBody =>
      'Быстрее настроить, но факт существования ваших данных виден любому, кто осмотрит устройство.';

  @override
  String get storagePlainWarning =>
      'Не рекомендуется пользователям с высоким риском. Выбирайте только если отрицаемость для вас не важна.';

  @override
  String get lockTitle => 'Разблокировать xVeil';

  @override
  String get lockPasswordHint => 'Введите пароль';

  @override
  String get lockUnlock => 'Разблокировать';

  @override
  String get lockWrong => 'Неверный пароль';

  @override
  String get lockStartOver => 'Начать заново';

  @override
  String get lockStartOverBody =>
      'Настроить новую личность на этом устройстве. Существующие данные не удаляются, но для доступа к ним снова понадобится их пароль. Продолжить?';

  @override
  String get lockWipe => 'Удалить все данные';

  @override
  String get lockWipeBody =>
      'Это безвозвратно удалит контейнер и ВСЕ личности внутри него — включая скрытые и ложные. Действие необратимо: без контейнера данные восстановить невозможно даже с верным паролем.';

  @override
  String get lockWipeTypePrompt =>
      'Чтобы подтвердить безвозвратное удаление, введите точно эту фразу:';

  @override
  String get lockWipePhrase => 'я понимаю последствия';

  @override
  String get lockWipeConfirm => 'Удалить навсегда';

  @override
  String get navChats => 'Чаты';

  @override
  String get navNetwork => 'Сеть';

  @override
  String get navSettings => 'Настройки';

  @override
  String get chatsEmpty => 'Пока нет переписок';

  @override
  String get chatsEmptyHint => 'Начните новый чат, чтобы написать сообщение';

  @override
  String get chatNewMessageHint => 'Сообщение';

  @override
  String get chatSend => 'Отправить';

  @override
  String get notificationNewMessage => 'Новое сообщение';

  @override
  String get notificationsTitle => 'Уведомления';

  @override
  String get notificationsEnabled => 'Показывать уведомления';

  @override
  String get notificationsPreview => 'Превью сообщения';

  @override
  String get notificationsPreviewHidden =>
      'Скрытое («новое сообщение», без отправителя и текста)';

  @override
  String get notificationsPreviewFull => 'Полное (отправитель и текст)';

  @override
  String get chatRequestSent => 'Запрос отправлен — ожидание одобрения';

  @override
  String get chatRequestResend => 'Отправить снова';

  @override
  String get chatRequestCancel => 'Отменить';

  @override
  String get chatRequestCancelTitle => 'Отменить запрос?';

  @override
  String get chatRequestCancelBody =>
      'Удаляет этот запрос и переписку с вашего устройства. Если он уже дошёл, собеседник мог его увидеть.';

  @override
  String get chatBlockedContact => 'Вы заблокировали этот контакт';

  @override
  String get chatRequestHint => 'Напишите запрос на связь…';

  @override
  String get chatAttachTooltip => 'Прикрепить файл';

  @override
  String get chatFileSave => 'Сохранить';

  @override
  String get chatFileSaved => 'Файл сохранён';

  @override
  String get chatFileSaveFailed => 'Не удалось сохранить файл';

  @override
  String get chatFileTooLarge => 'Файл слишком большой';

  @override
  String get chatMsgEdit => 'Изменить';

  @override
  String get chatMsgDeleteForEveryone => 'Удалить у всех';

  @override
  String get chatMsgDeleteForMe => 'Удалить у себя';

  @override
  String get chatMsgCopy => 'Копировать текст';

  @override
  String get chatMsgCopied => 'Скопировано';

  @override
  String get chatLoadEarlier => 'Загрузить ранние сообщения';

  @override
  String get chatListDelete => 'Удалить чат';

  @override
  String get chatDeleteChatTitle => 'Удалить этот чат?';

  @override
  String get chatDeleteChatBody =>
      'Переписка и все сообщения удаляются с этого устройства. Собеседник не уведомляется.';

  @override
  String get chatEditTitle => 'Изменить сообщение';

  @override
  String get chatEditSave => 'Сохранить';

  @override
  String get chatDeleteTitle => 'Удалить сообщение?';

  @override
  String get chatDeleteForMeBody =>
      'Оно будет безвозвратно стёрто с этого устройства.';

  @override
  String get chatDeleteForEveryoneBody =>
      'Оно стирается здесь, а собеседнику отправляется запрос на удаление — но он мог уже увидеть или скопировать его.';

  @override
  String get chatDeleteConfirm => 'Удалить';

  @override
  String get chatEdited => 'изменено';

  @override
  String get chatMenuRename => 'Переименовать';

  @override
  String get chatRenameTitle => 'Локальное имя';

  @override
  String get chatMenuUnblock => 'Разблокировать';

  @override
  String get chatMenuClearHistory => 'Очистить историю';

  @override
  String get chatMenuDeleteConversation => 'Удалить переписку';

  @override
  String get chatClearHistoryTitle => 'Очистить историю?';

  @override
  String get chatClearHistoryBody =>
      'Все сообщения этого чата будут стёрты с этого устройства. Контакт останется, переписку можно продолжить. Собеседник не будет уведомлён.';

  @override
  String get chatClearHistoryConfirm => 'Очистить';

  @override
  String get chatMsgInfo => 'Сведения о сообщении';

  @override
  String get msgInfoId => 'Идентификатор';

  @override
  String get msgInfoTime => 'Время';

  @override
  String get msgInfoDirection => 'Направление';

  @override
  String get msgInfoStatus => 'Статус';

  @override
  String get msgInfoFile => 'Файл';

  @override
  String get dirIncoming => 'Получено';

  @override
  String get dirOutgoing => 'Отправлено';

  @override
  String get msgStatusSending => 'Отправляется…';

  @override
  String get msgStatusSent => 'Отправлено';

  @override
  String get msgStatusDelivered => 'Доставлено';

  @override
  String get msgStatusFailed => 'Не доставлено';

  @override
  String get identityPickerTitle => 'Выберите личность';

  @override
  String get identityPickerSubtitle =>
      'В этом хранилище несколько личностей — выберите, от какой действовать.';

  @override
  String get networkTitle => 'Оверлей-сеть';

  @override
  String get networkStatusConnected => 'Подключено';

  @override
  String get networkStatusConnecting => 'Подключение…';

  @override
  String get networkStatusOffline => 'Не в сети';

  @override
  String networkPeers(int count) {
    return '$count узлов';
  }

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get settingsIdentity => 'Личность';

  @override
  String get settingsStorage => 'Хранилище и пространства';

  @override
  String get settingsStorageCompact => 'Сжать хранилище';

  @override
  String get settingsStorageCompactBody =>
      'Освободить неиспользуемое место — приложение переоткроется.';

  @override
  String get settingsStorageCompactDone => 'Освобождено';

  @override
  String get settingsStorageCompactFailed => 'Не удалось сжать хранилище';

  @override
  String get settingsStoragePasswordHint => 'Ваш пароль';

  @override
  String get settingsNetwork => 'Сеть и узлы';

  @override
  String get settingsAppearance => 'Оформление';

  @override
  String get settingsAbout => 'О приложении';

  @override
  String get settingsLanguage => 'Язык';

  @override
  String get settingsLockNow => 'Заблокировать';

  @override
  String get settingsSwitchIdentity => 'Сменить личность';

  @override
  String get settingsAddIdentity => 'Добавить личность';

  @override
  String get addIdentityTitle => 'Добавить личность';

  @override
  String get addIdentitySubtitle =>
      'Новая личность прячется в том же файле. При первом добавлении ваша текущая личность и новая управляются мастер-паролем, который вы зададите ниже.';

  @override
  String get addIdentityCurrentName => 'Имя текущей личности';

  @override
  String get addIdentityNewName => 'Имя новой личности';

  @override
  String get addIdentityNewPassword => 'Пароль новой личности';

  @override
  String get addIdentityMasterPassword => 'Мастер-пароль';

  @override
  String get addIdentityMasterHint =>
      'Открывает выбор личностей. Должен отличаться от пароля каждой личности.';

  @override
  String get addIdentityCreate => 'Создать';

  @override
  String get addIdentityIncomplete => 'Заполните все поля.';

  @override
  String get addIdentityClash =>
      'Этот мастер-пароль уже занят личностью — выберите другой.';

  @override
  String get addIdentityWorking =>
      'Создаём новую личность…\nЭто может занять несколько секунд.';

  @override
  String get addIdentityAnonymous => 'Анонимная маршрутизация';

  @override
  String get addIdentityAnonymousHint =>
      'Скрыть сетевую активность этой личности через overlay veil, чтобы её нельзя было связать с другими вашими личностями. Медленнее.';

  @override
  String get settingsKeepAllOnline => 'Держать все личности онлайн';

  @override
  String get settingsKeepAllOnlineHint =>
      'Запускать узлы всех личностей сразу, чтобы при переключении никто не уходил в оффлайн. Менее анонимно — наблюдатель может связать ваши личности по общему устройству. Чувствительные личности отмечайте для анонимной маршрутизации.';

  @override
  String get settingsAnonymousRouting => 'Анонимная маршрутизация (onion)';

  @override
  String get settingsAnonymousEnabledHint =>
      'теперь через onion — применится при следующем запуске';

  @override
  String get settingsAnonymousDisabledHint =>
      'больше не через onion — применится при следующем запуске';

  @override
  String get settingsLazyMining => 'Ленивый майнинг (поднять доверие)';

  @override
  String get settingsLazyMiningEnabledHint =>
      'в фоне намайнивает дополнительную анти-сибил сложность — нагружает CPU; применится при следующем запуске';

  @override
  String get settingsLazyMiningDisabledHint =>
      'выключен — без фонового майнинга сложности (рекомендуется); применится при следующем запуске';

  @override
  String get settingsManageIdentities => 'Управление личностями';

  @override
  String get manageTitle => 'Управление личностями';

  @override
  String get manageActive => 'активна';

  @override
  String get manageAnonOn => 'Анонимная маршрутизация';

  @override
  String get manageAnonOff => 'Выключить анонимность';

  @override
  String get manageBind => 'Привязать существующую';

  @override
  String get manageBindHint =>
      'Добавить уже имеющуюся личность к этому мастеру';

  @override
  String get manageBindBody =>
      'Введите собственный пароль личности, чтобы добавить её к этому мастеру. Личность шерится, а не копируется — она остаётся доступной и по своему паролю.';

  @override
  String get manageBindPassword => 'Пароль личности';

  @override
  String get manageBindLabel => 'Имя в этом мастере';

  @override
  String get manageBindError =>
      'Не удалось привязать — неверный пароль, это мастер, либо такое имя/личность уже здесь.';

  @override
  String get manageUnbind => 'Отвязать от мастера';

  @override
  String get manageUnbindBody =>
      'Убирает личность только из этого мастера. Её пространство НЕ удаляется — она по-прежнему открывается своим паролем и из других мастеров, где числится.';

  @override
  String get manageUnbindLastError =>
      'Нельзя отвязать последнюю личность. Удалите её или очистите все данные.';

  @override
  String get manageDelete => 'Удалить личность';

  @override
  String get manageDeleteBody =>
      'Безвозвратно стирает личность — её ключи, контакты, сообщения и файлы вычищаются из контейнера. Действие необратимо.';

  @override
  String get manageDeleteLastError =>
      'Нельзя удалить последнюю личность. Используйте «Удалить все данные».';

  @override
  String get settingsDecoyMaster => 'Настроить ложный доступ';

  @override
  String get decoyTitle => 'Ложный доступ (под принуждением)';

  @override
  String get decoySubtitle =>
      'Отдельный пароль, который под принуждением открывает только отмеченные ниже личности. Ваш настоящий мастер и остальные личности остаются скрытыми.';

  @override
  String get decoyWarning =>
      'Тот, кому вы выдадите этот пароль, увидит ВСЁ содержимое каждой отмеченной личности. Включайте только действительно безопасные.';

  @override
  String get decoyPassword => 'Пароль под принуждением';

  @override
  String get decoyInclude => 'Какие личности показывать под принуждением';

  @override
  String get decoyCreate => 'Создать ложный доступ';

  @override
  String get decoyCreated => 'Ложный доступ создан.';

  @override
  String get decoyPickOne => 'Выберите хотя бы одну личность.';

  @override
  String get decoyClash => 'Этот пароль уже занят — выберите другой.';

  @override
  String get languageSystem => 'Системный';

  @override
  String get languageRussian => 'Русский';

  @override
  String get languageEnglish => 'English';

  @override
  String get chatRequestTitle => 'Контакт хочет связаться с вами';

  @override
  String get actionAccept => 'Принять';

  @override
  String get actionBlock => 'Заблокировать';

  @override
  String get actionOpen => 'Открыть';

  @override
  String get inviteAddContact => 'Добавить контакт';

  @override
  String get inviteShowToContact => 'Покажите это собеседнику';

  @override
  String get inviteTooLarge => 'инвайт слишком большой';

  @override
  String get inviteCopied => 'Инвайт скопирован';

  @override
  String get inviteIsSelf =>
      'Это ваш собственный инвайт — нельзя добавить себя.';

  @override
  String get inviteCopyMine => 'Скопировать мой инвайт';

  @override
  String get identityDetails => 'Детали личности';

  @override
  String get identityPublicKey => 'публичный ключ';

  @override
  String get identityAlgo => 'алгоритм';

  @override
  String get invitePasteTheirs => 'Вставьте инвайт собеседника';

  @override
  String get inviteScanTooltip => 'Сканировать QR камерой';

  @override
  String get inviteScanComingSoon => 'Сканирование камерой скоро';

  @override
  String get scanTitle => 'Сканировать инвайт';

  @override
  String get scanHint => 'Наведите камеру на QR-код инвайта собеседника';

  @override
  String get scanUnavailable => 'Камера недоступна — вставьте инвайт вручную';

  @override
  String get scanNotInvite => 'Этот QR не является инвайтом xVeil';

  @override
  String get scanTorch => 'Подсветка';

  @override
  String get inviteAddButton => 'Добавить контакт';

  @override
  String get inviteInvalid => 'Это не похоже на инвайт xVeil';

  @override
  String get networkRouteTitle => 'Маршрутизация трафика (Proxy / VPN)';

  @override
  String get networkRouteSub => 'oproxy / ogate — скоро';

  @override
  String get networkRouteSubActive => 'Маршрутизация включена';

  @override
  String get networkRouteSubIdle => 'Пустить трафик через veil';

  @override
  String get routeTitle => 'Маршрутизация трафика';

  @override
  String get routeSocks5Title => 'Маршрутизировать мой трафик (SOCKS5)';

  @override
  String get routeSocks5Hint =>
      'Поднять локальный SOCKS5-прокси и пустить его трафик через veil на выходной узел. Направьте на него браузер или системный прокси, чтобы обходить цензуру и скрывать своё местоположение.';

  @override
  String get routeListenLabel => 'Локальный адрес SOCKS5';

  @override
  String get routeListenHint =>
      'Только loopback (например 127.0.0.1:1080) — прокси остаётся приватным для этого устройства.';

  @override
  String get routeListenInvalid =>
      'Укажите loopback host:port, например 127.0.0.1:1080';

  @override
  String get routeExitNodeLabel => 'Node id выходного узла (64-hex)';

  @override
  String get routeExitNodeHint =>
      'node_id выходного узла, которому вы доверяете — например, ваш собственный узел из «Мои узлы».';

  @override
  String get routeExitNodeInvalid => 'Нужен node id из 64 hex-символов';

  @override
  String get routeNeedExit =>
      'Укажите node id выходного узла для маршрутизации';

  @override
  String routeProxyAddress(String addr) {
    return 'Направьте приложения / браузер на $addr';
  }

  @override
  String get routeServeTitle => 'Быть выходным узлом';

  @override
  String get routeServeHint =>
      'Разрешить другим узлам выходить в интернет через этот узел. Больше выходных узлов — устойчивее сеть к цензуре, но трафик будет выглядеть исходящим с этого устройства.';

  @override
  String get routeAllowPrivate => 'Разрешить приватные сети (продвинутое)';

  @override
  String get routeAllowPrivateHint =>
      'Позволить выходному узлу обращаться к loopback / RFC1918 / link-local адресам. На публичном выходном узле держите ВЫКЛ — иначе открывается доступ к внутренним сервисам и облачным metadata-эндпоинтам.';

  @override
  String get routeAppliesNextStart =>
      'Изменения применятся при следующем запуске узла.';

  @override
  String get routeRestartNode => 'Перезапустить узел сейчас';

  @override
  String get networkNodesTitle => 'Мои узлы';

  @override
  String get networkNodesSub => 'Добавить узел по SSH, запустить ogate/oproxy';

  @override
  String networkNodesSubCount(int count) {
    return 'Узлов: $count';
  }

  @override
  String get nodesTitle => 'Мои узлы';

  @override
  String get nodesEmpty => 'Пока нет узлов';

  @override
  String get nodesEmptyHint =>
      'Добавьте сервер, который держите как выходной узел / реле — и пускайте через него трафик из «Маршрутизация трафика».';

  @override
  String get nodesAdd => 'Добавить узел';

  @override
  String get nodeEdit => 'Изменить узел';

  @override
  String get nodeLabelLabel => 'Название';

  @override
  String get nodeLabelRequired => 'Введите название';

  @override
  String get nodeIdLabel => 'Node id (64-hex)';

  @override
  String get nodeIdHintText =>
      'veil-id узла — чтобы маршрутизировать через него ваш трафик.';

  @override
  String get nodeIdInvalid => 'Нужен node id из 64 hex-символов';

  @override
  String get nodeSshHostLabel => 'SSH-хост (необязательно)';

  @override
  String get nodeSshPortLabel => 'SSH-порт';

  @override
  String get nodeSshUserLabel => 'SSH-пользователь (необязательно)';

  @override
  String get actionSave => 'Сохранить';

  @override
  String get nodeRemove => 'Удалить узел';

  @override
  String get nodeRemoveConfirm =>
      'Убрать узел из списка? Сам сервер не затрагивается.';

  @override
  String get nodeUseAsExit => 'Использовать как выходной узел';

  @override
  String get nodeUseAsExitDone => 'Назначен выходным узлом SOCKS5';

  @override
  String get nodeNeedsNodeId =>
      'Добавьте node id, чтобы маршрутизировать через этот узел';

  @override
  String get nodeProvision => 'Развернуть узел veil по SSH';

  @override
  String get provisionTitle => 'Развёртывание по SSH';

  @override
  String get provisionReleaseUrl => 'URL релиза veil-cli';

  @override
  String get provisionReleaseHint =>
      'Прямая ссылка на бинарь veil-cli для архитектуры сервера (ассет GitHub-релиза).';

  @override
  String get provisionSha256 => 'SHA-256 для veil-cli';

  @override
  String get provisionSha256Hint =>
      'Обязательно. 64-символьный hex SHA-256, опубликованный вместе с бинарём. Установка на сервере прерывается, если загрузка не совпадает — именно это не даёт подменённому бинарю выполниться от root.';

  @override
  String get provisionRunExit =>
      'Запустить как выходной узел (маршрутизировать через него)';

  @override
  String get provisionScriptLabel =>
      'Выполнится на сервере под root — проверьте перед запуском:';

  @override
  String get provisionPskMissing =>
      'PSK развёртывания не вшит в эту сборку — узел не сможет войти в сеть. Развёртывание недоступно.';

  @override
  String get provisionRun => 'Выполнить по SSH';

  @override
  String get provisionRunning =>
      'Развёртывание… (майнинг личности может занять время)';

  @override
  String get provisionNeedUrl => 'Укажите https-ссылку на релиз';

  @override
  String get provisionSavedNodeId => 'node id, сообщённый сервером, сохранён';

  @override
  String get nodeSshConnect => 'Подключиться по SSH';

  @override
  String sshDialogTitle(String host) {
    return 'SSH к $host';
  }

  @override
  String get sshUsePassword => 'Пароль';

  @override
  String get sshUseKey => 'Приватный ключ';

  @override
  String get sshPasswordLabel => 'Пароль';

  @override
  String get sshKeyLabel => 'Приватный ключ (PEM)';

  @override
  String get sshKeyPassphraseLabel => 'Пароль ключа (необязательно)';

  @override
  String get sshCredsNotSaved =>
      'Используется один раз для этого подключения — не сохраняется.';

  @override
  String get sshConnectRun => 'Подключиться и проверить';

  @override
  String get sshConnecting => 'Подключение…';

  @override
  String sshDone(String code) {
    return 'Готово (код $code)';
  }

  @override
  String sshError(String err) {
    return 'Ошибка: $err';
  }

  @override
  String get nodeCheckReachable => 'Проверить доступность';

  @override
  String get nodeChecking => 'Проверяем…';

  @override
  String get nodeReachable => 'Доступен';

  @override
  String get nodeUnreachable => 'Недоступен';

  @override
  String get networkExtTitle => 'Расширения (Lua)';

  @override
  String get networkExtSub => 'Загрузка изолированных дополнений';

  @override
  String get networkComingLater => 'Появится в следующих версиях';

  @override
  String get networkStatusError => 'Ошибка';

  @override
  String get networkBackgroundTitle => 'Работать в фоне';

  @override
  String get networkBackgroundHint =>
      'Только Android. Держит узел — ваш прокси и доставку входящих сообщений — активным после выхода из приложения. Требует постоянного уведомления (видно, что приложение работает) и расходует больше батареи.';

  @override
  String get peersTitle => 'Подключённые узлы';

  @override
  String get peersSectionActive => 'Активные';

  @override
  String get peersSectionInactive => 'Неактивные';

  @override
  String get peersEmpty => 'Пока нет узлов';

  @override
  String get peersEmptyHint =>
      'Когда ваш узел подключится к другим, они появятся здесь.';

  @override
  String get peerActiveNow => 'активен сейчас';

  @override
  String get peerNeverSeen => 'ещё не подключался';

  @override
  String get peerLastSeenLabel => 'был активен';

  @override
  String get peerDetailsTitle => 'Сведения об узле';

  @override
  String get peerFieldNodeId => 'node_id';

  @override
  String get peerFieldTransport => 'транспорт';

  @override
  String get peerFieldState => 'состояние';

  @override
  String get peerFieldDirection => 'направление';

  @override
  String get peerFieldLastSeen =>
      'последняя активность (по данным этого устройства)';

  @override
  String get peerStateActive => 'Активен';

  @override
  String get peerStateConnecting => 'Подключается';

  @override
  String get peerStateClosed => 'Отключён';

  @override
  String get peerStateUnknown => 'Неизвестно';

  @override
  String get peerDirInbound => 'Входящее';

  @override
  String get peerDirOutbound => 'Исходящее';

  @override
  String get peerDirUnknown => 'Неизвестно';

  @override
  String get timeJustNow => 'только что';

  @override
  String timeMinutesAgo(int n) {
    return '$n мин назад';
  }

  @override
  String timeHoursAgo(int n) {
    return '$n ч назад';
  }

  @override
  String timeDaysAgo(int n) {
    return '$n дн назад';
  }

  @override
  String get peersShareAction => 'Поделиться узлами входа';

  @override
  String get peersShareTitle => 'Поделиться узлами входа';

  @override
  String get peersShareSubtitle =>
      'Выберите узлы, чтобы дать другу рабочие точки входа в сеть — пригодится, если у него заблокированы узлы по умолчанию. Передаются ТОЛЬКО эти узлы, а не ваша личность.';

  @override
  String get peersShareNone =>
      'Нет известных узлов входа, которыми можно поделиться';

  @override
  String get peersShareSelectOne => 'Выберите хотя бы один узел';

  @override
  String get peersShareGenerate => 'Сформировать ссылку';

  @override
  String get peersShareScanHint =>
      'Пусть собеседник отсканирует это или откроет ссылку в xVeil';

  @override
  String get peerActiveBadge => 'активен';

  @override
  String peersImported(int n) {
    return 'Добавлено узлов входа: $n';
  }

  @override
  String get onboardRepeatPassword => 'Повторите пароль';

  @override
  String get onboardPasswordTitle => 'Придумайте пароль';

  @override
  String get onboardPasswordSubtitle =>
      'Этот пароль открывает ваше пространство на этом устройстве. Сброса нет.';

  @override
  String get onboardPasswordTooShort => 'Минимум 6 символов';

  @override
  String get onboardPasswordMismatch => 'Пароли не совпадают';

  @override
  String onboardComingSoon(String label) {
    return '$label — появится в следующей версии';
  }

  @override
  String get recoveryPhraseHint =>
      'Введите фразу восстановления, слова через пробел';

  @override
  String get demoChatTooltip => 'Демо-чат';

  @override
  String get demoNewChat => 'Новый чат';

  @override
  String get demoPeerNodeId => 'Node id собеседника (hex)';

  @override
  String get demoChatWith => 'Чат с демо-узлом';
}
