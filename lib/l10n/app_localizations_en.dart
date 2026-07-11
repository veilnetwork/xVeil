// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'xVeil';

  @override
  String get actionContinue => 'Continue';

  @override
  String get actionBack => 'Back';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionDone => 'Done';

  @override
  String get actionCopy => 'Copy';

  @override
  String get actionUnderstood => 'I understand';

  @override
  String get preparingTitle => 'Setting up your node';

  @override
  String get preparingBody =>
      'Provisioning your identity on this device. This can take a little while — please wait.';

  @override
  String get preparingFirstRunTitle => 'Creating this identity';

  @override
  String get preparingFirstRunBody =>
      'A one-time setup that can take up to a minute (a proof-of-work that makes the identity hard to forge). It only runs the first time — switching to it later is instant.';

  @override
  String get preparingUnlockTitle => 'Opening your container';

  @override
  String get preparingUnlockBody =>
      'Deriving your key and decrypting on this device — this is deliberately slow to resist guessing. Please wait a moment.';

  @override
  String get onboardWelcomeTitle => 'Welcome to xVeil';

  @override
  String get onboardWelcomeBody =>
      'A decentralized, censorship-resistant messenger. No phone number. No central server. Your identity and your messages stay with you.';

  @override
  String get onboardChooseTitle => 'Set up your identity';

  @override
  String get onboardCreateIdentity => 'Create a new identity';

  @override
  String get onboardCreateIdentitySub =>
      'Generate a fresh sovereign key on this device';

  @override
  String get onboardRestoreIdentity => 'Restore from recovery phrase';

  @override
  String get onboardRestoreIdentitySub =>
      'Use your 24-word phrase to recover an existing identity';

  @override
  String get onboardImportBackup => 'Import a backup';

  @override
  String get onboardImportBackupSub => 'Restore from an encrypted backup file';

  @override
  String get recoveryTitle => 'Save your recovery phrase';

  @override
  String get recoveryBody =>
      'These 24 words ARE your identity. Anyone with them controls it; lose them and it is gone forever. Write them on paper and store them somewhere safe. Never store them online or photograph them.';

  @override
  String get recoveryConfirm => 'I have written down my recovery phrase';

  @override
  String get storageTitle => 'How should we store your data?';

  @override
  String get storageHiddenTitle => 'Hidden space (recommended)';

  @override
  String get storageHiddenBody =>
      'Your chats and keys live in a deniable encrypted container. An adversary who seizes your device cannot prove the data even exists.';

  @override
  String get storagePlainTitle => 'Plain storage';

  @override
  String get storagePlainBody =>
      'Faster to set up, but the existence of your data is visible to anyone who inspects the device.';

  @override
  String get storagePlainWarning =>
      'Not recommended for high-risk users. Choose this only if deniability is not a concern for you.';

  @override
  String get lockTitle => 'Unlock xVeil';

  @override
  String get lockPasswordHint => 'Enter your password';

  @override
  String get lockUnlock => 'Unlock';

  @override
  String get lockWrong => 'Wrong password';

  @override
  String get lockStartOver => 'Start over';

  @override
  String get lockStartOverBody =>
      'Set up a new identity on this device. Your existing data is not deleted, but you will need its password to reach it again. Continue?';

  @override
  String get lockWipe => 'Clear all data';

  @override
  String get lockWipeBody =>
      'This permanently deletes the container and EVERY identity inside it — including any hidden or decoy ones. This cannot be undone: without the container the data is unrecoverable, even with the right password.';

  @override
  String get lockWipeTypePrompt =>
      'To confirm permanent deletion, type this phrase exactly:';

  @override
  String get lockWipePhrase => 'I understand the consequences';

  @override
  String get lockWipeConfirm => 'Delete forever';

  @override
  String get navChats => 'Chats';

  @override
  String get navNetwork => 'Network';

  @override
  String get navSettings => 'Settings';

  @override
  String get chatsEmpty => 'No conversations yet';

  @override
  String get chatsEmptyHint => 'Start a new chat to begin messaging';

  @override
  String get chatNewMessageHint => 'Message';

  @override
  String get chatSend => 'Send';

  @override
  String get notificationNewMessage => 'New message';

  @override
  String get notificationReply => 'Reply';

  @override
  String get notificationReplyHint => 'Message…';

  @override
  String get notificationsTitle => 'Notifications';

  @override
  String get notificationsEnabled => 'Show notifications';

  @override
  String get notificationsPreview => 'Message preview';

  @override
  String get notificationsPreviewHidden =>
      'Hidden (“new message”, no sender or text)';

  @override
  String get notificationsPreviewFull => 'Full (sender and text)';

  @override
  String get chatRequestSent => 'Request sent — waiting for approval';

  @override
  String get chatRequestResend => 'Send again';

  @override
  String get chatRequestCancel => 'Cancel';

  @override
  String get chatRequestCancelTitle => 'Cancel request?';

  @override
  String get chatRequestCancelBody =>
      'Removes this request and conversation from your device. If it already reached them, they may have seen it.';

  @override
  String get chatBlockedContact => 'You blocked this contact';

  @override
  String get chatRequestHint => 'Write a connection request…';

  @override
  String get chatAttachTooltip => 'Attach a file';

  @override
  String get chatVoiceHold => 'Hold to record a voice message';

  @override
  String get chatVoiceSlideCancel => 'Slide to cancel';

  @override
  String get chatVoiceReleaseCancel => 'Release to cancel';

  @override
  String get chatVoiceMicDenied => 'Microphone access denied';

  @override
  String get chatVoiceTooltip => 'Voice message';

  @override
  String get chatVnoteTooltip => 'Video message';

  @override
  String get stickerTitle => 'Stickers';

  @override
  String get stickerImport => 'Import from photos';

  @override
  String get groupCreateTitle => 'New group';

  @override
  String get groupCreateAction => 'Create';

  @override
  String get groupNameHint => 'Group name';

  @override
  String get groupEmpty => 'No groups yet';

  @override
  String get groupNoMessages => 'No messages yet';

  @override
  String get groupMembersTooltip => 'Members';

  @override
  String get groupRenameTitle => 'Rename group';

  @override
  String get groupRenameAction => 'Rename';

  @override
  String get groupRenameDenied =>
      'You don\'t have permission to rename this group';

  @override
  String groupMembers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get groupReply => 'Reply';

  @override
  String get groupAddMember => 'Add';

  @override
  String get groupMute => 'Mute';

  @override
  String get groupUnmute => 'Unmute';

  @override
  String get groupPromote => 'Make admin';

  @override
  String get groupDemote => 'Remove admin';

  @override
  String get groupRemove => 'Remove from group';

  @override
  String get groupLeave => 'Leave group';

  @override
  String get groupLeaveConfirm =>
      'You will stop receiving this group\'s messages.';

  @override
  String get groupNoContactsToAdd => 'No contacts left to add';

  @override
  String get groupAttachImage => 'Send image';

  @override
  String get groupSendSticker => 'Send sticker';

  @override
  String get groupImageOnly => 'Pick an image file';

  @override
  String get groupImageTooLarge => 'Image too large to send inline';

  @override
  String get groupVoiceRecord => 'Record voice message';

  @override
  String get groupVoiceStop => 'Stop and send';

  @override
  String get groupVoiceMessage => 'Voice message';

  @override
  String get groupVoiceTooLong =>
      'Voice message is too long to send in a group';

  @override
  String get reactorsTitle => 'Reactions';

  @override
  String get reactorsYou => 'You';

  @override
  String get settingsShowReactions => 'Show reactions';

  @override
  String get settingsShowReactionsHint =>
      'Reaction chips under messages and the quick-react bar in the message menu. Hiding is local only — reactions keep syncing.';

  @override
  String get stickerEmpty => 'No stickers yet — import your own pictures';

  @override
  String get stickerSharePack => 'Share pack';

  @override
  String get stickerPackTitle => 'Sticker pack';

  @override
  String get stickerPackDownload => 'Download';

  @override
  String get stickerPackInstall => 'Install';

  @override
  String stickerImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stickers added',
      one: '1 sticker added',
    );
    return '$_temp0';
  }

  @override
  String get chatVnoteDenied => 'Camera or microphone access denied';

  @override
  String get chatVoiceRecordFailed => 'Couldn\'t record — try again';

  @override
  String get chatVoiceTranscribe => 'Transcribe';

  @override
  String get chatVoiceTranscribing => 'Transcribing…';

  @override
  String get chatVoiceTranscribeFailed => 'Couldn\'t transcribe';

  @override
  String get chatFileSave => 'Save';

  @override
  String get chatFileSaved => 'File saved';

  @override
  String get chatFileSaveFailed => 'Couldn\'t save the file';

  @override
  String get chatFileTooLarge => 'File is too large';

  @override
  String get chatFileUnreadable => 'Couldn\'t read the file';

  @override
  String get chatMsgEdit => 'Edit';

  @override
  String get chatMsgDeleteForEveryone => 'Delete for everyone';

  @override
  String get chatMsgDeleteForMe => 'Delete for me';

  @override
  String get chatMsgCopy => 'Copy text';

  @override
  String get chatMsgCopied => 'Copied';

  @override
  String get chatLoadEarlier => 'Load earlier messages';

  @override
  String get settingsChatPageSize => 'Messages per page';

  @override
  String get settingsChatPageSizeHint =>
      'How many recent messages a chat loads; older ones load on demand';

  @override
  String get settingsCloseToTray => 'Close to tray';

  @override
  String get settingsCloseToTrayHint =>
      'Closing the window hides it to the system tray and keeps running, so messages and notifications keep arriving. Off = closing quits.';

  @override
  String get navChannels => 'Channels';

  @override
  String get navStorage => 'Storage';

  @override
  String get navMenuTiles => 'Menu';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get settingsCatAccount => 'Identities & account';

  @override
  String get settingsCatAccountHint => 'Switch, add, manage, anonymity';

  @override
  String get settingsCatPrivacy => 'Privacy';

  @override
  String get settingsCatPrivacyHint => 'P2P policy, signature requests';

  @override
  String get settingsCatChats => 'Chats & notifications';

  @override
  String get settingsCatChatsHint =>
      'Notifications, background delivery, page size';

  @override
  String get settingsCatData => 'Data & storage';

  @override
  String get settingsCatDataHint => 'Container size, compaction, files';

  @override
  String get settingsCatAppearanceHint => 'Language, folders panel';

  @override
  String get searchHint => 'Search';

  @override
  String get searchMessagesSection => 'Messages';

  @override
  String get searchNoResults => 'No results';

  @override
  String get chatMsgPin => 'Pin';

  @override
  String get chatMsgUnpin => 'Unpin';

  @override
  String get chatPinnedLabel => 'Pinned message';

  @override
  String get savedMessages => 'Saved Messages';

  @override
  String get savedNoteHint => 'Note to self…';

  @override
  String get chatFormatTooltip => 'Formatting';

  @override
  String get chatFormatBold => 'Bold';

  @override
  String get chatFormatItalic => 'Italic';

  @override
  String get chatFormatUnderline => 'Underline';

  @override
  String get chatFormatStrike => 'Strikethrough';

  @override
  String get chatFormatCode => 'Code';

  @override
  String get chatFormatSpoiler => 'Spoiler';

  @override
  String get chatFormatQuote => 'Quote';

  @override
  String get chatLinkCopied => 'Link copied';

  @override
  String get chatCodeCopied => 'Code copied';

  @override
  String get linkDialogTitle => 'Open link?';

  @override
  String get linkOpen => 'Open';

  @override
  String get linkCopy => 'Copy';

  @override
  String get linkOpenFailed => 'Couldn\'t open the link';

  @override
  String get p2pSelectedTitle => 'Selected contacts';

  @override
  String get p2pSelectedHint =>
      'Contacts allowed direct P2P under the \"Only selected\" policy. Turn one on to grant it; off follows the global policy.';

  @override
  String get p2pSelectedEmpty => 'No accepted contacts yet';

  @override
  String get trayShow => 'Show';

  @override
  String get trayHide => 'Hide';

  @override
  String get trayIdentities => 'Identities';

  @override
  String get trayLock => 'Lock';

  @override
  String get trayQuit => 'Quit';

  @override
  String trayUnread(String count) {
    return '$count unread';
  }

  @override
  String get chatListDelete => 'Delete chat';

  @override
  String get chatDeleteChatTitle => 'Delete this chat?';

  @override
  String get chatDeleteChatBody =>
      'The conversation and all its messages are erased from this device. The other person is not notified.';

  @override
  String get chatEditTitle => 'Edit message';

  @override
  String get chatEditSave => 'Save';

  @override
  String get chatDeleteTitle => 'Delete message?';

  @override
  String get chatDeleteForMeBody =>
      'It is permanently erased from this device.';

  @override
  String get chatDeleteForEveryoneBody =>
      'It is erased here and a delete request is sent to the other person — but they may already have seen or copied it.';

  @override
  String get chatDeleteConfirm => 'Delete';

  @override
  String get chatEdited => 'edited';

  @override
  String get chatMenuRetention => 'Auto-delete';

  @override
  String get retentionUnlimited => 'Never';

  @override
  String get retention7 => 'After 1 week';

  @override
  String get retention30 => 'After 1 month';

  @override
  String get retention90 => 'After 3 months';

  @override
  String get retention365 => 'After 1 year';

  @override
  String get retentionCustom => 'Custom…';

  @override
  String retentionCustomN(int days) {
    return 'Custom ($days days)';
  }

  @override
  String get retentionCustomTitle => 'Delete after (days)';

  @override
  String get retentionDaysSuffix => 'days';

  @override
  String get retentionApplied => 'Older messages will be deleted';

  @override
  String get chatMenuRename => 'Rename';

  @override
  String get chatRenameTitle => 'Local name';

  @override
  String get chatMenuPin => 'Pin to top';

  @override
  String get chatMenuUnpin => 'Unpin';

  @override
  String get chatMenuMute => 'Mute notifications';

  @override
  String get chatMenuUnmute => 'Unmute notifications';

  @override
  String get chatMenuMarkRead => 'Mark as read';

  @override
  String get chatMenuArchive => 'Archive';

  @override
  String get chatMenuUnarchive => 'Unarchive';

  @override
  String get chatsArchiveSection => 'Archive';

  @override
  String get chatMenuFolders => 'Folders';

  @override
  String get chatsFolderAll => 'All';

  @override
  String get chatsFolderNew => 'New folder';

  @override
  String get chatsFolderName => 'Folder name';

  @override
  String get chatsFolderRename => 'Rename folder';

  @override
  String get chatsFolderDelete => 'Delete folder';

  @override
  String get chatsFolderUnnamed => 'Untitled';

  @override
  String get chatsFolderEmpty => 'No chats in this folder';

  @override
  String get chatsFolderNoneYet => 'No folders yet';

  @override
  String get chatMsgRequestSignature => 'Request signature';

  @override
  String get chatSignatureRequested => 'Signature requested';

  @override
  String get chatSignaturePending => 'Awaiting the author\'s signature';

  @override
  String get chatSignatureVerified => 'Authorship verified';

  @override
  String get chatSignatureRefused => 'The author declined to sign';

  @override
  String get chatSignatureFailed => 'Signature did not verify';

  @override
  String signatureAskTitle(String who) {
    return '$who asks you to confirm you wrote the message below';
  }

  @override
  String get signatureAskConfirm => 'Sign';

  @override
  String get settingsSignaturePolicy => 'Signature requests';

  @override
  String get settingsSignaturePolicyHint =>
      'How to answer when a contact asks you to prove you wrote a message';

  @override
  String get settingsApiTitle => 'Automation API';

  @override
  String get settingsApiHint =>
      'Off. Local REST API for bots/scripts (localhost only)';

  @override
  String get settingsApiReadOnly => 'Read-only';

  @override
  String get settingsApiReadOnlyHint =>
      'Reads and events only — writes (send, calls) are refused';

  @override
  String get settingsApiAddToken => 'Add token';

  @override
  String get settingsApiTokenName => 'Token name (e.g. bot)';

  @override
  String get settingsApiRevoke => 'Revoke';

  @override
  String get settingsApiToken => 'API token';

  @override
  String get settingsApiCopyToken => 'Copy token';

  @override
  String get settingsApiRegenerate => 'Regenerate token';

  @override
  String get settingsApiTokenCopied => 'Token copied';

  @override
  String get settingsCommunication => 'Communication';

  @override
  String get settingsP2PPolicy => 'P2P policy';

  @override
  String get settingsP2PPolicyHint =>
      'Allows direct transport for calls, large media, files, and device-to-device exchange when both sides consent.';

  @override
  String get settingsP2PPolicyAnonymousHint =>
      'P2P is disabled while this identity uses anonymous routing.';

  @override
  String get p2pPolicyAllowAll => 'Allow everyone';

  @override
  String get p2pPolicyContacts => 'Allow contacts';

  @override
  String get p2pPolicySelected => 'Only selected contacts';

  @override
  String get p2pPolicyDenied => 'Deny';

  @override
  String get signaturePolicyAsk => 'Ask each time';

  @override
  String get signaturePolicyAuto => 'Sign automatically';

  @override
  String get signaturePolicyRefuse => 'Always refuse';

  @override
  String get settingsKeepNodeBackground => 'Keep running in background';

  @override
  String get settingsKeepNodeBackgroundHint =>
      'Keeps receiving messages when the app is minimised or the screen is off. Shows a persistent notification and uses more battery.';

  @override
  String get settingsFolderPanel => 'Folders panel';

  @override
  String get settingsFolderPanelHint => 'Where chat folders are shown';

  @override
  String get folderPanelLeft => 'Left drawer';

  @override
  String get folderPanelRight => 'Right drawer';

  @override
  String get folderPanelTop => 'Top bar';

  @override
  String get mute30m => '30 minutes';

  @override
  String get mute1h => '1 hour';

  @override
  String get mute8h => '8 hours';

  @override
  String get mute3d => '3 days';

  @override
  String get mute1w => '1 week';

  @override
  String get mute1mo => '1 month';

  @override
  String get muteForever => 'Until I turn it back on';

  @override
  String get muteCustom => 'Custom…';

  @override
  String get muteCustomTitle => 'Mute for how long?';

  @override
  String get muteHoursSuffix => 'hours';

  @override
  String get chatMenuCommunicationSettings => 'Communication settings';

  @override
  String get chatMenuP2P => 'P2P connection';

  @override
  String get contactP2PFollowGlobal => 'Follow global policy';

  @override
  String get contactP2PAllow => 'Allow';

  @override
  String get contactP2PDeny => 'Deny';

  @override
  String get chatMenuAllowPeerDelete => 'Let this contact delete at me';

  @override
  String get chatMenuAllowPeerDeleteHint =>
      'When on, their unsend or clear removes your copy too. Off keeps your copies even if they delete for everyone.';

  @override
  String get chatMenuUnblock => 'Unblock';

  @override
  String get chatMenuClearHistory => 'Clear history';

  @override
  String get chatMenuDeleteConversation => 'Delete conversation';

  @override
  String get chatClearHistoryTitle => 'Clear history?';

  @override
  String get chatClearHistoryBody =>
      'Every message in this chat is erased from this device. The contact stays, so you can keep messaging. The other person is not notified.';

  @override
  String get chatClearHistoryConfirm => 'Clear';

  @override
  String get chatMsgInfo => 'Message info';

  @override
  String get chatMsgHistory => 'Edit history';

  @override
  String get chatHistoryEmpty => 'No earlier versions';

  @override
  String get chatHistoryOriginal => 'Original';

  @override
  String get chatHistoryEdited => 'Edited';

  @override
  String get msgInfoId => 'ID';

  @override
  String get msgInfoTime => 'Time';

  @override
  String get msgInfoDirection => 'Direction';

  @override
  String get msgInfoStatus => 'Status';

  @override
  String get msgInfoFile => 'File';

  @override
  String get msgInfoSize => 'Size';

  @override
  String get msgInfoAuthor => 'Author';

  @override
  String get msgInfoSeq => 'Sequence';

  @override
  String get msgInfoEdited => 'Edited';

  @override
  String get msgInfoYes => 'Yes';

  @override
  String get chatMsgCopyMeta => 'Copy with metadata';

  @override
  String get chatMsgReply => 'Reply';

  @override
  String get chatMsgForward => 'Forward';

  @override
  String get chatMsgSelect => 'Select';

  @override
  String get chatMsgDelete => 'Delete';

  @override
  String get chatMsgDeleteTitle => 'Delete messages?';

  @override
  String get chatReplyingTo => 'Replying to';

  @override
  String get chatQuoteUnavailable => 'Quoted message';

  @override
  String get chatFileLabel => 'File';

  @override
  String get chatForwarded => 'Forwarded';

  @override
  String get chatYou => 'you';

  @override
  String chatForwardedFrom(String name) {
    return 'Forwarded from $name';
  }

  @override
  String get chatForwardTo => 'Forward to';

  @override
  String get chatForwardNoTargets => 'No accepted contacts to forward to';

  @override
  String chatMsgDeleteSelectedBody(int count) {
    return 'Delete $count selected message(s)?';
  }

  @override
  String get dirIncoming => 'Received';

  @override
  String get dirOutgoing => 'Sent';

  @override
  String get msgStatusSending => 'Sending…';

  @override
  String get msgStatusSent => 'Sent';

  @override
  String get msgStatusDelivered => 'Delivered';

  @override
  String get msgStatusFailed => 'Failed';

  @override
  String get identityPickerTitle => 'Choose an identity';

  @override
  String get identityPickerSubtitle =>
      'This vault holds several identities — pick one to act as.';

  @override
  String get networkTitle => 'Overlay network';

  @override
  String get networkStatusConnected => 'Connected';

  @override
  String get networkStatusConnecting => 'Connecting…';

  @override
  String get networkStatusOffline => 'Offline';

  @override
  String networkPeers(int count) {
    return '$count peers';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsIdentity => 'Identity';

  @override
  String get settingsStorage => 'Storage & spaces';

  @override
  String get settingsStorageCompact => 'Compact storage';

  @override
  String get settingsStorageCompactBody =>
      'Reclaim unused space — the app re-opens.';

  @override
  String get settingsStorageCompactDone => 'Reclaimed';

  @override
  String get settingsStorageCompactFailed => 'Couldn\'t compact storage';

  @override
  String get settingsStorageAutoCompact => 'Auto-compact on unlock';

  @override
  String get settingsStorageAutoCompactBody =>
      'Compact automatically when the container bloats. Enable ONLY if no other hidden identity lives in this container — compaction keeps just the unlocked space.';

  @override
  String get settingsStorageLeanPadding => 'Save storage space';

  @override
  String get settingsStorageLeanPaddingBody =>
      'Enabled by default: future writes use less padding, so the container grows much less. Turn off for stronger size-change masking. Applies after the app reopens.';

  @override
  String get settingsStoragePasswordHint => 'Your password';

  @override
  String get settingsNetwork => 'Network & nodes';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLockNow => 'Lock now';

  @override
  String get settingsSwitchIdentity => 'Switch identity';

  @override
  String get settingsAddIdentity => 'Add identity';

  @override
  String get settingsFiles => 'Files';

  @override
  String get settingsFilesHint => 'Auto-download limit & blocked types';

  @override
  String get fileSettingsTitle => 'File downloads';

  @override
  String get fileAutoLimit => 'Auto-download up to';

  @override
  String get fileAutoLimitHint =>
      'Bigger files are offered — you choose whether to download.';

  @override
  String get fileAlwaysAsk => 'Always ask';

  @override
  String get fileBlockedTitle => 'Never auto-download these types';

  @override
  String get fileBlockedHint =>
      'These always wait for your tap (e.g. apk, exe), even when small.';

  @override
  String get fileAddType => 'Add type';

  @override
  String get fileTypeHint => 'Extension, e.g. apk';

  @override
  String get fileDownloadTitle => 'Download file';

  @override
  String get fileSaveEncrypted => 'Encrypted storage';

  @override
  String get fileSaveEncryptedHint => 'Kept in the app, encrypted on disk';

  @override
  String get fileSavePlain => 'Save to disk (unencrypted)';

  @override
  String get fileSavePlainHint => 'A plain file you choose — not protected';

  @override
  String get fileSavePlainWarn =>
      'This file will be saved UNENCRYPTED on disk. Anyone with access to the device can read it. Continue?';

  @override
  String get fileSavePlainConfirm => 'Save unencrypted';

  @override
  String get fileLargeMode => 'Large files';

  @override
  String get fileLargeModeHint =>
      'When you download a file too big for the hidden volume';

  @override
  String get fileLargeModeAsk => 'Ask each time';

  @override
  String get fileCustomSize => 'Custom…';

  @override
  String get fileSizeMb => 'Size in MB';

  @override
  String get fileDownloading => 'Downloading';

  @override
  String get fileRequestingResend => 'Requesting the file from the sender…';

  @override
  String get fileResuming => 'Resuming…';

  @override
  String get fileGoneAskResend =>
      'The sender no longer has this file — ask them to send it again.';

  @override
  String get fileReofferFailed =>
      'Couldn\'t get the file — ask the sender to re-send it.';

  @override
  String get addIdentityTitle => 'Add identity';

  @override
  String get addIdentitySubtitle =>
      'A new identity is hidden in the same file. The first time you add one, your current identity and the new one are managed by a master password you set below.';

  @override
  String get addIdentityCurrentName => 'Name for your current identity';

  @override
  String get addIdentityNewName => 'New identity name';

  @override
  String get addIdentityNewPassword => 'New identity password';

  @override
  String get addIdentityMasterPassword => 'Master password';

  @override
  String get addIdentityMasterHint =>
      'Unlocks the identity chooser. Must be different from each identity\'s own password.';

  @override
  String get addIdentityCreate => 'Create';

  @override
  String get addIdentityIncomplete => 'Fill in every field.';

  @override
  String get addIdentityClash =>
      'That master password is already used by an identity — choose a different one.';

  @override
  String get addIdentityWorking =>
      'Setting up your new identity…\nThis can take a few seconds.';

  @override
  String get addIdentityAnonymous => 'Route anonymously';

  @override
  String get addIdentityAnonymousHint =>
      'Hide this identity\'s network activity through veil\'s overlay so it can\'t be linked to your other identities. Slower.';

  @override
  String get settingsKeepAllOnline => 'Keep all identities online';

  @override
  String get settingsKeepAllOnlineHint =>
      'Run every identity\'s node at once so none goes offline when you switch. Less anonymous — an observer may link your identities by their shared device. Mark sensitive identities to route anonymously.';

  @override
  String get settingsAnonymousRouting => 'Anonymous routing (onion)';

  @override
  String get settingsAnonymousEnabledHint =>
      'now routes over onion — applies on its next start';

  @override
  String get settingsAnonymousDisabledHint =>
      'no longer routes over onion — applies on its next start';

  @override
  String get settingsLazyMining => 'Lazy mining (raise trust)';

  @override
  String get settingsLazyMiningEnabledHint =>
      'grinds extra anti-sybil difficulty in the background — uses CPU; applies on its next start';

  @override
  String get settingsLazyMiningDisabledHint =>
      'off — no background difficulty grind (recommended); applies on its next start';

  @override
  String get settingsManageIdentities => 'Manage identities';

  @override
  String get manageTitle => 'Manage identities';

  @override
  String get manageActive => 'active';

  @override
  String get manageAnonOn => 'Route anonymously';

  @override
  String get manageAnonOff => 'Stop routing anonymously';

  @override
  String get manageBind => 'Bind existing identity';

  @override
  String get manageBindHint =>
      'Add an identity you already have to this master';

  @override
  String get manageBindBody =>
      'Enter the identity\'s own password to add it to this master. The identity is shared, not copied — it stays reachable by its own password too.';

  @override
  String get manageBindPassword => 'Identity password';

  @override
  String get manageBindLabel => 'Name in this master';

  @override
  String get manageBindError =>
      'Couldn\'t bind — wrong password, it\'s a master, or that name/identity is already here.';

  @override
  String get manageUnbind => 'Unbind from this master';

  @override
  String get manageUnbindBody =>
      'Removes this identity from this master only. Its space is NOT deleted — it still opens by its own password and from any other master that lists it.';

  @override
  String get manageUnbindLastError =>
      'Can\'t unbind the last identity. Delete it, or clear all data, instead.';

  @override
  String get manageDelete => 'Delete identity';

  @override
  String get manageDeleteBody =>
      'Permanently and irreversibly erases this identity — its keys, contacts, messages and files are scrubbed from the container. This cannot be undone.';

  @override
  String get manageDeleteLastError =>
      'Can\'t delete the last identity. Use \'Clear all data\' to remove everything.';

  @override
  String get settingsDecoyMaster => 'Set up decoy access';

  @override
  String get decoyTitle => 'Decoy (duress) access';

  @override
  String get decoySubtitle =>
      'A separate password that, under coercion, opens only the identities you tick below. Your real master and every other identity stay hidden.';

  @override
  String get decoyWarning =>
      'Anyone you give this password to sees the FULL content of every identity you tick. Include only genuinely safe ones.';

  @override
  String get decoyPassword => 'Duress password';

  @override
  String get decoyInclude => 'Identities to show under duress';

  @override
  String get decoyCreate => 'Create decoy access';

  @override
  String get decoyCreated => 'Decoy access created.';

  @override
  String get decoyPickOne => 'Select at least one identity.';

  @override
  String get decoyClash =>
      'That password is already in use — choose a different one.';

  @override
  String get languageSystem => 'System default';

  @override
  String get languageRussian => 'Русский';

  @override
  String get languageEnglish => 'English';

  @override
  String get chatRequestTitle => 'This contact wants to connect';

  @override
  String get actionAccept => 'Accept';

  @override
  String get actionBlock => 'Block';

  @override
  String get actionOpen => 'Open';

  @override
  String get inviteAddContact => 'Add a contact';

  @override
  String get inviteShowToContact => 'Show this to your contact';

  @override
  String get inviteTooLarge => 'invite too large';

  @override
  String get inviteCopied => 'Invite copied';

  @override
  String get inviteIsSelf =>
      'That\'s your own invite — you can\'t add yourself.';

  @override
  String get inviteCopyMine => 'Copy my invite';

  @override
  String get identityDetails => 'Identity details';

  @override
  String get identityPublicKey => 'public key';

  @override
  String get identityAlgo => 'algorithm';

  @override
  String get invitePasteTheirs => 'Paste their invite';

  @override
  String get inviteScanTooltip => 'Scan QR with camera';

  @override
  String get scanTitle => 'Scan invite';

  @override
  String get scanHint => 'Point the camera at a contact\'s invite QR code';

  @override
  String get scanUnavailable => 'Camera unavailable — paste the invite instead';

  @override
  String get scanNotInvite => 'That QR is not an xVeil invite';

  @override
  String get scanTorch => 'Torch';

  @override
  String get inviteAddButton => 'Add contact';

  @override
  String get inviteInvalid => 'That is not a valid xVeil invite';

  @override
  String get networkRouteTitle => 'Route traffic (Proxy / VPN)';

  @override
  String get networkRouteSubActive => 'Routing active';

  @override
  String get networkRouteSubIdle => 'Route your traffic through veil';

  @override
  String get routeTitle => 'Route traffic';

  @override
  String get routeSocks5Title => 'Route my traffic (SOCKS5)';

  @override
  String get routeSocks5Hint =>
      'Bind a local SOCKS5 proxy and tunnel its traffic through veil to an exit node. Point a browser or system proxy at it to evade censorship and hide your location.';

  @override
  String get routeListenLabel => 'Local SOCKS5 address';

  @override
  String get routeListenHint =>
      'Loopback only (e.g. 127.0.0.1:1080) — keeps the proxy private to this device.';

  @override
  String get routeListenInvalid =>
      'Use a loopback host:port, e.g. 127.0.0.1:1080';

  @override
  String get routeExitNodeLabel => 'Exit node id (64-hex)';

  @override
  String get routeExitNodeHint =>
      'node_id of an exit you trust — e.g. one of your own nodes from “My nodes”.';

  @override
  String get routeExitNodeInvalid => 'Must be a 64-character hex node id';

  @override
  String get routeNeedExit => 'Set an exit node id to route through';

  @override
  String routeProxyAddress(String addr) {
    return 'Point your apps / browser at $addr';
  }

  @override
  String get routeServeTitle => 'Be an exit node';

  @override
  String get routeServeHint =>
      'Let other peers route their traffic out to the internet through this node. More exits make the network more censorship-resistant — but traffic will appear to originate from this device.';

  @override
  String get routeAllowPrivate => 'Allow private networks (advanced)';

  @override
  String get routeAllowPrivateHint =>
      'Let the exit reach loopback / RFC1918 / link-local addresses. Leave OFF on any public exit — it prevents reaching internal services and cloud metadata endpoints.';

  @override
  String get routeAppliesNextStart =>
      'Changes apply the next time the node starts.';

  @override
  String get routeRestartNode => 'Restart node to apply now';

  @override
  String get networkNodesTitle => 'My nodes';

  @override
  String get networkNodesSub => 'Add a node over SSH, run ogate/oproxy';

  @override
  String networkNodesSubCount(int count) {
    return '$count nodes';
  }

  @override
  String get nodesTitle => 'My nodes';

  @override
  String get nodesEmpty => 'No nodes yet';

  @override
  String get nodesEmptyHint =>
      'Add a server you run as an exit / relay — then route your traffic through it from “Route traffic”.';

  @override
  String get nodesAdd => 'Add node';

  @override
  String get nodeEdit => 'Edit node';

  @override
  String get nodeLabelLabel => 'Label';

  @override
  String get nodeLabelRequired => 'Enter a label';

  @override
  String get nodeIdLabel => 'Node id (64-hex)';

  @override
  String get nodeIdHintText =>
      'The node\'s veil id — lets you route your traffic through it.';

  @override
  String get nodeIdInvalid => 'Must be a 64-character hex node id';

  @override
  String get nodeSshHostLabel => 'SSH host (optional)';

  @override
  String get nodeSshPortLabel => 'SSH port';

  @override
  String get nodeSshUserLabel => 'SSH user (optional)';

  @override
  String get actionSave => 'Save';

  @override
  String get nodeRemove => 'Remove node';

  @override
  String get nodeRemoveConfirm =>
      'Remove this node from your list? The remote server is not touched.';

  @override
  String get nodeUseAsExit => 'Use as routing exit';

  @override
  String get nodeUseAsExitDone => 'Set as your SOCKS5 routing exit';

  @override
  String get nodeNeedsNodeId => 'Add the node id to route through this node';

  @override
  String get nodeProvision => 'Provision veil node over SSH';

  @override
  String get provisionTitle => 'Provision over SSH';

  @override
  String get provisionReleaseUrl => 'veil-cli release URL';

  @override
  String get provisionReleaseHint =>
      'Direct link to a veil-cli binary for the server\'s arch (a GitHub release asset).';

  @override
  String get provisionSha256 => 'veil-cli SHA-256';

  @override
  String get provisionSha256Hint =>
      'Required. The 64-hex SHA-256 published with that binary. Installation aborts on the server if the download does not match — this is what stops a tampered binary from running as root.';

  @override
  String get provisionRunExit => 'Run as an exit (route my traffic through it)';

  @override
  String get provisionScriptLabel =>
      'Runs on the server as root — review before running:';

  @override
  String get provisionPskMissing =>
      'Deployment PSK isn\'t bundled in this build, so the node can\'t join the network. Provisioning is unavailable.';

  @override
  String get provisionRun => 'Run over SSH';

  @override
  String get provisionRunning =>
      'Provisioning… (mining the identity can take a while)';

  @override
  String get provisionNeedUrl => 'Enter an https release URL';

  @override
  String get provisionSavedNodeId => 'Saved the node id reported by the server';

  @override
  String get nodeSshConnect => 'Connect over SSH';

  @override
  String sshDialogTitle(String host) {
    return 'SSH to $host';
  }

  @override
  String get sshUsePassword => 'Password';

  @override
  String get sshUseKey => 'Private key';

  @override
  String get sshPasswordLabel => 'Password';

  @override
  String get sshKeyLabel => 'Private key (PEM)';

  @override
  String get sshKeyPassphraseLabel => 'Key passphrase (optional)';

  @override
  String get sshCredsNotSaved => 'Used once for this connection — never saved.';

  @override
  String get sshConnectRun => 'Connect & check';

  @override
  String get sshConnecting => 'Connecting…';

  @override
  String sshDone(String code) {
    return 'Done (exit $code)';
  }

  @override
  String sshError(String err) {
    return 'Failed: $err';
  }

  @override
  String get nodeCheckReachable => 'Check reachability';

  @override
  String get nodeChecking => 'Checking…';

  @override
  String get nodeReachable => 'Reachable';

  @override
  String get nodeUnreachable => 'Unreachable';

  @override
  String get networkExtTitle => 'Extensions (Lua)';

  @override
  String get networkExtSub => 'Load sandboxed add-ons';

  @override
  String get networkComingLater => 'Coming in a later milestone';

  @override
  String get networkStatusError => 'Error';

  @override
  String get networkBackgroundTitle => 'Keep running in background';

  @override
  String get networkBackgroundHint =>
      'Android only. Keeps the node — your proxy and incoming-message delivery — alive after you switch away from the app. Requires a persistent notification (so it\'s visible the app is running) and uses more battery.';

  @override
  String get networkBackgroundAllowTitle => 'Allow background work';

  @override
  String get networkBackgroundAllowBody =>
      'For messages to arrive while xVeil is in the background, allow it to run without battery restrictions. On some phones (e.g. Xiaomi, Samsung) you must ALSO enable “Autostart” / remove battery limits in the app\'s settings.';

  @override
  String get networkBackgroundAllowGrant => 'Allow';

  @override
  String get networkBackgroundOpenSettings => 'App settings';

  @override
  String get networkBackgroundLater => 'Later';

  @override
  String get peersTitle => 'Connected peers';

  @override
  String get peersSectionActive => 'Active';

  @override
  String get peersSectionInactive => 'Inactive';

  @override
  String get peersEmpty => 'No peers yet';

  @override
  String get peersEmptyHint =>
      'When your node connects to others, they appear here.';

  @override
  String get peerActiveNow => 'active now';

  @override
  String get peerNeverSeen => 'not yet connected';

  @override
  String get peerLastSeenLabel => 'last active';

  @override
  String get peerDetailsTitle => 'Peer details';

  @override
  String get peerFieldNodeId => 'node_id';

  @override
  String get peerFieldTransport => 'transport';

  @override
  String get peerFieldState => 'state';

  @override
  String get peerFieldDirection => 'direction';

  @override
  String get peerFieldLastSeen => 'last active (seen by this device)';

  @override
  String get peerStateActive => 'Active';

  @override
  String get peerStateConnecting => 'Connecting';

  @override
  String get peerStateClosed => 'Disconnected';

  @override
  String get peerStateUnknown => 'Unknown';

  @override
  String get peerDirInbound => 'Inbound';

  @override
  String get peerDirOutbound => 'Outbound';

  @override
  String get peerDirUnknown => 'Unknown';

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int n) {
    return '${n}m ago';
  }

  @override
  String timeHoursAgo(int n) {
    return '${n}h ago';
  }

  @override
  String timeDaysAgo(int n) {
    return '${n}d ago';
  }

  @override
  String get peersShareAction => 'Share entry nodes';

  @override
  String get peersShareTitle => 'Share entry nodes';

  @override
  String get peersShareSubtitle =>
      'Pick nodes to give a friend working entry points to the network — useful if the default seeds are blocked where they are. This shares ONLY these nodes, never your identity.';

  @override
  String get peersShareNone => 'No known entry nodes to share';

  @override
  String get peersShareSelectOne => 'Select at least one node';

  @override
  String get peersShareGenerate => 'Generate link';

  @override
  String get peersShareScanHint =>
      'Have your friend scan this or open the link in xVeil';

  @override
  String get peerActiveBadge => 'active';

  @override
  String peersImported(int n) {
    return 'Added $n entry nodes';
  }

  @override
  String get onboardRepeatPassword => 'Repeat password';

  @override
  String get onboardPasswordTitle => 'Set a password';

  @override
  String get onboardPasswordSubtitle =>
      'This password unlocks your space on this device. There is no reset.';

  @override
  String get onboardPasswordTooShort => 'Use at least 6 characters';

  @override
  String get onboardPasswordMismatch => 'Passwords do not match';

  @override
  String onboardComingSoon(String label) {
    return '$label — coming in the next milestone';
  }

  @override
  String get recoveryPhraseHint =>
      'Enter your recovery phrase, words separated by spaces';

  @override
  String get demoChatTooltip => 'Demo chat';

  @override
  String get demoNewChat => 'New chat';

  @override
  String get demoPeerNodeId => 'Peer node id (hex)';

  @override
  String get demoChatWith => 'Chat with a demo peer';

  @override
  String get callStartTooltip => 'Call';

  @override
  String get callAudio => 'Audio call';

  @override
  String get callVideo => 'Video call';

  @override
  String get callScreen => 'Screen share';

  @override
  String get callIncoming => 'Incoming call';

  @override
  String get callDialing => 'Calling…';

  @override
  String get callConnecting => 'Connecting…';

  @override
  String get callActive => 'In call';

  @override
  String get callAccept => 'Accept';

  @override
  String get callDecline => 'Decline';

  @override
  String get callEnd => 'End call';

  @override
  String get callCancel => 'Cancel';

  @override
  String get callEnded => 'Call ended';

  @override
  String get callMicOn => 'Mic on';

  @override
  String get callMicOff => 'Mic off';

  @override
  String get callCameraOn => 'Camera on';

  @override
  String get callCameraOff => 'Camera off';

  @override
  String get callScreenOn => 'Sharing screen';

  @override
  String get callScreenOff => 'Share screen';

  @override
  String get callPathOnion => 'Anonymous (onion)';

  @override
  String get callPathRelay => 'Relayed';

  @override
  String get callPathP2P => 'Direct (P2P)';

  @override
  String get settingsNickname => 'Nickname';

  @override
  String get settingsNicknameHint => 'Claim an @name others can find you by';

  @override
  String get videoPlayError => 'Could not play this video';

  @override
  String get emojiSearchHint => 'Search emoji';

  @override
  String get chatEmojiTooltip => 'Emoji';

  @override
  String get nicknameTitle => 'Nickname';

  @override
  String get nicknameIntro =>
      'A nickname is a public @name on the veil network that resolves to this identity. Claiming costs proof-of-work: short names cost much more. A name can be taken over by strictly more work, so you can reinforce yours anytime.';

  @override
  String get nicknameFieldLabel => 'Name (a–z, 0–9, _)';

  @override
  String get nicknameCheck => 'Check availability';

  @override
  String get nicknameFree => 'Available';

  @override
  String get nicknameMineVerdict => 'Already yours';

  @override
  String nicknameTakenWeight(String weight) {
    return 'Taken — protection weight $weight';
  }

  @override
  String get nicknameClaim => 'Claim name';

  @override
  String get nicknameMiningLabel => 'Mining proof-of-work…';

  @override
  String nicknameMiningStats(String weight, String target, String hashes) {
    return 'weight $weight / $target · $hashes hashes';
  }

  @override
  String get nicknamePublishing => 'Publishing…';

  @override
  String get nicknameOwnedTitle => 'Your name';

  @override
  String get nicknameWeightExplain =>
      'Protection weight is the cumulative proof-of-work pinned to the name — the value shown is the live network weight. Taking the name over requires strictly more work; Reinforce raises that price.';

  @override
  String nicknameOwnedTakenOver(String weight) {
    return 'The name was taken over with heavier work (rival weight $weight). Reinforce wins it back by mining strictly more.';
  }

  @override
  String nicknameOwnedWeight(String weight) {
    return 'Protection weight $weight';
  }

  @override
  String get nicknameTopUp => 'Reinforce (mine more)';

  @override
  String get nicknameClaimed => 'Name published';

  @override
  String get newChatPeerOrNickname => 'Node id (hex) or @name';

  @override
  String get nicknameNotFound => 'Name not found on the network';

  @override
  String get nicknameIsSelf => 'That name points to you';

  @override
  String get nicknameOwnerChanged =>
      'This name has changed owners on the network. The contact still points to the person you added.';
}
