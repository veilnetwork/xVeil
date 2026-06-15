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
  String get chatRequestSent => 'Request sent — waiting for approval';

  @override
  String get chatBlockedContact => 'You blocked this contact';

  @override
  String get chatRequestHint => 'Write a connection request…';

  @override
  String get chatAttachTooltip => 'Attach a file';

  @override
  String get chatFileSave => 'Save';

  @override
  String get chatFileSaved => 'File saved';

  @override
  String get chatFileSaveFailed => 'Couldn\'t save the file';

  @override
  String get chatFileTooLarge => 'File is too large';

  @override
  String get chatMsgEdit => 'Edit';

  @override
  String get chatMsgDeleteForEveryone => 'Delete for everyone';

  @override
  String get chatMsgDeleteForMe => 'Delete for me';

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
  String get inviteCopyMine => 'Copy my invite';

  @override
  String get invitePasteTheirs => 'Paste their invite';

  @override
  String get inviteScanTooltip => 'Scan QR (coming soon)';

  @override
  String get inviteScanComingSoon => 'Camera scanning coming soon';

  @override
  String get inviteAddButton => 'Add contact';

  @override
  String get inviteInvalid => 'That is not a valid xVeil invite';

  @override
  String get networkRouteTitle => 'Route traffic (Proxy / VPN)';

  @override
  String get networkRouteSub => 'oproxy / ogate — coming soon';

  @override
  String get networkNodesTitle => 'My nodes';

  @override
  String get networkNodesSub => 'Add a node over SSH, run ogate/oproxy';

  @override
  String get networkExtTitle => 'Extensions (Lua)';

  @override
  String get networkExtSub => 'Load sandboxed add-ons';

  @override
  String get networkComingLater => 'Coming in a later milestone';

  @override
  String get networkStatusError => 'Error';

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
}
