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
  String get chatRequestSent => 'Запрос отправлен — ожидание одобрения';

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
  String get inviteCopyMine => 'Скопировать мой инвайт';

  @override
  String get invitePasteTheirs => 'Вставьте инвайт собеседника';

  @override
  String get inviteScanTooltip => 'Сканировать QR (скоро)';

  @override
  String get inviteScanComingSoon => 'Сканирование камерой скоро';

  @override
  String get inviteAddButton => 'Добавить контакт';

  @override
  String get inviteInvalid => 'Это не похоже на инвайт xVeil';

  @override
  String get networkRouteTitle => 'Маршрутизация трафика (Proxy / VPN)';

  @override
  String get networkRouteSub => 'oproxy / ogate — скоро';

  @override
  String get networkNodesTitle => 'Мои узлы';

  @override
  String get networkNodesSub => 'Добавить узел по SSH, запустить ogate/oproxy';

  @override
  String get networkExtTitle => 'Расширения (Lua)';

  @override
  String get networkExtSub => 'Загрузка изолированных дополнений';

  @override
  String get networkComingLater => 'Появится в следующих версиях';

  @override
  String get networkStatusError => 'Ошибка';

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
