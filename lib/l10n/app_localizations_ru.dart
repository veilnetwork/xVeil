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
  String get onboardRestoreBody =>
      'Введите 24 слова фразы восстановления, записанной при создании личности. На этом устройстве будет воссоздана та же личность.';

  @override
  String get onboardRestoreSubmit => 'Восстановить';

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
  String get navCommunities => 'Сообщества';

  @override
  String get navFeed => 'Лента';

  @override
  String get navNetwork => 'Сеть';

  @override
  String get navSettings => 'Настройки';

  @override
  String get navCalls => 'Звонки';

  @override
  String get callLogEmpty => 'Пока нет звонков';

  @override
  String get callLogEmptyHint =>
      'Здесь появятся звонки, сделанные и принятые на любом из ваших устройств';

  @override
  String get callOutcomeMissed => 'Пропущенный';

  @override
  String get callOutcomeDeclined => 'Отклонён';

  @override
  String get callOutcomeCancelled => 'Отменён';

  @override
  String get callOutcomeBusy => 'Занято';

  @override
  String get callOutcomeFailed => 'Не удался';

  @override
  String get spaceCreateTitle => 'Новое сообщество';

  @override
  String get spaceCreateAction => 'Создать';

  @override
  String get spaceNameHint => 'Название сообщества';

  @override
  String get spaceDescriptionLabel => 'Описание';

  @override
  String get spaceDescriptionHint => 'Для чего создано это сообщество';

  @override
  String get spaceDescriptionEditTitle => 'Изменить описание';

  @override
  String get spaceDescriptionSave => 'Сохранить описание';

  @override
  String get spaceVisibilityLabel => 'Видимость';

  @override
  String get spaceVisibilityPublic => 'Публичное';

  @override
  String get spaceVisibilityPrivate => 'Приватное';

  @override
  String get spaceVisibilitySecret => 'Секретное';

  @override
  String get spaceVisibilityPublicHint =>
      'Публикациями можно делиться публично. Автоматический поиск не включён до готовности протокола распространителей.';

  @override
  String get spaceVisibilityPrivateHint =>
      'Вступление — по приглашению, содержимое шифруется для текущих участников.';

  @override
  String get spaceVisibilitySecretHint =>
      'В приглашениях скрывается название; содержимое зашифровано, а сообщество никогда не появляется в поиске.';

  @override
  String get spaceEmpty => 'Пока нет сообществ';

  @override
  String get spaceOperationFailed =>
      'Не удалось изменить сообщество. Проверьте сеть и повторите попытку.';

  @override
  String get spaceChannelsEmpty => 'В сообществе пока нет каналов';

  @override
  String get spaceChannelCreateTitle => 'Новый канал';

  @override
  String get spaceChannelNameHint => 'Название канала';

  @override
  String get spaceChannelText => 'Текстовый канал';

  @override
  String get spaceChannelVoice => 'Голосовой канал';

  @override
  String get spaceChannelCategory => 'Категория';

  @override
  String get spaceChannelAccess => 'Доступ';

  @override
  String get spaceChannelAccessSpace => 'Все участники сообщества';

  @override
  String get spaceChannelAccessRestricted =>
      'Закрытый · сначала только администраторы';

  @override
  String get spaceChannelAccessSecret =>
      'Секретный · сначала только администраторы';

  @override
  String get spaceVoiceStartFailed =>
      'Не удалось начать голосовую сессию или присоединиться к ней.';

  @override
  String get spacePostsTitle => 'Публикации';

  @override
  String get spacePostsEmpty => 'Публикаций пока нет';

  @override
  String get spacePostCreateTitle => 'Новая публикация';

  @override
  String get spacePostTitleHint => 'Заголовок (необязательно)';

  @override
  String get spacePostBodyHint => 'Поделитесь новостью с сообществом…';

  @override
  String get spacePostPublish => 'Опубликовать';

  @override
  String get spacePostEdit => 'Редактировать публикацию';

  @override
  String get spacePostEdited => 'Изменено';

  @override
  String get spacePostPin => 'Закрепить';

  @override
  String get spacePostUnpin => 'Открепить';

  @override
  String get spacePostPinned => 'Закреплено';

  @override
  String get feedPinnedTitle => 'Закреплённые';

  @override
  String get feedRecentTitle => 'Последние';

  @override
  String get spacePostDelete => 'Удалить публикацию';

  @override
  String get spacePostDeleteTitle => 'Удалить эту публикацию?';

  @override
  String get spacePostDeleteBody =>
      'Подписанный tombstone уберёт её из ленты сообщества на всех синхронизированных устройствах участников. Отменить это действие нельзя.';

  @override
  String get spacePostTypePost => 'Публикация';

  @override
  String get spacePostTypeArticle => 'Статья';

  @override
  String get spacePostTypeVideo => 'Видео';

  @override
  String get spacePostTypeShortVideo => 'Короткое видео';

  @override
  String get spacePostTypeAudio => 'Аудио';

  @override
  String get spacePostTypeVoiceMessage => 'Голосовое сообщение';

  @override
  String get spaceFeedEnable => 'Показывать сообщество в ленте';

  @override
  String get spaceFeedDisable => 'Скрыть сообщество из ленты';

  @override
  String get spaceSettingsTitle => 'Участники и настройки';

  @override
  String get spaceMembersTooltip => 'Участники и настройки';

  @override
  String get spaceRetentionTitle => 'Хранение истории';

  @override
  String get spaceRetentionSafetyHint =>
      'Политика сообщества и локальная история этого устройства независимы.';

  @override
  String get spaceRetentionGlobal => 'Политика сообщества';

  @override
  String get spaceRetentionGlobalHint =>
      'Подписывается владельцем и применяется у всех участников.';

  @override
  String get spaceRetentionLocal => 'На этом устройстве';

  @override
  String get spaceRetentionLocalHint =>
      'Скрывает только локальную историю и ничего не удаляет у других участников.';

  @override
  String get spaceActiveTitle => 'Сообщество активно';

  @override
  String get spaceActiveHint =>
      'Участники могут публиковать материалы, писать в каналах и входить в голосовые комнаты.';

  @override
  String get spaceArchivedTitle => 'Сообщество в архиве';

  @override
  String get spaceArchivedHint =>
      'История доступна для чтения, но сообщения, публикации, реакции, голосовые комнаты и настройки закрыты для изменений.';

  @override
  String get spaceDeletedTitle => 'Сообщество ожидает удаления';

  @override
  String get spaceDeletedHint =>
      'Содержимое скрыто, вся активность остановлена. Владелец может восстановить сообщество до окончания периода восстановления.';

  @override
  String get spaceDeleteTitle => 'Удалить сообщество?';

  @override
  String get spaceDeleteConfirm =>
      'Сообщество можно будет восстановить в течение 7 дней. После этого локальные зашифрованные копии удалятся фоновой задачей, а старые снимки не смогут их воскресить.';

  @override
  String get spaceDeleteAction => 'Удалить сообщество';

  @override
  String get spaceDeleteHint =>
      'Запускает 7-дневный период восстановления перед физической очисткой.';

  @override
  String spaceRecoveryUntil(String date) {
    return 'Восстановление доступно до $date';
  }

  @override
  String get spaceArchiveTitle => 'Архивировать сообщество?';

  @override
  String get spaceArchiveConfirm =>
      'Будет создана подписанная владельцем граница, после которой сообщество станет доступно только для чтения на всех устройствах. Его можно восстановить позже.';

  @override
  String get spaceArchiveAction => 'Архивировать';

  @override
  String get spaceRestoreTitle => 'Восстановить сообщество?';

  @override
  String get spaceRestoreConfirm =>
      'Новый контент начнёт отдельную подписанную эпоху. Архивная история останется доступна.';

  @override
  String get spaceRestoreAction => 'Восстановить';

  @override
  String spaceMembers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count участников',
      few: '$count участника',
      one: '1 участник',
    );
    return '$_temp0';
  }

  @override
  String get spaceMemberAdd => 'Пригласить участника';

  @override
  String get spaceNoContactsToAdd => 'Все принятые контакты уже участвуют';

  @override
  String get spaceInviteSent =>
      'Приглашение отправлено. Состав и ключи останутся закрыты до принятия.';

  @override
  String get spaceInvitesTitle => 'Приглашения';

  @override
  String get spaceSecretInviteTitle => 'Секретное сообщество';

  @override
  String spaceInviteFrom(String peer) {
    return 'От $peer';
  }

  @override
  String get spaceInviteAccept => 'Принять';

  @override
  String get spaceInviteDecline => 'Отклонить';

  @override
  String get spaceInviteJoining => 'Принято · ожидается проверенное членство';

  @override
  String get spaceJoinAction => 'Вступить по ссылке';

  @override
  String get spaceJoinDialogTitle => 'Запросить вступление в сообщество';

  @override
  String get spaceJoinCodeHint => 'Вставьте ссылку xveil://space';

  @override
  String get spaceJoinSafetyHint =>
      'Ссылка отправляет только заявку. Каналы, участники и ключи останутся недоступны, пока администратор не подтвердит вступление подписанной записью.';

  @override
  String get spaceJoinRequestSent =>
      'Заявка отправлена. Сообщество появится после подписанного подтверждения.';

  @override
  String get spaceJoinRequestsTitle => 'Заявки на вступление';

  @override
  String spaceJoinRequestFrom(String peer) {
    return 'Заявка от $peer';
  }

  @override
  String get spaceJoinRequestPending => 'Ожидает подтверждения';

  @override
  String get spaceJoinRequestApproved =>
      'Одобрено · получаем проверенное членство';

  @override
  String get spaceJoinRequestDeclined => 'Отклонено';

  @override
  String get spaceJoinDismiss => 'Скрыть';

  @override
  String get spaceJoinApprove => 'Одобрить';

  @override
  String get spaceJoinDecline => 'Отклонить';

  @override
  String get spaceJoinLinkTitle => 'Публичная ссылка для вступления';

  @override
  String get spaceJoinLinkHint =>
      'Любой, у кого есть эта отзывная ссылка, сможет отправить заявку. Сама ссылка никогда не предоставляет доступ.';

  @override
  String get spaceJoinLinkCreate => 'Создать ссылку';

  @override
  String get spaceJoinLinkCopy => 'Копировать ссылку';

  @override
  String get spaceJoinLinkRevoke => 'Отозвать ссылку';

  @override
  String get spaceJoinLinkCopied => 'Ссылка для вступления скопирована';

  @override
  String get spaceJoinLinkRevoked => 'Ссылка для вступления отозвана';

  @override
  String get spaceRecommendationsTitle => 'Рекомендации';

  @override
  String get spaceRecommendationsHint =>
      'Создайте подписанную публичную кампанию. После этого участники смогут рекомендовать сообщество только явно выбранным контактам.';

  @override
  String get spaceRecommendationCreate => 'Создать кампанию';

  @override
  String get spaceRecommendationTextHint =>
      'Текст, который участники отправят вместе с карточкой сообщества';

  @override
  String get spaceRecommendationShare => 'Рекомендовать сообщество';

  @override
  String get spaceRecommendationSelectCampaign => 'Выберите кампанию';

  @override
  String get spaceRecommendationSelectContact => 'Выберите получателя';

  @override
  String get spaceRecommendationRevoke => 'Отозвать кампанию';

  @override
  String get spaceRecommendationSent => 'Рекомендация отправлена';

  @override
  String get spaceRecommendationDuplicate =>
      'Эта кампания уже отправлялась этому контакту';

  @override
  String get spaceRecommendationRateLimited =>
      'Лимит рекомендаций исчерпан. Повторите позже.';

  @override
  String get spaceRecommendationAlreadyMember =>
      'Этот контакт уже участвует в сообществе';

  @override
  String get spaceRecommendationEmpty => 'Нет активных кампаний рекомендаций';

  @override
  String get spaceRecommendationReceive => 'Рекомендации сообществ';

  @override
  String get spaceRecommendationReceiveHint =>
      'Разрешить принятым контактам отправлять карточки сообществ. При отключении новые рекомендации будут молча отбрасываться.';

  @override
  String get spaceRoleLabel => 'Роль в сообществе';

  @override
  String get spaceRoleOwner => 'Владелец';

  @override
  String get spaceRoleAdmin => 'Администратор';

  @override
  String get spaceRoleMember => 'Участник';

  @override
  String get spaceMemberMuted => 'Публикации запрещены до снятия ограничения';

  @override
  String get spaceMemberMute => 'Запретить публикации';

  @override
  String get spaceMemberUnmute => 'Разрешить публикации';

  @override
  String get spaceMemberPromote => 'Сделать администратором';

  @override
  String get spaceMemberDemote => 'Сделать участником';

  @override
  String get spaceMemberRemove => 'Исключить из сообщества';

  @override
  String spaceMemberRemoveConfirm(String member) {
    return 'Исключить $member и сменить ключи доступа?';
  }

  @override
  String get spaceMemberTransferOwnership => 'Передать владение';

  @override
  String spaceMemberTransferOwnershipConfirm(String member) {
    return 'Передать владение пользователю $member? Вы станете администратором, и вернуть владение сможет только новый владелец.';
  }

  @override
  String get spaceRenameTitle => 'Переименовать сообщество';

  @override
  String get spaceRenameAction => 'Переименовать';

  @override
  String get spaceRenameDenied => 'Нет прав переименовать это сообщество';

  @override
  String get spaceLeave => 'Выйти из сообщества';

  @override
  String get spaceLeaveConfirm =>
      'Вы потеряете доступ к каналам и публикациям. Для оставшихся участников ключи защищённых данных будут сменены.';

  @override
  String get spaceOwnerLeaveHint =>
      'Перед выходом из сообщества передайте владение другому участнику.';

  @override
  String get spaceReplicationTitle => 'Доступность в P2P';

  @override
  String spaceReplicationNeighbors(int count) {
    return 'Распространять через $count ближайших участников';
  }

  @override
  String get spaceReplicationHint =>
      'Больше распространителей повышает доступность без владельца и надёжность восстановления, но расходует больше трафика этого устройства.';

  @override
  String get spaceYou => 'Вы';

  @override
  String get feedEmpty => 'Лента пока пуста';

  @override
  String get feedEmptyHint =>
      'Публикации включённых сообществ появятся здесь в хронологическом порядке.';

  @override
  String get feedPostHide => 'Скрыть из ленты';

  @override
  String get feedPostHidden => 'Публикация скрыта из вашей ленты';

  @override
  String get feedPostUndo => 'Вернуть';

  @override
  String get feedPostHideFailed => 'Не удалось изменить настройку ленты';

  @override
  String get feedFilterTitle => 'Фильтр публикаций';

  @override
  String get feedFilterAll => 'Все';

  @override
  String get feedFilterApply => 'Применить';

  @override
  String get feedFilterEmptyHint => 'Нет публикаций выбранных типов.';

  @override
  String get feedFilterUpdateFailed => 'Не удалось изменить фильтр ленты';

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
  String get notificationReply => 'Ответить';

  @override
  String get notificationReplyHint => 'Сообщение…';

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
  String get chatVoiceHold => 'Удерживайте для записи голосового';

  @override
  String get chatVoiceSlideCancel => 'Проведите для отмены';

  @override
  String get chatVoiceReleaseCancel => 'Отпустите для отмены';

  @override
  String get chatVoiceMicDenied => 'Доступ к микрофону запрещён';

  @override
  String get chatVoiceTooltip => 'Голосовое сообщение';

  @override
  String get chatVnoteTooltip => 'Видео-сообщение';

  @override
  String get stickerTitle => 'Стикеры';

  @override
  String get stickerImport => 'Импорт из фото';

  @override
  String get groupCreateTitle => 'Новый групповой чат';

  @override
  String get groupCreateAction => 'Создать';

  @override
  String get groupOperationFailed =>
      'Не удалось изменить группу. Проверьте сеть и повторите попытку.';

  @override
  String get groupEncrypted => 'Сквозное шифрование включено';

  @override
  String get groupEncryptionPending => 'Ожидается обновление шифрования';

  @override
  String get groupNameHint => 'Название группового чата';

  @override
  String get groupEmpty => 'Пока нет групповых чатов';

  @override
  String get groupNoMessages => 'Пока нет сообщений';

  @override
  String get groupMembersTooltip => 'Участники';

  @override
  String get groupSyncSettingsTooltip => 'Синхронизация чата';

  @override
  String get groupSyncNeighborsTitle => 'Синхронизация чата';

  @override
  String groupSyncNeighborsLabel(int count) {
    return 'XOR-соседей: $count';
  }

  @override
  String get groupSyncNeighborsHint =>
      'Со сколькими ближайшими по XOR участниками это устройство связывается для синхронизации истории. Больше соседей повышает надёжность, но расходует больше трафика. Настройка локальна для этого устройства.';

  @override
  String get groupRenameTitle => 'Переименовать группу';

  @override
  String get groupRenameAction => 'Переименовать';

  @override
  String get groupRenameDenied => 'Нет прав переименовать эту группу';

  @override
  String groupMembers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count участников',
      few: '$count участника',
      one: '1 участник',
    );
    return '$_temp0';
  }

  @override
  String get groupReply => 'Ответить';

  @override
  String get groupAddMember => 'Добавить';

  @override
  String get groupMute => 'Заглушить';

  @override
  String get groupUnmute => 'Разглушить';

  @override
  String get groupPromote => 'Сделать админом';

  @override
  String get groupDemote => 'Снять админа';

  @override
  String get groupRemove => 'Убрать из группы';

  @override
  String get groupLeave => 'Выйти из группы';

  @override
  String get groupLeaveConfirm =>
      'Вы перестанете получать сообщения этой группы.';

  @override
  String get groupNoContactsToAdd => 'Нет контактов для добавления';

  @override
  String get groupAttachImage => 'Отправить картинку';

  @override
  String get groupSendSticker => 'Отправить стикер';

  @override
  String get groupImageOnly => 'Выберите файл изображения';

  @override
  String get groupImageTooLarge => 'Картинка слишком большая для инлайна';

  @override
  String get groupVnoteRecord => 'Записать кружок';

  @override
  String get groupVoiceRecord => 'Записать голосовое';

  @override
  String get groupVoiceStop => 'Остановить и отправить';

  @override
  String get groupVoiceMessage => 'Голосовое сообщение';

  @override
  String get groupVoiceTooLong =>
      'Голосовое слишком длинное для отправки в группу';

  @override
  String get reactorsTitle => 'Реакции';

  @override
  String get reactorsYou => 'Вы';

  @override
  String get settingsShowReactions => 'Показывать реакции';

  @override
  String get settingsShowReactionsHint =>
      'Чипы реакций под сообщениями и быстрые реакции в меню сообщения. Скрытие локально — реакции продолжают синхронизироваться.';

  @override
  String get stickerEmpty => 'Пока нет стикеров — импортируйте свои картинки';

  @override
  String get stickerSharePack => 'Поделиться паком';

  @override
  String get stickerPackTitle => 'Пак стикеров';

  @override
  String get stickerPackDownload => 'Скачать';

  @override
  String get stickerPackInstall => 'Установить';

  @override
  String stickerImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Добавлено $count стикеров',
      few: 'Добавлено $count стикера',
      one: 'Добавлен 1 стикер',
    );
    return '$_temp0';
  }

  @override
  String get stickerPackChooseTarget => 'В какой пак добавить?';

  @override
  String get stickerPackNew => 'Новый пак…';

  @override
  String get stickerPackNameHint => 'Название пака';

  @override
  String get stickerPackRename => 'Переименовать';

  @override
  String get stickerPackDelete => 'Удалить пак';

  @override
  String stickerPackDeleteConfirm(String name) {
    return 'Удалить «$name» и его стикеры?';
  }

  @override
  String get stickerPackUnsigned => 'Пак без подписи';

  @override
  String stickerPackSignedBy(String author) {
    return 'Подписал $author';
  }

  @override
  String get stickerPackBadSignature =>
      'Подпись не сошлась — пак не установлен';

  @override
  String get chatVnoteDenied => 'Нет доступа к камере или микрофону';

  @override
  String get chatVoiceRecordFailed =>
      'Не удалось записать — попробуйте ещё раз';

  @override
  String get chatVoiceTranscribe => 'Расшифровать';

  @override
  String get chatVoiceTranscribing => 'Расшифровка…';

  @override
  String get chatVoiceTranscribeFailed => 'Не удалось расшифровать';

  @override
  String get chatFileSave => 'Сохранить';

  @override
  String get chatFileSaved => 'Файл сохранён';

  @override
  String get chatFileSaveFailed => 'Не удалось сохранить файл';

  @override
  String get chatFileTooLarge => 'Файл слишком большой';

  @override
  String get chatFileUnreadable => 'Не удалось прочитать файл';

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
  String get settingsChatPageSize => 'Сообщений на страницу';

  @override
  String get settingsChatPageSizeHint =>
      'Сколько последних сообщений загружает чат; более ранние — по запросу';

  @override
  String get settingsCloseToTray => 'Сворачивать в трей';

  @override
  String get settingsCloseToTrayHint =>
      'Закрытие окна прячет его в системный трей и не выключает приложение — сообщения и уведомления продолжают приходить. Выключено — закрытие завершает работу.';

  @override
  String get navStorage => 'Хранилище';

  @override
  String get navMenuTiles => 'Меню';

  @override
  String get cloudTitle => 'Личное облако';

  @override
  String get cloudUnavailable =>
      'Облачная синхронизация станет доступна после запуска узла';

  @override
  String get cloudEmpty => 'Ваше облако пусто';

  @override
  String get cloudEmptyHint =>
      'Файлы и заметки шифруются локально и реплицируются только между вашими связанными устройствами.';

  @override
  String get cloudAdd => 'Добавить в облако';

  @override
  String get cloudAddFile => 'Добавить файл';

  @override
  String get cloudAddNote => 'Новая заметка';

  @override
  String get cloudImported => 'Файл добавлен в облако';

  @override
  String get cloudImportFailed => 'Не удалось импортировать файл';

  @override
  String get cloudLoadFailed => 'Не удалось загрузить индекс облака';

  @override
  String get cloudReplication => 'Хранить на этом устройстве';

  @override
  String get cloudModeAll => 'Всё';

  @override
  String get cloudModeSelected => 'Выбранное';

  @override
  String get cloudModeIndex => 'Только индекс';

  @override
  String get cloudModeAllHint =>
      'Автоматически загружать всё содержимое облака';

  @override
  String get cloudModeSelectedHint =>
      'Автоматически загружать выбранные элементы';

  @override
  String get cloudModeIndexHint =>
      'Показывать индекс, содержимое загружать по запросу';

  @override
  String get cloudLocal => 'на устройстве';

  @override
  String get cloudRemote => 'в облаке';

  @override
  String cloudReplicas(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count проверенных копий',
      few: '$count проверенные копии',
      one: '1 проверенная копия',
      zero: 'нет проверенных копий',
    );
    return '$_temp0';
  }

  @override
  String get cloudDownload => 'Загрузить на устройство';

  @override
  String get cloudShare => 'Поделиться с контактом';

  @override
  String get cloudShareTitle => 'Поделиться с';

  @override
  String get cloudNoContacts => 'Нет принятых контактов для отправки';

  @override
  String get cloudShared => 'Файл отправлен';

  @override
  String get cloudShareFailed => 'Не удалось отправить файл';

  @override
  String get cloudPublicLink => 'Приватная ссылка';

  @override
  String get cloudPublicCopy => 'Копировать ссылку';

  @override
  String get cloudPublicCopied => 'Приватная ссылка скопирована';

  @override
  String get cloudPublicRevoke => 'Отозвать ссылку';

  @override
  String get cloudPublicRevoked =>
      'Ссылка отозвана; уже скачанные копии удалить нельзя';

  @override
  String get cloudPublicFailed => 'Не удалось создать приватную ссылку';

  @override
  String get cloudPublicImport => 'Открыть приватную ссылку';

  @override
  String get cloudPublicPasteHint => 'Вставьте ссылку xveil://cloud';

  @override
  String get cloudPublicOpenFailed =>
      'Не удалось открыть или проверить приватную ссылку';

  @override
  String get cloudSelect => 'Хранить выбранным';

  @override
  String get cloudUnselect => 'Не хранить выбранным';

  @override
  String get cloudVerify => 'Проверить и восстановить';

  @override
  String get cloudVerifyOk => 'Локальные файлы облака прошли проверку';

  @override
  String cloudRepairStarted(int count) {
    return 'Запрошено восстановление повреждённых файлов: $count';
  }

  @override
  String get cloudDelete => 'Удалить';

  @override
  String get cloudDeleteTitle => 'Удалить из облака?';

  @override
  String get cloudDeleteBody =>
      'Элемент исчезнет со всех связанных устройств. Это действие нельзя отменить.';

  @override
  String get cloudNoteNew => 'Новая заметка';

  @override
  String get cloudNoteEdit => 'Редактировать заметку';

  @override
  String get cloudNoteTitleHint => 'Название';

  @override
  String get cloudNoteBodyHint => 'Напишите приватную заметку…';

  @override
  String get cloudNoteSave => 'Сохранить';

  @override
  String get cloudNoteSaved => 'Заметка сохранена';

  @override
  String get cloudNoteLoadFailed =>
      'Не удалось загрузить или проверить заметку';

  @override
  String get cloudNoteSaveFailed => 'Не удалось сохранить заметку';

  @override
  String get cloudNoteTitleRequired => 'Введите название';

  @override
  String get cloudNoteTooLarge => 'Заметка слишком большая (максимум 1 МиБ)';

  @override
  String get cloudNoteConflictTitle =>
      'Заметка изменилась на другом устройстве';

  @override
  String get cloudNoteConflictBody =>
      'Сверьте текущую облачную версию с черновиком и объедините их перед сохранением.';

  @override
  String get cloudNoteRemoteVersion => 'Текущая версия в облаке';

  @override
  String get cloudNoteYourDraft => 'Ваш объединённый черновик';

  @override
  String get cloudNoteUseRemote => 'Использовать версию из облака';

  @override
  String get cloudNoteSaveMerged => 'Сохранить объединённую версию';

  @override
  String cloudNoteBranches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Сохранено $count офлайн-версий',
      few: 'Сохранены $count офлайн-версии',
      one: 'Сохранена 1 версия',
    );
    return '$_temp0';
  }

  @override
  String get cloudNoteReviewBranches => 'Сверить версии';

  @override
  String cloudNoteVersion(int number) {
    return 'Сохранённая версия $number';
  }

  @override
  String get cloudNoteBranchesUnavailable =>
      'Перед объединением загрузите все сохранённые версии';

  @override
  String get cloudNoteMergeReady =>
      'Объединение подготовлено — сохраните заметку, чтобы разрешить все версии';

  @override
  String get settingsCatAccount => 'Личности и аккаунт';

  @override
  String get settingsCatAccountHint =>
      'Смена, добавление, управление, анонимность';

  @override
  String get settingsCatPrivacy => 'Приватность';

  @override
  String get settingsCatPrivacyHint => 'P2P-политика, запросы подписи';

  @override
  String get settingsCatChats => 'Чаты и уведомления';

  @override
  String get settingsCatChatsHint =>
      'Уведомления, фоновая доставка, размер страницы';

  @override
  String get settingsCatData => 'Данные и хранилище';

  @override
  String get settingsCatDataHint => 'Размер контейнера, компакция, файлы';

  @override
  String get settingsCatAppearanceHint => 'Язык, панель папок';

  @override
  String get searchHint => 'Поиск';

  @override
  String get searchMessagesSection => 'Сообщения';

  @override
  String get searchNoResults => 'Ничего не найдено';

  @override
  String get chatMsgPin => 'Закрепить';

  @override
  String get chatMsgUnpin => 'Открепить';

  @override
  String get chatPinnedLabel => 'Закреплённое сообщение';

  @override
  String get savedMessages => 'Избранное';

  @override
  String get savedNoteHint => 'Заметка себе…';

  @override
  String get chatFormatTooltip => 'Форматирование';

  @override
  String get chatFormatBold => 'Жирный';

  @override
  String get chatFormatItalic => 'Курсив';

  @override
  String get chatFormatUnderline => 'Подчёркнутый';

  @override
  String get chatFormatStrike => 'Зачёркнутый';

  @override
  String get chatFormatCode => 'Код';

  @override
  String get chatFormatSpoiler => 'Спойлер';

  @override
  String get chatFormatQuote => 'Цитата';

  @override
  String get chatLinkCopied => 'Ссылка скопирована';

  @override
  String get chatCodeCopied => 'Код скопирован';

  @override
  String get linkDialogTitle => 'Открыть ссылку?';

  @override
  String get linkOpen => 'Открыть';

  @override
  String get linkCopy => 'Копировать';

  @override
  String get linkOpenFailed => 'Не удалось открыть ссылку';

  @override
  String get p2pSelectedTitle => 'Избранные контакты';

  @override
  String get p2pSelectedHint =>
      'Кому разрешён прямой P2P при политике «Только выбранные». Включите тумблер, чтобы разрешить; выключено — по глобальной политике.';

  @override
  String get p2pSelectedEmpty => 'Пока нет принятых контактов';

  @override
  String get trayShow => 'Показать';

  @override
  String get trayHide => 'Скрыть';

  @override
  String get trayIdentities => 'Личности';

  @override
  String get trayLock => 'Заблокировать';

  @override
  String get trayQuit => 'Выход';

  @override
  String trayUnread(String count) {
    return 'Непрочитанных: $count';
  }

  @override
  String get chatListDelete => 'Удалить чат';

  @override
  String get chatDeleteChatTitle => 'Удалить этот чат?';

  @override
  String get chatDeleteChatBody =>
      'Переписка и все сообщения удаляются с этого устройства. Собеседник не уведомляется.';

  @override
  String get chatDeleteNotifyPeer => 'Уведомить собеседника';

  @override
  String get chatDeletedByPeer => 'Собеседник удалил этот чат у себя';

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
  String get chatMenuRetention => 'Автоудаление';

  @override
  String get retentionUnlimited => 'Никогда';

  @override
  String get retention7 => 'Через 1 неделю';

  @override
  String get retention30 => 'Через 1 месяц';

  @override
  String get retention90 => 'Через 3 месяца';

  @override
  String get retention365 => 'Через 1 год';

  @override
  String get retentionCustom => 'Произвольно…';

  @override
  String retentionCustomN(int days) {
    return 'Произвольно ($days дн.)';
  }

  @override
  String get retentionCustomTitle => 'Удалять через (дней)';

  @override
  String get retentionDaysSuffix => 'дн.';

  @override
  String get retentionApplied => 'Старые сообщения будут удалены';

  @override
  String get chatMenuRename => 'Переименовать';

  @override
  String get chatRenameTitle => 'Локальное имя';

  @override
  String get chatMenuPin => 'Закрепить сверху';

  @override
  String get chatMenuUnpin => 'Открепить';

  @override
  String get chatMenuMute => 'Отключить уведомления';

  @override
  String get chatMenuUnmute => 'Включить уведомления';

  @override
  String get chatMenuMarkRead => 'Пометить прочитанным';

  @override
  String get chatMenuArchive => 'В архив';

  @override
  String get chatMenuUnarchive => 'Из архива';

  @override
  String get chatsArchiveSection => 'Архив';

  @override
  String get chatMenuFolders => 'Папки';

  @override
  String get chatsFolderAll => 'Все';

  @override
  String get chatsFolderNew => 'Новая папка';

  @override
  String get chatsFolderName => 'Название папки';

  @override
  String get chatsFolderRename => 'Переименовать папку';

  @override
  String get chatsFolderDelete => 'Удалить папку';

  @override
  String get chatsFolderUnnamed => 'Без названия';

  @override
  String get chatsFolderEmpty => 'В этой папке нет чатов';

  @override
  String get chatsFolderNoneYet => 'Папок пока нет';

  @override
  String get chatMsgRequestSignature => 'Запросить подпись';

  @override
  String get chatSignatureRequested => 'Подпись запрошена';

  @override
  String get chatSignaturePending => 'Ожидание подписи автора';

  @override
  String get chatSignatureVerified => 'Авторство подтверждено';

  @override
  String get chatSignatureRefused => 'Автор отказался подписывать';

  @override
  String get chatSignatureFailed => 'Подпись не прошла проверку';

  @override
  String signatureAskTitle(String who) {
    return '$who просит подтвердить, что сообщение ниже написали вы';
  }

  @override
  String get signatureAskConfirm => 'Подписать';

  @override
  String get settingsSignaturePolicy => 'Запросы подписи';

  @override
  String get settingsSignaturePolicyHint =>
      'Как отвечать, когда контакт просит подтвердить, что вы написали сообщение';

  @override
  String get settingsApiTitle => 'API автоматизации';

  @override
  String get settingsApiHint =>
      'Выкл. Локальный REST API для ботов/скриптов (только localhost)';

  @override
  String get settingsApiReadOnly => 'Только чтение';

  @override
  String get settingsApiReadOnlyHint =>
      'Только чтение и события — запись (отправка, звонки) запрещена';

  @override
  String get settingsApiAddToken => 'Добавить токен';

  @override
  String get settingsApiTokenName => 'Имя токена (напр. бот)';

  @override
  String get settingsApiRevoke => 'Отозвать';

  @override
  String get settingsApiToken => 'Токен API';

  @override
  String get settingsApiCopyToken => 'Копировать токен';

  @override
  String get settingsApiRegenerate => 'Сменить токен';

  @override
  String get settingsApiTokenCopied => 'Токен скопирован';

  @override
  String get settingsCommunication => 'Связь';

  @override
  String get settingsP2PPolicy => 'Политика P2P';

  @override
  String get settingsP2PPolicyHint =>
      'Разрешает прямой транспорт для звонков, больших медиа, файлов и обмена между устройствами, когда обе стороны согласны.';

  @override
  String get settingsP2PPolicyAnonymousHint =>
      'P2P отключён, пока эта личность использует анонимную маршрутизацию.';

  @override
  String get p2pPolicyAllowAll => 'Разрешить всем';

  @override
  String get p2pPolicyContacts => 'Разрешить контактам';

  @override
  String get p2pPolicySelected => 'Только указанным';

  @override
  String get p2pPolicyDenied => 'Запретить';

  @override
  String get signaturePolicyAsk => 'Спрашивать каждый раз';

  @override
  String get signaturePolicyAuto => 'Подписывать автоматически';

  @override
  String get signaturePolicyRefuse => 'Всегда отказывать';

  @override
  String get settingsKeepNodeBackground => 'Работать в фоне';

  @override
  String get settingsKeepNodeBackgroundHint =>
      'Продолжает получать сообщения, когда приложение свёрнуто или экран погашен. Показывает постоянное уведомление и расходует больше батареи.';

  @override
  String get settingsFolderPanel => 'Панель папок';

  @override
  String get settingsFolderPanelHint => 'Где показывать папки чатов';

  @override
  String get folderPanelLeft => 'Слева (выдвижная)';

  @override
  String get folderPanelRight => 'Справа (выдвижная)';

  @override
  String get folderPanelTop => 'Сверху (полоса)';

  @override
  String get mute30m => '30 минут';

  @override
  String get mute1h => '1 час';

  @override
  String get mute8h => '8 часов';

  @override
  String get mute3d => '3 дня';

  @override
  String get mute1w => 'Неделя';

  @override
  String get mute1mo => 'Месяц';

  @override
  String get muteForever => 'Пока не включу обратно';

  @override
  String get muteCustom => 'Своё время…';

  @override
  String get muteCustomTitle => 'На сколько отключить?';

  @override
  String get muteHoursSuffix => 'часов';

  @override
  String get chatMenuCommunicationSettings => 'Настройки общения';

  @override
  String get chatMenuP2P => 'Связь P2P';

  @override
  String get contactP2PFollowGlobal => 'Следовать общей политике';

  @override
  String get contactP2PAllow => 'Разрешить';

  @override
  String get contactP2PDeny => 'Запретить';

  @override
  String get chatMenuAllowPeerDelete => 'Разрешить собеседнику удалять у меня';

  @override
  String get chatMenuAllowPeerDeleteHint =>
      'Когда включено, его удаление или очистка убирают и вашу копию. Выключено — ваши копии остаются, даже если он удалил у всех.';

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
  String get chatMsgHistory => 'История изменений';

  @override
  String get chatHistoryEmpty => 'Прежних версий нет';

  @override
  String get chatHistoryOriginal => 'Оригинал';

  @override
  String get chatHistoryEdited => 'Изменено';

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
  String get msgInfoSize => 'Размер';

  @override
  String get msgInfoAuthor => 'Автор';

  @override
  String get msgInfoSeq => 'Порядковый номер';

  @override
  String get msgInfoEdited => 'Изменено';

  @override
  String get msgInfoYes => 'Да';

  @override
  String get chatMsgCopyMeta => 'Скопировать с метаданными';

  @override
  String get chatMsgReply => 'Ответить';

  @override
  String get chatMsgForward => 'Переслать';

  @override
  String get chatMsgSelect => 'Выбрать';

  @override
  String get chatMsgDelete => 'Удалить';

  @override
  String get chatMsgDeleteTitle => 'Удалить сообщения?';

  @override
  String get chatReplyingTo => 'Ответ на';

  @override
  String get chatQuoteUnavailable => 'Цитируемое сообщение';

  @override
  String get chatFileLabel => 'Файл';

  @override
  String get chatForwarded => 'Переслано';

  @override
  String get chatYou => 'вы';

  @override
  String chatForwardedFrom(String name) {
    return 'Переслано от $name';
  }

  @override
  String get chatForwardTo => 'Переслать в';

  @override
  String get chatForwardNoTargets => 'Нет принятых контактов для пересылки';

  @override
  String chatMsgDeleteSelectedBody(int count) {
    return 'Удалить $count выбранных сообщений?';
  }

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
  String get settingsStorageAutoCompact => 'Авто-сжатие при разблокировке';

  @override
  String get settingsStorageAutoCompactBody =>
      'Сжимать автоматически, когда контейнер раздувается. Включайте ТОЛЬКО если в этом контейнере нет других скрытых личностей — сжатие сохраняет лишь разблокированное пространство.';

  @override
  String get settingsStorageLeanPadding => 'Экономить место';

  @override
  String get settingsStorageLeanPaddingBody =>
      'Включено по умолчанию: будущие записи используют меньше padding, поэтому контейнер растет намного меньше. Отключите для более сильной маскировки изменения размера. Применится после переоткрытия приложения.';

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
  String get settingsFiles => 'Файлы';

  @override
  String get settingsFilesHint => 'Лимит авто-загрузки и заблокированные типы';

  @override
  String get fileSettingsTitle => 'Загрузка файлов';

  @override
  String get fileAutoLimit => 'Авто-загрузка до';

  @override
  String get fileAutoLimitHint =>
      'Файлы крупнее — по запросу: вы решаете, загружать ли.';

  @override
  String get fileAlwaysAsk => 'Всегда спрашивать';

  @override
  String get fileBlockedTitle => 'Не загружать автоматически эти типы';

  @override
  String get fileBlockedHint =>
      'Такие всегда ждут вашего нажатия (напр. apk, exe), даже маленькие.';

  @override
  String get fileAddType => 'Добавить тип';

  @override
  String get fileTypeHint => 'Расширение, напр. apk';

  @override
  String get fileDownloadTitle => 'Загрузить файл';

  @override
  String get fileSaveEncrypted => 'Зашифрованное хранилище';

  @override
  String get fileSaveEncryptedHint =>
      'Хранится в приложении, зашифрован на диске';

  @override
  String get fileSavePlain => 'Сохранить на диск (без шифрования)';

  @override
  String get fileSavePlainHint => 'Обычный файл по вашему выбору — без защиты';

  @override
  String get fileSavePlainWarn =>
      'Файл будет сохранён НЕЗАШИФРОВАННЫМ на диске. Его сможет прочитать любой, у кого есть доступ к устройству. Продолжить?';

  @override
  String get fileSavePlainConfirm => 'Сохранить без шифрования';

  @override
  String get fileLargeMode => 'Большие файлы';

  @override
  String get fileLargeModeHint =>
      'Когда загружаете файл, не помещающийся в скрытый том';

  @override
  String get fileLargeModeAsk => 'Спрашивать каждый раз';

  @override
  String get fileCustomSize => 'Свой размер…';

  @override
  String get fileSizeMb => 'Размер в МБ';

  @override
  String get fileDownloading => 'Загрузка';

  @override
  String get fileRequestingResend => 'Запрашиваем файл у отправителя…';

  @override
  String get fileResuming => 'Догрузка…';

  @override
  String get fileGoneAskResend =>
      'У отправителя больше нет этого файла — попросите отправить его заново.';

  @override
  String get fileReofferFailed =>
      'Не удалось получить файл — попросите отправителя переслать его.';

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
      'Запускать узлы всех личностей сразу: переключение мгновенно, никто не уходит в оффлайн (по умолчанию). Выключите для строгой несвязываемости — всегда-онлайн личности можно связать по общему устройству. Чувствительные личности отмечайте для анонимной маршрутизации.';

  @override
  String get settingsPhraseStatusTitle => 'Фраза восстановления';

  @override
  String get settingsPhraseBackedHint =>
      'Личность выведена из фразы восстановления — записанная вами фраза восстанавливает её.';

  @override
  String get settingsPhraseNoneHint =>
      'Личность создана без фразы восстановления — восстановить её по фразе нельзя. Берегите данные приложения другими средствами.';

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
  String get vpnTitle => 'Системный VPN';

  @override
  String get vpnHint =>
      'Маршрутизирует трафик устройства через выход veil. VPN сам запускает локальный SOCKS5-транспорт; отдельный переключатель SOCKS5 нужен только для прямого доступа к прокси.';

  @override
  String get vpnStatusRunning => 'Пакетный туннель активен';

  @override
  String get vpnStatusStarting => 'Пакетный туннель запускается…';

  @override
  String get vpnStatusStopping => 'Пакетный туннель останавливается…';

  @override
  String get vpnStatusStopped => 'Пакетный туннель остановлен';

  @override
  String get vpnStatusError => 'Ошибка пакетного туннеля';

  @override
  String get vpnStatusUnsupported =>
      'Пакетный туннель недоступен в этой сборке';

  @override
  String get vpnUnsupportedDetail =>
      'В этой сборке платформы ещё нет нативного packet-tunnel engine. SOCKS5 доступен, но xVeil не будет ложно показывать VPN активным.';

  @override
  String get vpnRouteMode => 'Выбор трафика';

  @override
  String get vpnRouteAll => 'Весь трафик';

  @override
  String get vpnRouteInclude => 'Только выбранные подсети';

  @override
  String get vpnRouteExclude => 'Всё, кроме выбранных подсетей';

  @override
  String get vpnApplicationRouting => 'Приложения через VPN';

  @override
  String get vpnApplicationAll => 'Все приложения';

  @override
  String get vpnApplicationOnlySelected => 'Только выбранные приложения';

  @override
  String get vpnApplicationOnlySelectedHint =>
      'Только выбранные Android-приложения входят в туннель; остальные используют обычную сеть.';

  @override
  String get vpnApplicationUnsupported =>
      'Маршрутизация по приложениям доступна на Android. Обычный VPN на iOS/macOS не сообщает исходное приложение; для Linux и Windows потребуется отдельный процессный backend.';

  @override
  String get vpnApplicationSelect => 'Выбрать приложения';

  @override
  String get vpnApplicationNoneSelected => 'Выберите хотя бы одно приложение';

  @override
  String vpnApplicationSelectedCount(Object count) {
    return 'Выбрано приложений: $count';
  }

  @override
  String get vpnApplicationPickerTitle => 'Приложения через VPN';

  @override
  String get vpnApplicationPickerEmpty =>
      'Android не показывает доступных запускаемых приложений.';

  @override
  String get vpnApplicationSearchEmpty =>
      'По этому запросу приложения не найдены.';

  @override
  String vpnApplicationLoadError(Object error) {
    return 'Не удалось получить список приложений: $error';
  }

  @override
  String get oproxyCatalogTitle => 'Выходы oproxy';

  @override
  String get oproxyAddTitle => 'Добавить oproxy';

  @override
  String get oproxyEditTitle => 'Изменить oproxy';

  @override
  String get oproxyName => 'Название';

  @override
  String get oproxyEmpty => 'Сначала добавьте хотя бы один выход oproxy.';

  @override
  String get oproxyNoDefault => 'Дефолтный oproxy не настроен';

  @override
  String oproxyDefaultSummary(Object count) {
    return 'Дефолтная цепочка: выходов — $count';
  }

  @override
  String get oproxyDefaultOrderTitle => 'Дефолтный oproxy и запасные';

  @override
  String get oproxyDefaultOrderAction => 'Настроить основной и запасные';

  @override
  String get oproxyPrimary => 'Основной oproxy';

  @override
  String get oproxyUseDefault => 'Использовать дефолтную цепочку';

  @override
  String get oproxyVpnRouteTitle => 'Цепочка oproxy основного VPN';

  @override
  String oproxyRouteSummary(Object fallbacks, Object primary) {
    return '$primary + запасных: $fallbacks';
  }

  @override
  String get oproxyAutoFailover => 'Автосмена oproxy';

  @override
  String get oproxyAutoFailoverHint =>
      'Новые соединения пробуют следующий выход, если основной не может открыть маршрут. Работающие соединения остаются на текущем выходе.';

  @override
  String get oproxyApplicationRoutesTitle => 'Маршруты приложений через oproxy';

  @override
  String get oproxyApplicationRoutesEmpty =>
      'Для этого VPN не выбраны приложения.';

  @override
  String oproxyApplicationRoutesCount(Object count) {
    return 'Переопределений для приложений: $count';
  }

  @override
  String get vpnIncludedCidrs => 'Включённые подсети';

  @override
  String get vpnExcludedCidrs => 'Исключённые подсети';

  @override
  String get vpnCidrsHint =>
      'Один IPv4- или IPv6-CIDR в строке, например 10.20.0.0/16';

  @override
  String get vpnCidrsInvalid =>
      'Каждый маршрут должен быть корректным IPv4- или IPv6-CIDR';

  @override
  String get vpnIncludedCountries => 'Страны через VPN (GeoIP)';

  @override
  String get vpnExcludedCountries => 'Страны в обход VPN (GeoIP)';

  @override
  String get vpnCountriesHint =>
      'Двухбуквенные коды через пробел или запятую, например KZ, RU. Используется встроенный снимок IPdeny; GeoIP приблизителен.';

  @override
  String get vpnCountriesInvalid =>
      'Используйте двухбуквенные коды стран, например KZ';

  @override
  String get vpnRouteDns => 'Маршрутизировать DNS через VPN';

  @override
  String get vpnRouteDnsHint =>
      'Назначить выбранные DNS-серверы интерфейсу туннеля, чтобы не допустить утечек резолвера.';

  @override
  String get vpnDnsServers => 'DNS-серверы';

  @override
  String get vpnDnsHint => 'Один IPv4- или IPv6-адрес в строке';

  @override
  String get vpnDnsInvalid => 'Каждый DNS-сервер должен быть IP-адресом';

  @override
  String get vpnAllowLan => 'Разрешить локальную сеть';

  @override
  String get vpnAllowLanHint =>
      'Оставить приватные и link-local подсети доступными в обход туннеля.';

  @override
  String get vpnMtu => 'MTU туннеля';

  @override
  String get vpnMtuHint =>
      '1280–9000; 1280 безопасно для маршрутов IPv4 и IPv6';

  @override
  String get vpnMtuInvalid => 'MTU должен быть от 1280 до 9000';

  @override
  String get vpnNeedsProxy =>
      'Сначала выберите корректный выходной узел. VPN запустит SOCKS5-транспорт автоматически.';

  @override
  String get vpnStart => 'Запустить VPN';

  @override
  String get vpnStop => 'Остановить VPN';

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
  String get nodesAddChoiceTitle => 'Какой узел добавить?';

  @override
  String get nodesAddExisting => 'Добавить готовый узел';

  @override
  String get nodesAddExistingHint =>
      'Сохранить уже установленный узел с известным node id.';

  @override
  String get nodesAddExistingFieldsHint =>
      'Обязательно: название и Node ID. SSH-поля необязательны и нужны только для управления сервером. Пароль или ключ можно сохранить ниже в зашифрованном хранилище xVeil.';

  @override
  String get nodesBootstrapNew => 'Забутстрапить новый узел';

  @override
  String get nodesBootstrapNewHint =>
      'Установить veil на Linux-сервер; node id сохранится автоматически.';

  @override
  String get nodesBootstrapFieldsHint =>
      'Обязательно: название, SSH-хост и SSH-пользователь. Порт по умолчанию — 22. Пароль или ключ можно сохранить ниже; Node ID сохранится после развёртывания.';

  @override
  String get nodesBootstrapContinue => 'Перейти к развёртыванию';

  @override
  String get nodeEdit => 'Изменить узел';

  @override
  String get nodeLabelLabel => 'Название *';

  @override
  String get nodeLabelRequired => 'Введите название';

  @override
  String get nodeIdLabel => 'Node ID (64 hex, необязательно)';

  @override
  String get nodeIdRequiredLabel => 'Node ID (64 hex) *';

  @override
  String get nodeIdHintText =>
      'veil-id узла — чтобы маршрутизировать через него ваш трафик.';

  @override
  String get nodeIdInvalid => 'Нужен node id из 64 hex-символов';

  @override
  String get nodeIdRequired => 'Укажите 64-символьный node id готового узла';

  @override
  String get nodeSshHostLabel => 'SSH-хост (необязательно)';

  @override
  String get nodeSshHostRequiredLabel => 'SSH-хост *';

  @override
  String get nodeSshHostRequired => 'Укажите SSH-хост нового сервера';

  @override
  String get nodeSshPortLabel => 'SSH-порт (по умолчанию 22)';

  @override
  String get nodeSshUserLabel => 'SSH-пользователь (необязательно)';

  @override
  String get nodeSshUserRequiredLabel => 'SSH-пользователь *';

  @override
  String get nodeSshUserRequired => 'Укажите SSH-пользователя нового сервера';

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
  String get nodeManage => 'Управление узлом';

  @override
  String get nodeInventory => 'Проверить установку и состояние';

  @override
  String get nodeInstallUpdate => 'Установить или обновить ПО';

  @override
  String get nodeServices => 'Сервисы';

  @override
  String get nodeAdvancedConfig => 'Расширенная конфигурация';

  @override
  String get nodeServiceStatus => 'Состояние';

  @override
  String get nodeServiceStart => 'Запустить';

  @override
  String get nodeServiceStop => 'Остановить';

  @override
  String get nodeServiceRestart => 'Перезапустить';

  @override
  String get nodeServiceEnable => 'Включить и запустить';

  @override
  String get nodeServiceDisable => 'Остановить и отключить';

  @override
  String get nodeConfigLoad => 'Загрузить с сервера';

  @override
  String get nodeConfigApply => 'Проверить, применить и перезапустить';

  @override
  String get nodeConfigNotLoaded =>
      'Перед редактированием загрузите текущий конфиг с сервера.';

  @override
  String get nodeUninstallSoftware => 'Удалить ПО (сохранить данные)';

  @override
  String get nodeDebootstrap => 'Дебутстрап ноды (стереть всё)';

  @override
  String get nodeDebootstrapConfirm =>
      'Это навсегда удалит удалённую личность ноды, состояние, конфиги и всё ПО veil/ogate/oproxy. Введите DELETE для продолжения.';

  @override
  String get nodeDebootstrapType => 'Введите DELETE';

  @override
  String get nodeOperationOutput => 'Вывод сервера';

  @override
  String get nodeOperationRun => 'Выполнить команду';

  @override
  String get nodeOperationSuccess => 'Операция на сервере завершена';

  @override
  String get nodeSelectServices => 'Выберите сервисы';

  @override
  String get provisionTitle => 'Развёртывание по SSH';

  @override
  String get provisionReleaseSection => 'Релиз veil-cli';

  @override
  String get provisionReleaseTarget => 'Архитектура сервера';

  @override
  String get provisionReleaseTargetX64 => 'x86_64 Linux (переносимый musl)';

  @override
  String get provisionReleaseTargetArm64 => 'ARM64 Linux (переносимый musl)';

  @override
  String get provisionReleaseRefresh => 'Обновить поля с GitHub';

  @override
  String get provisionSourceGithub => 'GitHub-релиз';

  @override
  String get provisionSourceCustom => 'Своя ссылка';

  @override
  String get provisionReleaseLoading => 'Загружаю последний релиз с GitHub…';

  @override
  String provisionReleaseLoaded(String tag) {
    return 'Загружен GitHub-релиз $tag';
  }

  @override
  String provisionReleaseError(String error) {
    return 'Не удалось заполнить с GitHub: $error. Оба значения можно указать вручную.';
  }

  @override
  String get provisionReleaseUrl => 'URL релиза veil-cli';

  @override
  String get provisionReleaseHint =>
      'Заполняется автоматически из официального GitHub-релиза veilnetwork/veil. Для замены выберите «Своя ссылка».';

  @override
  String get provisionCustomReleaseHint =>
      'Укажите прямую HTTPS-ссылку на свой бинарник и его SHA-256 в поле ниже.';

  @override
  String get provisionSha256 => 'SHA-256 для veil-cli';

  @override
  String get provisionSha256Hint =>
      'Обязательно. 64-символьный hex SHA-256, опубликованный вместе с бинарём. Установка на сервере прерывается, если загрузка не совпадает — именно это не даёт подменённому бинарю выполниться от root.';

  @override
  String get provisionRunExit =>
      'Запустить как выходной узел (маршрутизировать через него)';

  @override
  String get provisionComponents => 'Компоненты';

  @override
  String get provisionTransports => 'Входящие транспорты';

  @override
  String get provisionTransportObfs4TcpHint =>
      'Обфусцированный TCP-листенер для устойчивых к блокировкам соединений с пирами.';

  @override
  String get provisionTransportTcpHint =>
      'Обычный TCP-листенер без шифрования на уровне транспорта.';

  @override
  String get provisionTransportTlsHint =>
      'TCP-листенер, защищённый общим TLS-сертификатом ниже.';

  @override
  String get provisionTransportQuicHint =>
      'QUIC-листенер поверх UDP, защищённый общим TLS-сертификатом ниже.';

  @override
  String get provisionTransportWssHint =>
      'Защищённый WebSocket-листенер с общим TLS-сертификатом ниже.';

  @override
  String provisionTransportPort(String transport) {
    return 'Порт $transport';
  }

  @override
  String provisionTransportNetwork(String protocol) {
    return 'Сетевой протокол: $protocol';
  }

  @override
  String get provisionTransportCommon => 'Общие настройки транспортов';

  @override
  String get provisionTransportCommonHint =>
      'Эти значения относятся ко всем выбранным входящим транспортам.';

  @override
  String get provisionAdvertiseHost => 'Публичный хост / IP (необязательно)';

  @override
  String get provisionAdvertiseHostHint =>
      'Один публичный адрес объявляется для всех выбранных транспортов; порт у каждого свой.';

  @override
  String get provisionTlsShared => 'TLS-сертификат';

  @override
  String provisionTlsSharedHint(String transports) {
    return 'Используется для: $transports. Выберите, как предоставить сертификат всем выбранным TLS-транспортам.';
  }

  @override
  String get provisionTlsMode => 'Источник сертификата';

  @override
  String get provisionTlsModeExisting => 'Существующие файлы';

  @override
  String get provisionTlsModeAutomatic => 'Автоматически';

  @override
  String get provisionTlsModeSelfSigned => 'Самоподписанный';

  @override
  String get provisionTlsAutomaticName =>
      'Домен или IP (необязательная замена)';

  @override
  String get provisionTlsAutomaticNameHint =>
      'Оставьте пустым, чтобы использовать публичный хост / IP выше. Для домена выпускается Let\'s Encrypt, для IP — самоподписанный сертификат с IP SAN.';

  @override
  String get provisionTlsLetsEncryptHint =>
      'Сертификат Let\'s Encrypt будет запрошен на сервере. Домен должен указывать на этот сервер, а входящий TCP-порт 80 — быть открыт. Продление настраивается автоматически.';

  @override
  String get provisionTlsIpHint =>
      'Для IP здесь недоступен стандартный сценарий Let\'s Encrypt. На сервере будет создан самоподписанный сертификат с этим IP в SAN.';

  @override
  String get provisionTlsUnknownHint =>
      'Укажите домен или IP здесь либо заполните публичный хост / IP выше.';

  @override
  String get provisionTlsEmail => 'Email аккаунта Let\'s Encrypt';

  @override
  String get provisionTlsAgreeTerms =>
      'Я принимаю условия использования Let\'s Encrypt';

  @override
  String get provisionTlsSelfSignedName => 'Домен или IP в сертификате';

  @override
  String get provisionTlsSelfSignedNameHint =>
      'Значение записывается в DNS- или IP-поле Subject Alternative Name сертификата.';

  @override
  String get provisionTlsSelfSignedDays => 'Срок действия в днях (1–3650)';

  @override
  String get provisionTlsSelfSignedHint =>
      'Клиенты должны явно доверять этому самоподписанному сертификату. Приватный ключ создаётся и остаётся на сервере.';

  @override
  String get provisionTlsCert => 'Путь TLS-сертификата на сервере';

  @override
  String get provisionTlsKey => 'Путь приватного TLS-ключа на сервере';

  @override
  String get provisionTlsCa => 'Путь TLS CA на сервере (необязательно)';

  @override
  String provisionComponentUrl(String component) {
    return 'URL релиза $component';
  }

  @override
  String provisionComponentSha(String component) {
    return 'SHA-256 для $component';
  }

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
  String get provisionInvalidConfig =>
      'Проверьте обязательные поля релиза, транспортов, портов и TLS';

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
      'Введённые здесь данные используются один раз. Сохранённые реквизиты меняются в карточке узла.';

  @override
  String get sshCredentialsTitle => 'SSH-аутентификация';

  @override
  String get sshSavedPasswordLabel => 'Сохранённый SSH-пароль (необязательно)';

  @override
  String get sshSavedPasswordHint =>
      'Оставьте поле пустым, чтобы удалить сохранённый пароль.';

  @override
  String get sshCredentialsEncryptedHint =>
      'Пароль и приватный ключ хранятся только внутри зашифрованного контейнера xVeil.';

  @override
  String get sshCredentialsEndpointCleared =>
      'SSH-адрес изменён — сохранённые пароль и ключ очищены для безопасности.';

  @override
  String get sshGenerateEd25519 => 'Сгенерировать ключ Ed25519';

  @override
  String get sshRegenerateEd25519 => 'Сгенерировать новый ключ Ed25519';

  @override
  String get sshSavedEd25519Title => 'Сохранённый ключ Ed25519';

  @override
  String get sshPublicKeyLabel =>
      'Добавьте эту строку в ~/.ssh/authorized_keys на сервере:';

  @override
  String get sshCopyPublicKey => 'Копировать публичный ключ';

  @override
  String get sshPublicKeyCopied => 'Публичный ключ скопирован';

  @override
  String get sshRemoveSavedKey => 'Удалить сохранённый ключ';

  @override
  String get sshUseSavedKeyHint =>
      'Оставьте поле пустым, чтобы использовать сохранённый ключ Ed25519.';

  @override
  String get sshOtherKeyLabel => 'Другой приватный ключ (PEM, только сейчас)';

  @override
  String get sshCredentialRequired => 'Введите пароль или приватный ключ';

  @override
  String get sshCredentialsSaving => 'Сохранение…';

  @override
  String sshCredentialsSaveFailed(String error) {
    return 'Не удалось сохранить SSH-реквизиты: $error';
  }

  @override
  String sshKeyGenerationFailed(String error) {
    return 'Не удалось сгенерировать ключ: $error';
  }

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
  String get networkBackgroundAllowTitle => 'Разрешить работу в фоне';

  @override
  String get networkBackgroundAllowBody =>
      'Чтобы сообщения приходили, пока xVeil в фоне, разреши работу без ограничений батареи. На некоторых телефонах (например Xiaomi, Samsung) нужно ДОПОЛНИТЕЛЬНО включить «Автозапуск» / снять ограничения батареи в настройках приложения.';

  @override
  String get networkBackgroundAllowGrant => 'Разрешить';

  @override
  String get networkBackgroundOpenSettings => 'Настройки приложения';

  @override
  String get callBatteryAllowTitle => 'Не прерывать звонки в фоне?';

  @override
  String get callBatteryAllowBody =>
      'Некоторые телефоны останавливают звонок, когда вы уходите из xVeil. Разрешите игнорировать оптимизацию батареи, чтобы звонки продолжались в фоне.';

  @override
  String get networkBackgroundLater => 'Позже';

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
  String get recoveryPhraseHint =>
      'Введите фразу восстановления, слова через пробел';

  @override
  String get securityCenterTooltip => 'Безопасность';

  @override
  String get securityCenterTitle => 'Безопасность и сеть';

  @override
  String get callStartTooltip => 'Позвонить';

  @override
  String get callAudio => 'Аудиозвонок';

  @override
  String get callVideo => 'Видеозвонок';

  @override
  String get callScreen => 'Демонстрация экрана';

  @override
  String get callIncoming => 'Входящий звонок';

  @override
  String get callDialing => 'Вызов…';

  @override
  String get callConnecting => 'Соединение…';

  @override
  String get callActive => 'В звонке';

  @override
  String get callAccept => 'Принять';

  @override
  String get callDecline => 'Отклонить';

  @override
  String get callEnd => 'Завершить';

  @override
  String get callCancel => 'Отменить';

  @override
  String get callEnded => 'Звонок завершён';

  @override
  String get callMicOn => 'Микрофон вкл';

  @override
  String get callMicOff => 'Микрофон выкл';

  @override
  String get callCameraOn => 'Камера вкл';

  @override
  String get callCameraOff => 'Камера выкл';

  @override
  String get callDevices => 'Устройства';

  @override
  String get callSettingsAudio => 'Аудио';

  @override
  String get callSettingsVideo => 'Видео';

  @override
  String get callAudioOutput => 'Вывод звука';

  @override
  String get callSpeaker => 'Громкоговоритель';

  @override
  String get callEarpiece => 'Динамик телефона';

  @override
  String get callCameras => 'Камеры';

  @override
  String get callMicrophones => 'Микрофоны';

  @override
  String get callScreens => 'Экраны';

  @override
  String get callNoCaptureDevices => 'Устройства захвата недоступны';

  @override
  String get callDeviceSwitchFailed => 'Не удалось переключить устройство';

  @override
  String get callSwitchCamera => 'Переключить камеру';

  @override
  String get callScreenOn => 'Показ экрана';

  @override
  String get callScreenOff => 'Показать экран';

  @override
  String get callScreenWaiting => 'Ожидание показа экрана…';

  @override
  String get groupCallOngoing => 'Идёт групповой звонок';

  @override
  String get groupCallJoinAction => 'Присоединиться';

  @override
  String get callVideoPaused => 'Видео приостановлено';

  @override
  String get callVideoWaiting => 'Ожидание видео…';

  @override
  String get callPathOnion => 'Анонимно (onion)';

  @override
  String get callPathRelay => 'Через реле';

  @override
  String get callPathP2P => 'Напрямую (P2P)';

  @override
  String get callPathNoDirectSession => 'нет прямой связи';

  @override
  String get groupCallTitle => 'Групповой звонок';

  @override
  String get groupCallIncoming => 'Входящий групповой звонок';

  @override
  String get groupCallStartAudio => 'Начать групповой аудиозвонок';

  @override
  String get groupCallStartVideo => 'Начать групповой видеозвонок';

  @override
  String get groupCallBusy => 'Уже активен другой звонок';

  @override
  String get groupCallLeave => 'Выйти из звонка';

  @override
  String get groupCallEndEveryone => 'Завершить для всех';

  @override
  String get groupCallMinimize => 'Свернуть групповой звонок';

  @override
  String get groupCallExpand => 'Открыть групповой звонок';

  @override
  String get settingsNickname => 'Никнейм';

  @override
  String get settingsNicknameHint => 'Занять @имя, по которому вас найдут';

  @override
  String get videoPlayError => 'Не удалось воспроизвести видео';

  @override
  String get emojiSearchHint => 'Поиск эмодзи';

  @override
  String get chatEmojiTooltip => 'Эмодзи';

  @override
  String get chatMoreActions => 'Дополнительные действия';

  @override
  String get composerCamera => 'Камера';

  @override
  String get composerUploadPhoto => 'Загрузить фото';

  @override
  String get composerUploadVideo => 'Загрузить видео';

  @override
  String get composerUploadFile => 'Загрузить файл';

  @override
  String get composerPoll => 'Опрос';

  @override
  String get composerLocation => 'Местоположение';

  @override
  String get composerPlanned => 'Планируется';

  @override
  String get composerGif => 'GIF';

  @override
  String get composerGifLocal => 'Выбрать GIF с устройства';

  @override
  String get composerGifPrivacy =>
      'Без внешнего GIF-поиска: запрос не покидает xVeil.';

  @override
  String get composerCameraUnavailable =>
      'Съёмка камерой недоступна на этом устройстве';

  @override
  String get nicknameTitle => 'Никнейм';

  @override
  String get nicknameIntro =>
      'Никнейм — публичное @имя в сети veil, указывающее на эту личность. Занятие имени требует доказательства работы: короткие имена стоят заметно дороже. Имя можно перехватить строго бо́льшей работой, поэтому своё можно усиливать в любой момент.';

  @override
  String get nicknameFieldLabel => 'Имя (a–z, 0–9, _)';

  @override
  String get nicknameCheck => 'Проверить доступность';

  @override
  String get nicknameFree => 'Свободно';

  @override
  String get nicknameMineVerdict => 'Уже ваше';

  @override
  String nicknameTakenWeight(String weight) {
    return 'Занято — вес защиты $weight';
  }

  @override
  String get nicknameClaim => 'Занять имя';

  @override
  String get nicknameMiningLabel => 'Майнинг доказательства работы…';

  @override
  String nicknameMiningStats(String weight, String target, String hashes) {
    return 'вес $weight / $target · $hashes хешей';
  }

  @override
  String get nicknamePublishing => 'Публикация…';

  @override
  String get nicknameOwnedTitle => 'Ваше имя';

  @override
  String get nicknameWeightExplain =>
      'Вес защиты — суммарное доказательство работы (PoW), закреплённое за именем: показан актуальный вес из сети. Чтобы перехватить имя, нужно вычислить строго больше — «Усилить» повышает цену перехвата.';

  @override
  String nicknameOwnedTakenOver(String weight) {
    return 'Имя перехвачено более тяжёлой работой (вес соперника $weight). «Усилить» вернёт имя, намайнив строго больше.';
  }

  @override
  String nicknameOwnedWeight(String weight) {
    return 'Вес защиты $weight';
  }

  @override
  String get nicknameTopUp => 'Усилить (майнить ещё)';

  @override
  String get nicknameClaimed => 'Имя опубликовано';

  @override
  String get newChatPeerOrNickname => 'Node id (hex) или @имя';

  @override
  String get nicknameNotFound => 'Имя не найдено в сети';

  @override
  String get nicknameIsSelf => 'Это имя указывает на вас';

  @override
  String get nicknameOwnerChanged =>
      'Имя сменило владельца в сети. Контакт по-прежнему указывает на человека, которого вы добавили.';

  @override
  String get settingsDevices => 'Мои устройства';

  @override
  String get settingsDevicesHint =>
      'Связать, проверить или отозвать устройства этой личности';

  @override
  String get devicesThisDevice => 'Это устройство';

  @override
  String get devicesNoGroup => 'Другие устройства пока не связаны';

  @override
  String get devicesLinkNew => 'Связать новое устройство';

  @override
  String get devicesJoinExisting => 'Присоединиться к существующему';

  @override
  String get devicesPhrase => 'Фраза восстановления';

  @override
  String get devicesPhraseHint =>
      'Фраза расшифрует суверенный ключ только для этого действия и не сохранится.';

  @override
  String get devicesRecoveryCode => 'Код восстановления';

  @override
  String get devicesRecoveryCodeHint =>
      'Код расшифрует сертификат восстановления только для этого действия и не сохранится.';

  @override
  String get devicesTargetInvite => 'Инвайт нового устройства';

  @override
  String get devicesTargetInviteHint =>
      'Отсканируйте или вставьте bootstrap-инвайт с нового устройства';

  @override
  String get devicesShowMyInvite =>
      'Сначала покажите инвайт этого устройства существующему устройству';

  @override
  String get devicesPrepare => 'Подготовить защищённую связку';

  @override
  String get devicesAdoptionQrTitle => 'Отсканируйте на новом устройстве';

  @override
  String get devicesAdoptionQrHint =>
      'Сначала отсканируйте этот код там. Затем вернитесь сюда и отправьте зашифрованную настройку.';

  @override
  String get devicesSendSetup => 'Новое устройство готово — отправить';

  @override
  String get devicesSetupSent => 'Зашифрованная настройка отправлена';

  @override
  String get devicesJoinToken => 'Код настройки с существующего устройства';

  @override
  String get devicesJoinTokenHint =>
      'Отсканируйте или вставьте код привязки устройства';

  @override
  String get devicesWaitTitle => 'Готово к приёму';

  @override
  String get devicesWaitHint =>
      'На существующем устройстве нажмите «отправить». Этот экран завершится автоматически.';

  @override
  String get devicesJoined => 'Устройство связано';

  @override
  String get devicesInvalidToken =>
      'Некорректный или чужой код настройки устройства';

  @override
  String get devicesExpiredToken => 'Срок действия кода истёк';

  @override
  String get devicesRevoke => 'Отозвать устройство';

  @override
  String devicesRevokeTitle(String device) {
    return 'Отозвать $device?';
  }

  @override
  String get devicesOperationFailed =>
      'Не удалось завершить привязку устройства';

  @override
  String get devicesCancelPending => 'Отменить ожидание';

  @override
  String get devicesRecoverySection => 'Если потеряны все устройства';

  @override
  String get devicesCreateRecovery => 'Создать сертификат восстановления';

  @override
  String get devicesCreateRecoveryHint =>
      'Сохранит тот же суверенный node ID при потере всех связанных устройств';

  @override
  String get devicesRecover => 'Восстановить реестр устройств';

  @override
  String get devicesRecoverHint =>
      'На чистом реестре используйте сертификат и отдельно сохранённый код';

  @override
  String get devicesCertificate => 'Сертификат восстановления';

  @override
  String get devicesCertificateHint =>
      'Вставьте полное значение xveil-recovery:v1';

  @override
  String get devicesCertificateReady => 'Сертификат восстановления создан';

  @override
  String get devicesCertificateWarning =>
      'Тот, у кого есть оба значения, управляет вашей суверенной идентичностью устройств. Храните сертификат и код раздельно. Код показан только сейчас.';

  @override
  String get devicesCopyCertificate => 'Копировать сертификат';

  @override
  String get devicesCopyCode => 'Копировать код восстановления';

  @override
  String get devicesRecovered =>
      'Реестр устройств восстановлен с прежним суверенным node ID';

  @override
  String get devicesFreshRegistryRequired =>
      'Для восстановления нужен чистый реестр устройств';

  @override
  String get actionReject => 'Отклонить';

  @override
  String cloudDocumentInvites(int count) {
    return 'Приглашения в общие документы ($count)';
  }

  @override
  String cloudDocumentInviteFrom(String sender) {
    return 'Приглашение от $sender';
  }

  @override
  String cloudDocumentInviteKind(String kind) {
    return 'Зашифрованный документ $kind · неактивен до принятия';
  }

  @override
  String get cloudDocumentAdopted => 'Общий документ добавлен';

  @override
  String get cloudDocumentAdoptFailed => 'Не удалось проверить приглашение';

  @override
  String get cloudDocumentRejected => 'Приглашение удалено';

  @override
  String get cloudSharedNew => 'Новый общий документ';

  @override
  String cloudSharedDocuments(int count) {
    return 'Общие документы ($count)';
  }

  @override
  String cloudSharedDocument(String kind, String id) {
    return 'Общий документ $kind · $id';
  }

  @override
  String cloudSharedMembers(int count, int epoch, String role) {
    return 'Участников: $count · эпоха $epoch · $role';
  }

  @override
  String get cloudSharedPickContact => 'Пригласить принятый контакт';

  @override
  String get cloudSharedRole => 'Роль в документе';

  @override
  String get cloudSharedRoleOwner => 'Владелец';

  @override
  String get cloudSharedRoleEditor => 'Редактор';

  @override
  String get cloudSharedRoleViewer => 'Читатель';

  @override
  String get cloudSharedCreated =>
      'Общий документ создан, приглашение поставлено в отправку';

  @override
  String get cloudSharedFailed => 'Не удалось изменить общий документ';

  @override
  String get cloudSharedPartial =>
      'Локально сохранено, но доставка поставлена в очередь не для всех';

  @override
  String get cloudSharedAddMember => 'Добавить участника';

  @override
  String get cloudSharedRevoke => 'Отозвать доступ';

  @override
  String cloudSharedRevokeTitle(String member) {
    return 'Отозвать доступ у $member?';
  }

  @override
  String get cloudSharedRotate => 'Сменить ключ шифрования';

  @override
  String get cloudSharedRotateTitle =>
      'Сменить ключ документа для всех участников?';

  @override
  String get cloudSharedCompact => 'Сжать историю';

  @override
  String get cloudSharedCompactTitle =>
      'Запросить у текущих редакторов подтверждение точного синхронизированного состояния, а затем автоматически заменить старую зашифрованную историю подписанной контрольной точкой? Офлайн-редактор безопасно отложит сжатие. Содержимое, доступ и непрерывность правок сохранятся.';

  @override
  String get cloudSharedResend => 'Повторить приглашение';

  @override
  String get cloudSharedQueued => 'Изменение поставлено в отправку';

  @override
  String get cloudRichTitle => 'Общая заметка';

  @override
  String get cloudRichCollaborative =>
      'Совместное редактирование с шифрованием';

  @override
  String get cloudRichReadOnly => 'Доступ только для чтения';

  @override
  String get cloudRichManage => 'Участники и доступ';

  @override
  String get cloudRichSave => 'Сохранить';

  @override
  String get cloudRichSaved =>
      'Общая заметка сохранена и поставлена в отправку';

  @override
  String get cloudRichFailed => 'Не удалось изменить общую заметку';

  @override
  String get cloudRichHint => 'Пишите вместе…';

  @override
  String get cloudRichRemotePending =>
      'Во время редактирования пришло удалённое изменение. При сохранении обе версии останутся целы.';

  @override
  String get cloudRichRecovered =>
      'Офлайн-правка пережила одновременное удаление и восстановлена здесь.';

  @override
  String get cloudRichInvalid =>
      'Подписанная, но некорректная правка оставлена неактивной.';

  @override
  String get cloudRichDelete => 'Удалить видимую версию';

  @override
  String get cloudRichDeleteTitle => 'Удалить видимую здесь версию?';

  @override
  String get cloudRichDeleteBody =>
      'Удаление охватит только уже видимые на этом устройстве изменения. Одновременная офлайн-правка сохранится и снова появится для проверки, а не потеряется.';

  @override
  String get cloudRichDeleted =>
      'Видимая версия удалена; одновременные правки можно восстановить';

  @override
  String get cloudRichBold => 'Полужирный';

  @override
  String get cloudRichItalic => 'Курсив';

  @override
  String get cloudRichUnderline => 'Подчёркивание';

  @override
  String get cloudRichStrike => 'Зачёркивание';

  @override
  String get cloudRichCode => 'Код в строке';

  @override
  String get cloudRichParagraph => 'Абзац';

  @override
  String get cloudRichHeading1 => 'Заголовок 1';

  @override
  String get cloudRichHeading2 => 'Заголовок 2';

  @override
  String get cloudRichQuote => 'Цитата';

  @override
  String get cloudRichBullet => 'Список';

  @override
  String get cloudRichCodeBlock => 'Блок кода';

  @override
  String get cloudSharedPickKind => 'Тип общего документа';

  @override
  String get cloudKindNote => 'Заметка';

  @override
  String get cloudKindTasks => 'Список задач';

  @override
  String get cloudKindCalendar => 'Календарь';

  @override
  String get cloudTasksTitle => 'Общие задачи';

  @override
  String get cloudCalendarTitle => 'Общий календарь';

  @override
  String get cloudCollectionCollaborative =>
      'Совместная коллекция с шифрованием';

  @override
  String get cloudCollectionEmptyTasks => 'Задач пока нет';

  @override
  String get cloudCollectionEmptyEvents => 'Событий пока нет';

  @override
  String get cloudTaskAdd => 'Добавить задачу';

  @override
  String get cloudTaskEdit => 'Изменить задачу';

  @override
  String get cloudTaskTitle => 'Задача';

  @override
  String get cloudTaskNotes => 'Заметки';

  @override
  String get cloudTaskDue => 'Срок';

  @override
  String get cloudTaskNoDue => 'Без срока';

  @override
  String get cloudEventAdd => 'Добавить событие';

  @override
  String get cloudEventEdit => 'Изменить событие';

  @override
  String get cloudEventTitle => 'Событие';

  @override
  String get cloudEventStart => 'Начало';

  @override
  String get cloudEventEnd => 'Окончание';

  @override
  String get cloudEventAllDay => 'Весь день';

  @override
  String get cloudEventLocation => 'Место';

  @override
  String get cloudCollectionDelete => 'Удалить';

  @override
  String cloudCollectionDeleteTitle(String title) {
    return 'Удалить «$title»?';
  }

  @override
  String get cloudCollectionSaved =>
      'Изменение сохранено и поставлено в отправку';

  @override
  String get cloudCollectionFailed => 'Не удалось изменить общую коллекцию';

  @override
  String get cloudCollectionInvalidRange =>
      'Событие должно закончиться после начала';

  @override
  String get cloudCollectionInvalid =>
      'Подписанное, но некорректное изменение оставлено неактивным.';

  @override
  String get spaceRulesTitle => 'Правила сообщества';

  @override
  String get spaceRulesEmpty => 'Сообщество пока не опубликовало правила.';

  @override
  String get spaceRulesPublish => 'Опубликовать правила';

  @override
  String spaceRulesPublishVersion(int version) {
    return 'Опубликовать правила, версия $version';
  }

  @override
  String get spaceRulesFullText => 'Полный текст правил';

  @override
  String get spaceRulesSummary => 'Краткая сводка';

  @override
  String get spaceRulesEffectiveDate => 'Дата вступления в силу';

  @override
  String spaceRulesEffective(String date) {
    return 'Вступают в силу $date';
  }

  @override
  String spaceRulesVersion(int version) {
    return 'Версия $version';
  }

  @override
  String get spaceRulesAccept => 'Принять правила';

  @override
  String get spaceRulesAccepted => 'Правила приняты';

  @override
  String get spaceRulesAcceptanceRequired =>
      'Ознакомьтесь и примите актуальные правила';

  @override
  String get spaceRulesHistory => 'Предыдущие версии';

  @override
  String get spaceModerationTitle => 'Модерация';

  @override
  String get spaceModerationEmpty => 'Действий модерации пока нет.';

  @override
  String get spaceModerationAdd => 'Новое действие модерации';

  @override
  String get spaceModerationTarget => 'Участник';

  @override
  String get spaceModerationAction => 'Действие';

  @override
  String get spaceModerationReason => 'Причина';

  @override
  String get spaceModerationDuration => 'Срок';

  @override
  String get spaceModerationNoExpiry => 'До отмены';

  @override
  String get spaceModerationOneHour => '1 час';

  @override
  String get spaceModerationOneDay => '24 часа';

  @override
  String get spaceModerationOneWeek => '7 дней';

  @override
  String get spaceModerationActive => 'Действует';

  @override
  String get spaceModerationExpired => 'Срок истёк';

  @override
  String get spaceModerationRevoked => 'Отменено';

  @override
  String get spaceModerationRevoke => 'Снять ограничение';

  @override
  String get spaceModerationRevokeReason => 'Причина снятия';

  @override
  String get spaceModerationWarning => 'Предупреждение';

  @override
  String get spaceModerationDeleteMessage => 'Удалить сообщение';

  @override
  String get spaceModerationDeletePost => 'Удалить публикацию';

  @override
  String get spaceModerationRestrictPublishing =>
      'Временно запретить публикации';

  @override
  String get spaceModerationRestrictMessages => 'Запретить отправку сообщений';

  @override
  String get spaceModerationRestrictVoice =>
      'Запретить вход в голосовые каналы';

  @override
  String get spaceModerationMute => 'Отключить сообщения и голос';

  @override
  String get spaceModerationTimeout => 'Тайм-аут';

  @override
  String get spaceModerationTemporaryBan => 'Временная блокировка';

  @override
  String get spaceModerationPermanentBan => 'Бессрочная блокировка';

  @override
  String spaceModerationUntil(String date) {
    return 'До $date';
  }
}
