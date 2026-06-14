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
}
