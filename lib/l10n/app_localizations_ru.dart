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
