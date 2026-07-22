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
  String get onboardRestoreBody =>
      'Enter the 24-word recovery phrase you wrote down when the identity was created. The same identity will be recreated on this device.';

  @override
  String get onboardRestoreSubmit => 'Restore';

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
  String get navCommunities => 'Communities';

  @override
  String get navFeed => 'Feed';

  @override
  String get navNetwork => 'Network';

  @override
  String get navSettings => 'Settings';

  @override
  String get navCalls => 'Calls';

  @override
  String get callLogEmpty => 'No calls yet';

  @override
  String get callLogEmptyHint =>
      'Calls you make and receive on any of your devices will appear here';

  @override
  String get callOutcomeMissed => 'Missed';

  @override
  String get callOutcomeDeclined => 'Declined';

  @override
  String get callOutcomeCancelled => 'Cancelled';

  @override
  String get callOutcomeBusy => 'Busy';

  @override
  String get callOutcomeFailed => 'Failed';

  @override
  String get spaceCreateTitle => 'New community';

  @override
  String get spaceCreateAction => 'Create';

  @override
  String get spaceNameHint => 'Community name';

  @override
  String get spaceDescriptionLabel => 'Description';

  @override
  String get spaceDescriptionHint => 'What this community is for';

  @override
  String get spaceDescriptionEditTitle => 'Edit description';

  @override
  String get spaceDescriptionSave => 'Save description';

  @override
  String get spaceVisibilityLabel => 'Visibility';

  @override
  String get spaceVisibilityPublic => 'Public';

  @override
  String get spaceVisibilityPrivate => 'Private';

  @override
  String get spaceVisibilitySecret => 'Secret';

  @override
  String get spaceVisibilityPublicHint =>
      'Posts may be shared publicly. Automatic discovery is not enabled until the holder protocol is ready.';

  @override
  String get spaceVisibilityPrivateHint =>
      'Membership is by invitation and community content is encrypted for current members.';

  @override
  String get spaceVisibilitySecretHint =>
      'Invitations hide the community name; content is encrypted and the community is never searchable.';

  @override
  String get spaceEmpty => 'No communities yet';

  @override
  String get spaceOperationFailed =>
      'Could not update the community. Check the network and try again.';

  @override
  String get spaceChannelsEmpty => 'No channels in this community';

  @override
  String get spaceChannelCreateTitle => 'New channel';

  @override
  String get spaceChannelNameHint => 'Channel name';

  @override
  String get spaceChannelText => 'Text channel';

  @override
  String get spaceChannelVoice => 'Voice channel';

  @override
  String get spaceChannelCategory => 'Category';

  @override
  String get spaceChannelAccess => 'Access';

  @override
  String get spaceChannelAccessSpace => 'All community members';

  @override
  String get spaceChannelAccessRestricted =>
      'Restricted · admins only initially';

  @override
  String get spaceChannelAccessSecret => 'Secret · admins only initially';

  @override
  String get spaceVoiceStartFailed =>
      'Could not start or join this voice session.';

  @override
  String get spacePostsTitle => 'Publications';

  @override
  String get spacePostsEmpty => 'No publications yet';

  @override
  String get spacePostCreateTitle => 'New publication';

  @override
  String get spacePostTitleHint => 'Title (optional)';

  @override
  String get spacePostBodyHint => 'Share an update with the community…';

  @override
  String get spacePostPublish => 'Publish';

  @override
  String get spacePostEdit => 'Edit publication';

  @override
  String get spacePostEdited => 'Edited';

  @override
  String get spacePostDelete => 'Delete publication';

  @override
  String get spacePostDeleteTitle => 'Delete this publication?';

  @override
  String get spacePostDeleteBody =>
      'A signed tombstone will remove it from the community feed on every synchronized member device. This cannot be undone.';

  @override
  String get spacePostTypePost => 'Post';

  @override
  String get spacePostTypeArticle => 'Article';

  @override
  String get spaceFeedEnable => 'Show this community in Feed';

  @override
  String get spaceFeedDisable => 'Hide this community from Feed';

  @override
  String get spaceSettingsTitle => 'Members and settings';

  @override
  String get spaceMembersTooltip => 'Members and settings';

  @override
  String get spaceRetentionTitle => 'History retention';

  @override
  String get spaceRetentionSafetyHint =>
      'Community policy and this device\'s local history are independent.';

  @override
  String get spaceRetentionGlobal => 'Community policy';

  @override
  String get spaceRetentionGlobalHint =>
      'Signed by the owner and enforced by every member.';

  @override
  String get spaceRetentionLocal => 'On this device';

  @override
  String get spaceRetentionLocalHint =>
      'Only hides local history; it never deletes content for other members.';

  @override
  String get spaceActiveTitle => 'Community is active';

  @override
  String get spaceActiveHint =>
      'Members can publish, write in channels, and join voice rooms.';

  @override
  String get spaceArchivedTitle => 'Community is archived';

  @override
  String get spaceArchivedHint =>
      'History remains readable, but messages, posts, reactions, voice rooms, and settings are read-only.';

  @override
  String get spaceArchiveTitle => 'Archive community?';

  @override
  String get spaceArchiveConfirm =>
      'This creates an owner-signed boundary and makes the community read-only on every device. You can restore it later.';

  @override
  String get spaceArchiveAction => 'Archive';

  @override
  String get spaceRestoreTitle => 'Restore community?';

  @override
  String get spaceRestoreConfirm =>
      'New content will start in a fresh signed lifecycle epoch. Archived history remains available.';

  @override
  String get spaceRestoreAction => 'Restore';

  @override
  String spaceMembers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get spaceMemberAdd => 'Invite member';

  @override
  String get spaceNoContactsToAdd =>
      'All accepted contacts are already members';

  @override
  String get spaceInviteSent =>
      'Invitation sent. Membership and keys stay private until they accept.';

  @override
  String get spaceInvitesTitle => 'Invitations';

  @override
  String get spaceSecretInviteTitle => 'Secret community';

  @override
  String spaceInviteFrom(String peer) {
    return 'From $peer';
  }

  @override
  String get spaceInviteAccept => 'Accept';

  @override
  String get spaceInviteDecline => 'Decline';

  @override
  String get spaceInviteJoining => 'Accepted · waiting for verified membership';

  @override
  String get spaceRoleLabel => 'Community role';

  @override
  String get spaceRoleOwner => 'Owner';

  @override
  String get spaceRoleAdmin => 'Administrator';

  @override
  String get spaceRoleMember => 'Member';

  @override
  String get spaceMemberMuted => 'Cannot publish until unmuted';

  @override
  String get spaceMemberMute => 'Restrict publishing';

  @override
  String get spaceMemberUnmute => 'Allow publishing';

  @override
  String get spaceMemberPromote => 'Make administrator';

  @override
  String get spaceMemberDemote => 'Make member';

  @override
  String get spaceMemberRemove => 'Remove from community';

  @override
  String spaceMemberRemoveConfirm(String member) {
    return 'Remove $member and rotate access keys?';
  }

  @override
  String get spaceMemberTransferOwnership => 'Transfer ownership';

  @override
  String spaceMemberTransferOwnershipConfirm(String member) {
    return 'Transfer ownership to $member? You will become an administrator, and only the new owner can transfer it back.';
  }

  @override
  String get spaceRenameTitle => 'Rename community';

  @override
  String get spaceRenameAction => 'Rename';

  @override
  String get spaceRenameDenied =>
      'You do not have permission to rename this community';

  @override
  String get spaceLeave => 'Leave community';

  @override
  String get spaceLeaveConfirm =>
      'You will lose access to its channels and publications. Protected keys will be rotated for the remaining members.';

  @override
  String get spaceOwnerLeaveHint =>
      'Transfer ownership to another member before leaving the community.';

  @override
  String get spaceReplicationTitle => 'P2P availability';

  @override
  String spaceReplicationNeighbors(int count) {
    return 'Distribute through $count nearby members';
  }

  @override
  String get spaceReplicationHint =>
      'More distributors improve offline availability and recovery, but use more traffic on this device.';

  @override
  String get spaceYou => 'You';

  @override
  String get feedEmpty => 'Your feed is empty';

  @override
  String get feedEmptyHint =>
      'Publications from enabled communities will appear here in chronological order.';

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
  String get groupCreateTitle => 'New group chat';

  @override
  String get groupCreateAction => 'Create';

  @override
  String get groupOperationFailed =>
      'Could not update the group. Check the network and try again.';

  @override
  String get groupEncrypted => 'End-to-end encrypted';

  @override
  String get groupEncryptionPending => 'Encryption upgrade pending';

  @override
  String get groupNameHint => 'Group chat name';

  @override
  String get groupEmpty => 'No group chats yet';

  @override
  String get groupNoMessages => 'No messages yet';

  @override
  String get groupMembersTooltip => 'Members';

  @override
  String get groupSyncSettingsTooltip => 'Chat synchronization';

  @override
  String get groupSyncNeighborsTitle => 'Chat synchronization';

  @override
  String groupSyncNeighborsLabel(int count) {
    return 'XOR neighbours: $count';
  }

  @override
  String get groupSyncNeighborsHint =>
      'How many XOR-closest members this device connects to for chat history. More neighbours improve redundancy but use more traffic. This setting is local to this device.';

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
  String get groupVnoteRecord => 'Record video note';

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
  String get stickerPackChooseTarget => 'Add to which pack?';

  @override
  String get stickerPackNew => 'New pack…';

  @override
  String get stickerPackNameHint => 'Pack name';

  @override
  String get stickerPackRename => 'Rename';

  @override
  String get stickerPackDelete => 'Delete pack';

  @override
  String stickerPackDeleteConfirm(String name) {
    return 'Delete \"$name\" and its stickers?';
  }

  @override
  String get stickerPackUnsigned => 'Unsigned pack';

  @override
  String stickerPackSignedBy(String author) {
    return 'Signed by $author';
  }

  @override
  String get stickerPackBadSignature =>
      'Signature check failed — pack not installed';

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
  String get navStorage => 'Storage';

  @override
  String get navMenuTiles => 'Menu';

  @override
  String get cloudTitle => 'Personal cloud';

  @override
  String get cloudUnavailable =>
      'Cloud sync is unavailable until the node is ready';

  @override
  String get cloudEmpty => 'Your cloud is empty';

  @override
  String get cloudEmptyHint =>
      'Files and notes are encrypted locally and replicated only between your own linked devices.';

  @override
  String get cloudAdd => 'Add to cloud';

  @override
  String get cloudAddFile => 'Add file';

  @override
  String get cloudAddNote => 'New note';

  @override
  String get cloudImported => 'File added to your cloud';

  @override
  String get cloudImportFailed => 'Could not import the file';

  @override
  String get cloudLoadFailed => 'Could not load the cloud index';

  @override
  String get cloudReplication => 'Keep on this device';

  @override
  String get cloudModeAll => 'Everything';

  @override
  String get cloudModeSelected => 'Selected';

  @override
  String get cloudModeIndex => 'Index only';

  @override
  String get cloudModeAllHint => 'Automatically download every cloud item';

  @override
  String get cloudModeSelectedHint => 'Automatically download selected items';

  @override
  String get cloudModeIndexHint => 'Show the index and download only on demand';

  @override
  String get cloudLocal => 'on this device';

  @override
  String get cloudRemote => 'in cloud';

  @override
  String cloudReplicas(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count verified copies',
      one: '1 verified copy',
      zero: 'no verified copies',
    );
    return '$_temp0';
  }

  @override
  String get cloudDownload => 'Download to this device';

  @override
  String get cloudShare => 'Share with contact';

  @override
  String get cloudShareTitle => 'Share with';

  @override
  String get cloudNoContacts => 'No accepted contacts to share with';

  @override
  String get cloudShared => 'File shared';

  @override
  String get cloudShareFailed => 'Could not share the file';

  @override
  String get cloudPublicLink => 'Private link';

  @override
  String get cloudPublicCopy => 'Copy link';

  @override
  String get cloudPublicCopied => 'Private link copied';

  @override
  String get cloudPublicRevoke => 'Revoke link';

  @override
  String get cloudPublicRevoked =>
      'Link revoked; existing downloads cannot be erased';

  @override
  String get cloudPublicFailed => 'Could not create the private link';

  @override
  String get cloudPublicImport => 'Open private link';

  @override
  String get cloudPublicPasteHint => 'Paste an xveil://cloud link';

  @override
  String get cloudPublicOpenFailed =>
      'Could not open or verify the private link';

  @override
  String get cloudSelect => 'Keep selected';

  @override
  String get cloudUnselect => 'Stop keeping selected';

  @override
  String get cloudVerify => 'Verify and repair';

  @override
  String get cloudVerifyOk => 'Local cloud files passed verification';

  @override
  String cloudRepairStarted(int count) {
    return 'Repair requested for $count damaged files';
  }

  @override
  String get cloudDelete => 'Delete';

  @override
  String get cloudDeleteTitle => 'Delete from your cloud?';

  @override
  String get cloudDeleteBody =>
      'The item will disappear from every linked device. This cannot be undone.';

  @override
  String get cloudNoteNew => 'New note';

  @override
  String get cloudNoteEdit => 'Edit note';

  @override
  String get cloudNoteTitleHint => 'Title';

  @override
  String get cloudNoteBodyHint => 'Write a private note…';

  @override
  String get cloudNoteSave => 'Save';

  @override
  String get cloudNoteSaved => 'Note saved';

  @override
  String get cloudNoteLoadFailed => 'Could not load or verify the note';

  @override
  String get cloudNoteSaveFailed => 'Could not save the note';

  @override
  String get cloudNoteTitleRequired => 'Enter a title';

  @override
  String get cloudNoteTooLarge => 'The note is too large (maximum 1 MiB)';

  @override
  String get cloudNoteConflictTitle => 'This note changed on another device';

  @override
  String get cloudNoteConflictBody =>
      'Review the current cloud version and merge it with your draft before saving.';

  @override
  String get cloudNoteRemoteVersion => 'Current cloud version';

  @override
  String get cloudNoteYourDraft => 'Your merged draft';

  @override
  String get cloudNoteUseRemote => 'Use cloud version';

  @override
  String get cloudNoteSaveMerged => 'Save merged version';

  @override
  String cloudNoteBranches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count offline versions',
      one: '1 version',
    );
    return '$_temp0 preserved';
  }

  @override
  String get cloudNoteReviewBranches => 'Review versions';

  @override
  String cloudNoteVersion(int number) {
    return 'Preserved version $number';
  }

  @override
  String get cloudNoteBranchesUnavailable =>
      'Download every preserved version before merging';

  @override
  String get cloudNoteMergeReady =>
      'Merge prepared — save the note to resolve every version';

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
  String get chatDeleteNotifyPeer => 'Notify the other person';

  @override
  String get chatDeletedByPeer =>
      'The other person deleted this chat on their device';

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
      'Run every identity\'s node at once so switching is instant and none goes offline (the default). Turn off for strict unlinkability — an observer may link always-on identities by their shared device. Mark sensitive identities to route anonymously.';

  @override
  String get settingsPhraseStatusTitle => 'Recovery phrase';

  @override
  String get settingsPhraseBackedHint =>
      'This identity derives from its recovery phrase — the phrase you wrote down restores it.';

  @override
  String get settingsPhraseNoneHint =>
      'This identity was created without a recovery phrase — a phrase cannot restore it. Keep the app data backed up by other means.';

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
  String get vpnTitle => 'System VPN';

  @override
  String get vpnHint =>
      'Route device traffic through a veil exit. VPN starts its local SOCKS5 transport automatically; the separate SOCKS5 switch is only for direct proxy use.';

  @override
  String get vpnStatusRunning => 'Packet tunnel active';

  @override
  String get vpnStatusStarting => 'Starting packet tunnel…';

  @override
  String get vpnStatusStopping => 'Stopping packet tunnel…';

  @override
  String get vpnStatusStopped => 'Packet tunnel stopped';

  @override
  String get vpnStatusError => 'Packet tunnel error';

  @override
  String get vpnStatusUnsupported => 'Packet tunnel unavailable in this build';

  @override
  String get vpnUnsupportedDetail =>
      'This platform build has no native packet-tunnel engine yet. SOCKS5 remains available; xVeil will not claim that a VPN is active.';

  @override
  String get vpnRouteMode => 'Traffic selection';

  @override
  String get vpnRouteAll => 'All traffic';

  @override
  String get vpnRouteInclude => 'Only selected subnets';

  @override
  String get vpnRouteExclude => 'All except selected subnets';

  @override
  String get vpnApplicationRouting => 'Applications using VPN';

  @override
  String get vpnApplicationAll => 'All applications';

  @override
  String get vpnApplicationOnlySelected => 'Only selected applications';

  @override
  String get vpnApplicationOnlySelectedHint =>
      'Only the selected Android applications enter the tunnel; all other applications use the normal network.';

  @override
  String get vpnApplicationUnsupported =>
      'Per-application routing is available on Android. Consumer iOS/macOS VPNs do not expose the source application; Linux and Windows need a future process-routing backend.';

  @override
  String get vpnApplicationSelect => 'Select apps';

  @override
  String get vpnApplicationNoneSelected => 'Select at least one application';

  @override
  String vpnApplicationSelectedCount(Object count) {
    return '$count applications selected';
  }

  @override
  String get vpnApplicationPickerTitle => 'Applications using VPN';

  @override
  String get vpnApplicationPickerEmpty =>
      'No launchable applications are visible to Android.';

  @override
  String get vpnApplicationSearchEmpty => 'No applications match this search.';

  @override
  String vpnApplicationLoadError(Object error) {
    return 'Could not list applications: $error';
  }

  @override
  String get oproxyCatalogTitle => 'oproxy exits';

  @override
  String get oproxyAddTitle => 'Add oproxy';

  @override
  String get oproxyEditTitle => 'Edit oproxy';

  @override
  String get oproxyName => 'Name';

  @override
  String get oproxyEmpty => 'Add at least one oproxy exit first.';

  @override
  String get oproxyNoDefault => 'No default oproxy is configured';

  @override
  String oproxyDefaultSummary(Object count) {
    return 'Default chain: $count exits';
  }

  @override
  String get oproxyDefaultOrderTitle => 'Default oproxy and fallbacks';

  @override
  String get oproxyDefaultOrderAction => 'Configure default and fallbacks';

  @override
  String get oproxyPrimary => 'Primary oproxy';

  @override
  String get oproxyUseDefault => 'Use default chain';

  @override
  String get oproxyVpnRouteTitle => 'Main VPN oproxy chain';

  @override
  String oproxyRouteSummary(Object fallbacks, Object primary) {
    return '$primary + $fallbacks fallbacks';
  }

  @override
  String get oproxyAutoFailover => 'Automatic oproxy failover';

  @override
  String get oproxyAutoFailoverHint =>
      'New connections try the next exit when the primary cannot open a route. Existing connections stay on their current exit.';

  @override
  String get oproxyApplicationRoutesTitle => 'Application oproxy routes';

  @override
  String get oproxyApplicationRoutesEmpty =>
      'No applications are selected for this VPN.';

  @override
  String oproxyApplicationRoutesCount(Object count) {
    return '$count application overrides';
  }

  @override
  String get vpnIncludedCidrs => 'Included subnets';

  @override
  String get vpnExcludedCidrs => 'Excluded subnets';

  @override
  String get vpnCidrsHint =>
      'One IPv4 or IPv6 CIDR per line, e.g. 10.20.0.0/16';

  @override
  String get vpnCidrsInvalid => 'Every route must be a valid IPv4 or IPv6 CIDR';

  @override
  String get vpnIncludedCountries => 'Countries routed through VPN (GeoIP)';

  @override
  String get vpnExcludedCountries => 'Countries bypassing VPN (GeoIP)';

  @override
  String get vpnCountriesHint =>
      'Two-letter country codes separated by spaces or commas, e.g. KZ, RU. Uses the bundled IPdeny snapshot; GeoIP is approximate.';

  @override
  String get vpnCountriesInvalid => 'Use two-letter country codes such as KZ';

  @override
  String get vpnRouteDns => 'Route DNS through VPN';

  @override
  String get vpnRouteDnsHint =>
      'Install the selected DNS servers on the tunnel interface to prevent resolver leaks.';

  @override
  String get vpnDnsServers => 'DNS servers';

  @override
  String get vpnDnsHint => 'One IPv4 or IPv6 address per line';

  @override
  String get vpnDnsInvalid => 'Every DNS server must be an IP address';

  @override
  String get vpnAllowLan => 'Allow local network';

  @override
  String get vpnAllowLanHint =>
      'Keep private and link-local subnets reachable outside the tunnel.';

  @override
  String get vpnMtu => 'Tunnel MTU';

  @override
  String get vpnMtuHint => '1280–9000; 1280 is safe across IPv4 and IPv6 paths';

  @override
  String get vpnMtuInvalid => 'MTU must be between 1280 and 9000';

  @override
  String get vpnNeedsProxy =>
      'Select a valid exit node first. VPN starts its SOCKS5 transport automatically.';

  @override
  String get vpnStart => 'Start VPN';

  @override
  String get vpnStop => 'Stop VPN';

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
  String get nodesAddChoiceTitle => 'What kind of node are you adding?';

  @override
  String get nodesAddExisting => 'Add an existing node';

  @override
  String get nodesAddExistingHint =>
      'Register a node that is already installed and has a node id.';

  @override
  String get nodesAddExistingFieldsHint =>
      'Required: label and node ID. SSH fields are optional and only needed to manage the server. A password or key can be saved below in xVeil\'s encrypted storage.';

  @override
  String get nodesBootstrapNew => 'Bootstrap a new node over SSH';

  @override
  String get nodesBootstrapNewHint =>
      'Install veil on a Linux server; its node id will be saved automatically.';

  @override
  String get nodesBootstrapFieldsHint =>
      'Required: label, SSH host, and SSH user. The port defaults to 22. A password or key can be saved below; the node ID is saved after provisioning.';

  @override
  String get nodesBootstrapContinue => 'Continue to provisioning';

  @override
  String get nodeEdit => 'Edit node';

  @override
  String get nodeLabelLabel => 'Label *';

  @override
  String get nodeLabelRequired => 'Enter a label';

  @override
  String get nodeIdLabel => 'Node ID (64 hex, optional)';

  @override
  String get nodeIdRequiredLabel => 'Node ID (64 hex) *';

  @override
  String get nodeIdHintText =>
      'The node\'s veil id — lets you route your traffic through it.';

  @override
  String get nodeIdInvalid => 'Must be a 64-character hex node id';

  @override
  String get nodeIdRequired =>
      'Enter the existing node\'s 64-character node id';

  @override
  String get nodeSshHostLabel => 'SSH host (optional)';

  @override
  String get nodeSshHostRequiredLabel => 'SSH host *';

  @override
  String get nodeSshHostRequired => 'Enter the SSH host for the new server';

  @override
  String get nodeSshPortLabel => 'SSH port (defaults to 22)';

  @override
  String get nodeSshUserLabel => 'SSH user (optional)';

  @override
  String get nodeSshUserRequiredLabel => 'SSH user *';

  @override
  String get nodeSshUserRequired => 'Enter the SSH user for the new server';

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
  String get nodeManage => 'Manage node';

  @override
  String get nodeInventory => 'Inspect installation and status';

  @override
  String get nodeInstallUpdate => 'Install or update software';

  @override
  String get nodeServices => 'Services';

  @override
  String get nodeAdvancedConfig => 'Advanced configuration';

  @override
  String get nodeServiceStatus => 'Status';

  @override
  String get nodeServiceStart => 'Start';

  @override
  String get nodeServiceStop => 'Stop';

  @override
  String get nodeServiceRestart => 'Restart';

  @override
  String get nodeServiceEnable => 'Enable and start';

  @override
  String get nodeServiceDisable => 'Stop and disable';

  @override
  String get nodeConfigLoad => 'Load from server';

  @override
  String get nodeConfigApply => 'Validate, apply and restart';

  @override
  String get nodeConfigNotLoaded =>
      'Load the current server config before editing it.';

  @override
  String get nodeUninstallSoftware => 'Uninstall software (keep data)';

  @override
  String get nodeDebootstrap => 'Debootstrap node (erase everything)';

  @override
  String get nodeDebootstrapConfirm =>
      'This permanently deletes the remote node identity, state, configs and all veil/ogate/oproxy software. Type DELETE to continue.';

  @override
  String get nodeDebootstrapType => 'Type DELETE';

  @override
  String get nodeOperationOutput => 'Server output';

  @override
  String get nodeOperationRun => 'Run command';

  @override
  String get nodeOperationSuccess => 'Remote operation completed';

  @override
  String get nodeSelectServices => 'Select services';

  @override
  String get provisionTitle => 'Provision over SSH';

  @override
  String get provisionReleaseSection => 'veil-cli release';

  @override
  String get provisionReleaseTarget => 'Server architecture';

  @override
  String get provisionReleaseTargetX64 => 'x86_64 Linux (portable musl)';

  @override
  String get provisionReleaseTargetArm64 => 'ARM64 Linux (portable musl)';

  @override
  String get provisionReleaseRefresh => 'Refresh GitHub fields';

  @override
  String get provisionSourceGithub => 'GitHub release';

  @override
  String get provisionSourceCustom => 'Custom link';

  @override
  String get provisionReleaseLoading =>
      'Loading the latest release from GitHub…';

  @override
  String provisionReleaseLoaded(String tag) {
    return 'Loaded GitHub release $tag';
  }

  @override
  String provisionReleaseError(String error) {
    return 'Could not auto-fill from GitHub: $error. You can enter both values manually.';
  }

  @override
  String get provisionReleaseUrl => 'veil-cli release URL';

  @override
  String get provisionReleaseHint =>
      'Filled automatically from the official veilnetwork/veil GitHub release. Choose Custom link to override it.';

  @override
  String get provisionCustomReleaseHint =>
      'Enter a direct HTTPS link to your binary. You must also supply its SHA-256 below.';

  @override
  String get provisionSha256 => 'veil-cli SHA-256';

  @override
  String get provisionSha256Hint =>
      'Required. The 64-hex SHA-256 published with that binary. Installation aborts on the server if the download does not match — this is what stops a tampered binary from running as root.';

  @override
  String get provisionRunExit => 'Run as an exit (route my traffic through it)';

  @override
  String get provisionComponents => 'Components';

  @override
  String get provisionTransports => 'Incoming transports';

  @override
  String get provisionTransportObfs4TcpHint =>
      'Obfuscated TCP listener for censorship-resistant peer connections.';

  @override
  String get provisionTransportTcpHint =>
      'Plain TCP listener without transport encryption.';

  @override
  String get provisionTransportTlsHint =>
      'TCP listener protected by the shared TLS certificate below.';

  @override
  String get provisionTransportQuicHint =>
      'QUIC listener over UDP, protected by the shared TLS certificate below.';

  @override
  String get provisionTransportWssHint =>
      'Secure WebSocket listener, protected by the shared TLS certificate below.';

  @override
  String provisionTransportPort(String transport) {
    return '$transport port';
  }

  @override
  String provisionTransportNetwork(String protocol) {
    return 'Network protocol: $protocol';
  }

  @override
  String get provisionTransportCommon => 'Shared transport settings';

  @override
  String get provisionTransportCommonHint =>
      'These values apply to every selected incoming transport.';

  @override
  String get provisionAdvertiseHost => 'Public host / IP (optional)';

  @override
  String get provisionAdvertiseHostHint =>
      'The same public address is advertised for every selected transport; each one keeps its own port.';

  @override
  String get provisionTlsShared => 'TLS certificate';

  @override
  String provisionTlsSharedHint(String transports) {
    return 'Used by: $transports. Choose how the certificate is supplied to every selected TLS transport.';
  }

  @override
  String get provisionTlsMode => 'Certificate source';

  @override
  String get provisionTlsModeExisting => 'Existing files';

  @override
  String get provisionTlsModeAutomatic => 'Automatic';

  @override
  String get provisionTlsModeSelfSigned => 'Self-signed';

  @override
  String get provisionTlsAutomaticName => 'Domain or IP (optional override)';

  @override
  String get provisionTlsAutomaticNameHint =>
      'Leave empty to use the public host / IP above. A DNS name gets Let\'s Encrypt; an IP gets a self-signed certificate with an IP SAN.';

  @override
  String get provisionTlsLetsEncryptHint =>
      'Let\'s Encrypt will be requested on the server. The domain must point to this server and inbound TCP port 80 must be open. Renewal is configured automatically.';

  @override
  String get provisionTlsIpHint =>
      'An IP address cannot use the standard Let\'s Encrypt flow here. A self-signed certificate with this IP in its SAN will be generated on the server.';

  @override
  String get provisionTlsUnknownHint =>
      'Enter a domain or IP here, or set the public host / IP above.';

  @override
  String get provisionTlsEmail => 'Let\'s Encrypt account email';

  @override
  String get provisionTlsAgreeTerms =>
      'I agree to the Let\'s Encrypt terms of service';

  @override
  String get provisionTlsSelfSignedName => 'Domain or IP in the certificate';

  @override
  String get provisionTlsSelfSignedNameHint =>
      'The value is written into the certificate\'s DNS or IP subject alternative name.';

  @override
  String get provisionTlsSelfSignedDays => 'Validity in days (1–3650)';

  @override
  String get provisionTlsSelfSignedHint =>
      'Clients must trust this self-signed certificate explicitly. Its private key is generated and kept on the server.';

  @override
  String get provisionTlsCert => 'Remote TLS certificate path';

  @override
  String get provisionTlsKey => 'Remote TLS private-key path';

  @override
  String get provisionTlsCa => 'Remote TLS CA path (optional)';

  @override
  String provisionComponentUrl(String component) {
    return '$component release URL';
  }

  @override
  String provisionComponentSha(String component) {
    return '$component SHA-256';
  }

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
  String get provisionInvalidConfig =>
      'Check the required release, transport, port, and TLS fields';

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
  String get sshCredsNotSaved =>
      'Credentials entered here are used once. Manage saved credentials in the node card.';

  @override
  String get sshCredentialsTitle => 'SSH authentication';

  @override
  String get sshSavedPasswordLabel => 'Saved SSH password (optional)';

  @override
  String get sshSavedPasswordHint =>
      'Leave empty to remove the saved password.';

  @override
  String get sshCredentialsEncryptedHint =>
      'The password and private key are stored only inside xVeil\'s encrypted container.';

  @override
  String get sshCredentialsEndpointCleared =>
      'The SSH endpoint changed, so the saved password and key were cleared for safety.';

  @override
  String get sshGenerateEd25519 => 'Generate an Ed25519 key';

  @override
  String get sshRegenerateEd25519 => 'Generate a new Ed25519 key';

  @override
  String get sshSavedEd25519Title => 'Saved Ed25519 key';

  @override
  String get sshPublicKeyLabel =>
      'Add this line to ~/.ssh/authorized_keys on the server:';

  @override
  String get sshCopyPublicKey => 'Copy public key';

  @override
  String get sshPublicKeyCopied => 'Public key copied';

  @override
  String get sshRemoveSavedKey => 'Remove saved key';

  @override
  String get sshUseSavedKeyHint => 'Leave empty to use the saved Ed25519 key.';

  @override
  String get sshOtherKeyLabel => 'Another private key (PEM, this time only)';

  @override
  String get sshCredentialRequired => 'Enter a password or private key';

  @override
  String get sshCredentialsSaving => 'Saving…';

  @override
  String sshCredentialsSaveFailed(String error) {
    return 'Could not save SSH credentials: $error';
  }

  @override
  String sshKeyGenerationFailed(String error) {
    return 'Could not generate the key: $error';
  }

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
  String get callBatteryAllowTitle => 'Keep calls alive in the background?';

  @override
  String get callBatteryAllowBody =>
      'Some phones stop a call when you switch away from xVeil. Allow it to ignore battery optimization so backgrounded calls keep running.';

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
  String get recoveryPhraseHint =>
      'Enter your recovery phrase, words separated by spaces';

  @override
  String get securityCenterTooltip => 'Security';

  @override
  String get securityCenterTitle => 'Security & network';

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
  String get callDevices => 'Devices';

  @override
  String get callSettingsAudio => 'Audio';

  @override
  String get callSettingsVideo => 'Video';

  @override
  String get callAudioOutput => 'Audio output';

  @override
  String get callSpeaker => 'Speaker';

  @override
  String get callEarpiece => 'Phone earpiece';

  @override
  String get callCameras => 'Cameras';

  @override
  String get callMicrophones => 'Microphones';

  @override
  String get callScreens => 'Screens';

  @override
  String get callNoCaptureDevices => 'No capture devices available';

  @override
  String get callDeviceSwitchFailed => 'Could not switch device';

  @override
  String get callSwitchCamera => 'Switch camera';

  @override
  String get callScreenOn => 'Sharing screen';

  @override
  String get callScreenOff => 'Share screen';

  @override
  String get callScreenWaiting => 'Waiting for shared screen…';

  @override
  String get groupCallOngoing => 'Group call in progress';

  @override
  String get groupCallJoinAction => 'Join';

  @override
  String get callVideoPaused => 'Video paused';

  @override
  String get callVideoWaiting => 'Waiting for video…';

  @override
  String get callPathOnion => 'Anonymous (onion)';

  @override
  String get callPathRelay => 'Relayed';

  @override
  String get callPathP2P => 'Direct (P2P)';

  @override
  String get callPathNoDirectSession => 'no direct link';

  @override
  String get groupCallTitle => 'Group call';

  @override
  String get groupCallIncoming => 'Incoming group call';

  @override
  String get groupCallStartAudio => 'Start group audio call';

  @override
  String get groupCallStartVideo => 'Start group video call';

  @override
  String get groupCallBusy => 'Another call is already active';

  @override
  String get groupCallLeave => 'Leave call';

  @override
  String get groupCallEndEveryone => 'End for everyone';

  @override
  String get groupCallMinimize => 'Minimize group call';

  @override
  String get groupCallExpand => 'Open group call';

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
  String get chatMoreActions => 'More actions';

  @override
  String get composerCamera => 'Camera';

  @override
  String get composerUploadPhoto => 'Upload photo';

  @override
  String get composerUploadVideo => 'Upload video';

  @override
  String get composerUploadFile => 'Upload file';

  @override
  String get composerPoll => 'Poll';

  @override
  String get composerLocation => 'Location';

  @override
  String get composerPlanned => 'Planned';

  @override
  String get composerGif => 'GIF';

  @override
  String get composerGifLocal => 'Choose GIF from device';

  @override
  String get composerGifPrivacy =>
      'No external GIF search: your query never leaves xVeil.';

  @override
  String get composerCameraUnavailable =>
      'Camera capture is unavailable on this device';

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

  @override
  String get settingsDevices => 'My devices';

  @override
  String get settingsDevicesHint =>
      'Link, review, or revoke devices that share this identity';

  @override
  String get devicesThisDevice => 'This device';

  @override
  String get devicesNoGroup => 'No other devices are linked yet';

  @override
  String get devicesLinkNew => 'Link a new device';

  @override
  String get devicesJoinExisting => 'Join an existing device';

  @override
  String get devicesPhrase => 'Recovery phrase';

  @override
  String get devicesPhraseHint =>
      'The phrase decrypts the sovereign key for this one action. It is not stored.';

  @override
  String get devicesRecoveryCode => 'Recovery code';

  @override
  String get devicesRecoveryCodeHint =>
      'The code decrypts the recovery certificate for this one action. It is not stored.';

  @override
  String get devicesTargetInvite => 'New device invite';

  @override
  String get devicesTargetInviteHint =>
      'Scan or paste the bootstrap invite shown by the new device';

  @override
  String get devicesShowMyInvite =>
      'First, show this device invite to the existing device';

  @override
  String get devicesPrepare => 'Prepare secure link';

  @override
  String get devicesAdoptionQrTitle => 'Scan this on the new device';

  @override
  String get devicesAdoptionQrHint =>
      'First scan this setup code there. Then return here and send the encrypted setup.';

  @override
  String get devicesSendSetup => 'New device is ready — send setup';

  @override
  String get devicesSetupSent => 'Encrypted setup sent';

  @override
  String get devicesJoinToken => 'Setup code from existing device';

  @override
  String get devicesJoinTokenHint => 'Scan or paste the device setup code';

  @override
  String get devicesWaitTitle => 'Ready to receive';

  @override
  String get devicesWaitHint =>
      'On the existing device, press “send setup”. This screen will finish automatically.';

  @override
  String get devicesJoined => 'Device linked';

  @override
  String get devicesInvalidToken => 'Invalid or mismatched device setup code';

  @override
  String get devicesExpiredToken => 'This setup code has expired';

  @override
  String get devicesRevoke => 'Revoke device';

  @override
  String devicesRevokeTitle(String device) {
    return 'Revoke $device?';
  }

  @override
  String get devicesOperationFailed => 'Could not complete device linking';

  @override
  String get devicesCancelPending => 'Cancel waiting';

  @override
  String get devicesRecoverySection => 'All devices lost';

  @override
  String get devicesCreateRecovery => 'Create recovery certificate';

  @override
  String get devicesCreateRecoveryHint =>
      'Preserves the same sovereign node ID if every linked device is lost';

  @override
  String get devicesRecover => 'Recover device registry';

  @override
  String get devicesRecoverHint =>
      'Use a certificate and its separately stored recovery code on a fresh registry';

  @override
  String get devicesCertificate => 'Recovery certificate';

  @override
  String get devicesCertificateHint =>
      'Paste the complete xveil-recovery:v1 value';

  @override
  String get devicesCertificateReady => 'Recovery certificate created';

  @override
  String get devicesCertificateWarning =>
      'Anyone with both values controls your sovereign device identity. Store the certificate and code separately. The code is shown only now.';

  @override
  String get devicesCopyCertificate => 'Copy certificate';

  @override
  String get devicesCopyCode => 'Copy recovery code';

  @override
  String get devicesRecovered =>
      'Device registry recovered with the same sovereign node ID';

  @override
  String get devicesFreshRegistryRequired =>
      'Recovery requires a fresh device registry';

  @override
  String get actionReject => 'Reject';

  @override
  String cloudDocumentInvites(int count) {
    return 'Shared document invitations ($count)';
  }

  @override
  String cloudDocumentInviteFrom(String sender) {
    return 'Invitation from $sender';
  }

  @override
  String cloudDocumentInviteKind(String kind) {
    return 'Encrypted $kind document · inactive until accepted';
  }

  @override
  String get cloudDocumentAdopted => 'Shared document added';

  @override
  String get cloudDocumentAdoptFailed => 'The invitation could not be verified';

  @override
  String get cloudDocumentRejected => 'Invitation removed';

  @override
  String get cloudSharedNew => 'New shared document';

  @override
  String cloudSharedDocuments(int count) {
    return 'Shared documents ($count)';
  }

  @override
  String cloudSharedDocument(String kind, String id) {
    return 'Shared $kind · $id';
  }

  @override
  String cloudSharedMembers(int count, int epoch, String role) {
    return '$count members · epoch $epoch · $role';
  }

  @override
  String get cloudSharedPickContact => 'Invite an accepted contact';

  @override
  String get cloudSharedRole => 'Document role';

  @override
  String get cloudSharedRoleOwner => 'Owner';

  @override
  String get cloudSharedRoleEditor => 'Editor';

  @override
  String get cloudSharedRoleViewer => 'Viewer';

  @override
  String get cloudSharedCreated =>
      'Shared document created and invitation queued';

  @override
  String get cloudSharedFailed => 'Could not update the shared document';

  @override
  String get cloudSharedPartial =>
      'Saved locally, but delivery was not queued for every member';

  @override
  String get cloudSharedAddMember => 'Add member';

  @override
  String get cloudSharedRevoke => 'Revoke access';

  @override
  String cloudSharedRevokeTitle(String member) {
    return 'Revoke access for $member?';
  }

  @override
  String get cloudSharedRotate => 'Rotate encryption key';

  @override
  String get cloudSharedRotateTitle =>
      'Rotate the document key for every member?';

  @override
  String get cloudSharedCompact => 'Compact history';

  @override
  String get cloudSharedCompactTitle =>
      'Ask current editors to confirm the exact synchronized state, then automatically replace the old encrypted history with a signed checkpoint? Offline editors will safely delay compaction. Current content, access and edit continuity are preserved.';

  @override
  String get cloudSharedResend => 'Resend invitation';

  @override
  String get cloudSharedQueued => 'Update queued';

  @override
  String get cloudRichTitle => 'Shared note';

  @override
  String get cloudRichCollaborative => 'Encrypted collaborative editing';

  @override
  String get cloudRichReadOnly => 'Read-only access';

  @override
  String get cloudRichManage => 'Members and access';

  @override
  String get cloudRichSave => 'Save';

  @override
  String get cloudRichSaved => 'Shared note saved and queued';

  @override
  String get cloudRichFailed => 'The shared note could not be updated';

  @override
  String get cloudRichHint => 'Write together…';

  @override
  String get cloudRichRemotePending =>
      'A remote change arrived while you were editing. Saving preserves both changes.';

  @override
  String get cloudRichRecovered =>
      'An offline edit survived a concurrent deletion and was recovered here.';

  @override
  String get cloudRichInvalid =>
      'An authenticated but invalid edit was kept inert.';

  @override
  String get cloudRichDelete => 'Delete visible version';

  @override
  String get cloudRichDeleteTitle => 'Delete the version visible here?';

  @override
  String get cloudRichDeleteBody =>
      'This deletion covers only changes already visible on this device. A concurrent offline edit is preserved and will reappear for review instead of being lost.';

  @override
  String get cloudRichDeleted =>
      'Visible version deleted; concurrent edits remain recoverable';

  @override
  String get cloudRichBold => 'Bold';

  @override
  String get cloudRichItalic => 'Italic';

  @override
  String get cloudRichUnderline => 'Underline';

  @override
  String get cloudRichStrike => 'Strikethrough';

  @override
  String get cloudRichCode => 'Inline code';

  @override
  String get cloudRichParagraph => 'Paragraph';

  @override
  String get cloudRichHeading1 => 'Heading 1';

  @override
  String get cloudRichHeading2 => 'Heading 2';

  @override
  String get cloudRichQuote => 'Quote';

  @override
  String get cloudRichBullet => 'Bullet';

  @override
  String get cloudRichCodeBlock => 'Code block';

  @override
  String get cloudSharedPickKind => 'Shared document type';

  @override
  String get cloudKindNote => 'Note';

  @override
  String get cloudKindTasks => 'Task list';

  @override
  String get cloudKindCalendar => 'Calendar';

  @override
  String get cloudTasksTitle => 'Shared tasks';

  @override
  String get cloudCalendarTitle => 'Shared calendar';

  @override
  String get cloudCollectionCollaborative =>
      'Encrypted collaborative collection';

  @override
  String get cloudCollectionEmptyTasks => 'No tasks yet';

  @override
  String get cloudCollectionEmptyEvents => 'No events yet';

  @override
  String get cloudTaskAdd => 'Add task';

  @override
  String get cloudTaskEdit => 'Edit task';

  @override
  String get cloudTaskTitle => 'Task';

  @override
  String get cloudTaskNotes => 'Notes';

  @override
  String get cloudTaskDue => 'Due date';

  @override
  String get cloudTaskNoDue => 'No due date';

  @override
  String get cloudEventAdd => 'Add event';

  @override
  String get cloudEventEdit => 'Edit event';

  @override
  String get cloudEventTitle => 'Event';

  @override
  String get cloudEventStart => 'Starts';

  @override
  String get cloudEventEnd => 'Ends';

  @override
  String get cloudEventAllDay => 'All day';

  @override
  String get cloudEventLocation => 'Location';

  @override
  String get cloudCollectionDelete => 'Delete';

  @override
  String cloudCollectionDeleteTitle(String title) {
    return 'Delete \"$title\"?';
  }

  @override
  String get cloudCollectionSaved => 'Change saved and queued';

  @override
  String get cloudCollectionFailed => 'Could not update this shared collection';

  @override
  String get cloudCollectionInvalidRange =>
      'The event must end after it starts';

  @override
  String get cloudCollectionInvalid =>
      'An authenticated but invalid change was kept inert.';

  @override
  String get spaceRulesTitle => 'Community rules';

  @override
  String get spaceRulesEmpty => 'This community has not published rules yet.';

  @override
  String get spaceRulesPublish => 'Publish rules';

  @override
  String spaceRulesPublishVersion(int version) {
    return 'Publish rules version $version';
  }

  @override
  String get spaceRulesFullText => 'Full rules';

  @override
  String get spaceRulesSummary => 'Short summary';

  @override
  String get spaceRulesEffectiveDate => 'Effective date';

  @override
  String spaceRulesEffective(String date) {
    return 'Effective $date';
  }

  @override
  String spaceRulesVersion(int version) {
    return 'Version $version';
  }

  @override
  String get spaceRulesAccept => 'Accept rules';

  @override
  String get spaceRulesAccepted => 'Rules accepted';

  @override
  String get spaceRulesAcceptanceRequired =>
      'Please review and accept the current rules';

  @override
  String get spaceRulesHistory => 'Previous versions';

  @override
  String get spaceModerationTitle => 'Moderation';

  @override
  String get spaceModerationEmpty =>
      'No moderation actions have been recorded.';

  @override
  String get spaceModerationAdd => 'New moderation action';

  @override
  String get spaceModerationTarget => 'Member';

  @override
  String get spaceModerationAction => 'Action';

  @override
  String get spaceModerationReason => 'Reason';

  @override
  String get spaceModerationDuration => 'Duration';

  @override
  String get spaceModerationNoExpiry => 'Until revoked';

  @override
  String get spaceModerationOneHour => '1 hour';

  @override
  String get spaceModerationOneDay => '24 hours';

  @override
  String get spaceModerationOneWeek => '7 days';

  @override
  String get spaceModerationActive => 'Active';

  @override
  String get spaceModerationExpired => 'Expired';

  @override
  String get spaceModerationRevoked => 'Revoked';

  @override
  String get spaceModerationRevoke => 'Revoke action';

  @override
  String get spaceModerationRevokeReason => 'Reason for revocation';

  @override
  String get spaceModerationWarning => 'Warning';

  @override
  String get spaceModerationDeleteMessage => 'Remove message';

  @override
  String get spaceModerationDeletePost => 'Remove publication';

  @override
  String get spaceModerationRestrictPublishing =>
      'Temporarily restrict publications';

  @override
  String get spaceModerationRestrictMessages => 'Prevent sending messages';

  @override
  String get spaceModerationRestrictVoice => 'Prevent joining voice channels';

  @override
  String get spaceModerationMute => 'Mute messages and voice';

  @override
  String get spaceModerationTimeout => 'Timeout';

  @override
  String get spaceModerationTemporaryBan => 'Temporary ban';

  @override
  String get spaceModerationPermanentBan => 'Permanent ban';

  @override
  String spaceModerationUntil(String date) {
    return 'Until $date';
  }
}
