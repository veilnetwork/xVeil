import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'xVeil'**
  String get appName;

  /// No description provided for @actionContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get actionContinue;

  /// No description provided for @actionBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// No description provided for @actionCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get actionCopy;

  /// No description provided for @actionUnderstood.
  ///
  /// In en, this message translates to:
  /// **'I understand'**
  String get actionUnderstood;

  /// No description provided for @preparingTitle.
  ///
  /// In en, this message translates to:
  /// **'Setting up your node'**
  String get preparingTitle;

  /// No description provided for @preparingBody.
  ///
  /// In en, this message translates to:
  /// **'Provisioning your identity on this device. This can take a little while — please wait.'**
  String get preparingBody;

  /// No description provided for @onboardWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to xVeil'**
  String get onboardWelcomeTitle;

  /// No description provided for @onboardWelcomeBody.
  ///
  /// In en, this message translates to:
  /// **'A decentralized, censorship-resistant messenger. No phone number. No central server. Your identity and your messages stay with you.'**
  String get onboardWelcomeBody;

  /// No description provided for @onboardChooseTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up your identity'**
  String get onboardChooseTitle;

  /// No description provided for @onboardCreateIdentity.
  ///
  /// In en, this message translates to:
  /// **'Create a new identity'**
  String get onboardCreateIdentity;

  /// No description provided for @onboardCreateIdentitySub.
  ///
  /// In en, this message translates to:
  /// **'Generate a fresh sovereign key on this device'**
  String get onboardCreateIdentitySub;

  /// No description provided for @onboardRestoreIdentity.
  ///
  /// In en, this message translates to:
  /// **'Restore from recovery phrase'**
  String get onboardRestoreIdentity;

  /// No description provided for @onboardRestoreIdentitySub.
  ///
  /// In en, this message translates to:
  /// **'Use your 24-word phrase to recover an existing identity'**
  String get onboardRestoreIdentitySub;

  /// No description provided for @onboardImportBackup.
  ///
  /// In en, this message translates to:
  /// **'Import a backup'**
  String get onboardImportBackup;

  /// No description provided for @onboardImportBackupSub.
  ///
  /// In en, this message translates to:
  /// **'Restore from an encrypted backup file'**
  String get onboardImportBackupSub;

  /// No description provided for @recoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Save your recovery phrase'**
  String get recoveryTitle;

  /// No description provided for @recoveryBody.
  ///
  /// In en, this message translates to:
  /// **'These 24 words ARE your identity. Anyone with them controls it; lose them and it is gone forever. Write them on paper and store them somewhere safe. Never store them online or photograph them.'**
  String get recoveryBody;

  /// No description provided for @recoveryConfirm.
  ///
  /// In en, this message translates to:
  /// **'I have written down my recovery phrase'**
  String get recoveryConfirm;

  /// No description provided for @storageTitle.
  ///
  /// In en, this message translates to:
  /// **'How should we store your data?'**
  String get storageTitle;

  /// No description provided for @storageHiddenTitle.
  ///
  /// In en, this message translates to:
  /// **'Hidden space (recommended)'**
  String get storageHiddenTitle;

  /// No description provided for @storageHiddenBody.
  ///
  /// In en, this message translates to:
  /// **'Your chats and keys live in a deniable encrypted container. An adversary who seizes your device cannot prove the data even exists.'**
  String get storageHiddenBody;

  /// No description provided for @storagePlainTitle.
  ///
  /// In en, this message translates to:
  /// **'Plain storage'**
  String get storagePlainTitle;

  /// No description provided for @storagePlainBody.
  ///
  /// In en, this message translates to:
  /// **'Faster to set up, but the existence of your data is visible to anyone who inspects the device.'**
  String get storagePlainBody;

  /// No description provided for @storagePlainWarning.
  ///
  /// In en, this message translates to:
  /// **'Not recommended for high-risk users. Choose this only if deniability is not a concern for you.'**
  String get storagePlainWarning;

  /// No description provided for @lockTitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock xVeil'**
  String get lockTitle;

  /// No description provided for @lockPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get lockPasswordHint;

  /// No description provided for @lockUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockUnlock;

  /// No description provided for @lockWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong password'**
  String get lockWrong;

  /// No description provided for @lockStartOver.
  ///
  /// In en, this message translates to:
  /// **'Start over'**
  String get lockStartOver;

  /// No description provided for @lockStartOverBody.
  ///
  /// In en, this message translates to:
  /// **'Set up a new identity on this device. Your existing data is not deleted, but you will need its password to reach it again. Continue?'**
  String get lockStartOverBody;

  /// No description provided for @navChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get navChats;

  /// No description provided for @navNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get navNetwork;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @chatsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get chatsEmpty;

  /// No description provided for @chatsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Start a new chat to begin messaging'**
  String get chatsEmptyHint;

  /// No description provided for @chatNewMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatNewMessageHint;

  /// No description provided for @chatSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSend;

  /// No description provided for @chatRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Request sent — waiting for approval'**
  String get chatRequestSent;

  /// No description provided for @chatBlockedContact.
  ///
  /// In en, this message translates to:
  /// **'You blocked this contact'**
  String get chatBlockedContact;

  /// No description provided for @chatRequestHint.
  ///
  /// In en, this message translates to:
  /// **'Write a connection request…'**
  String get chatRequestHint;

  /// No description provided for @chatAttachTooltip.
  ///
  /// In en, this message translates to:
  /// **'Attach a file'**
  String get chatAttachTooltip;

  /// No description provided for @chatFileSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get chatFileSave;

  /// No description provided for @chatFileSaved.
  ///
  /// In en, this message translates to:
  /// **'File saved'**
  String get chatFileSaved;

  /// No description provided for @chatFileSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the file'**
  String get chatFileSaveFailed;

  /// No description provided for @chatFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File is too large'**
  String get chatFileTooLarge;

  /// No description provided for @chatMsgEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatMsgEdit;

  /// No description provided for @chatMsgDeleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get chatMsgDeleteForEveryone;

  /// No description provided for @chatMsgDeleteForMe.
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get chatMsgDeleteForMe;

  /// No description provided for @chatEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get chatEditTitle;

  /// No description provided for @chatEditSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get chatEditSave;

  /// No description provided for @chatDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message?'**
  String get chatDeleteTitle;

  /// No description provided for @chatDeleteForMeBody.
  ///
  /// In en, this message translates to:
  /// **'It is permanently erased from this device.'**
  String get chatDeleteForMeBody;

  /// No description provided for @chatDeleteForEveryoneBody.
  ///
  /// In en, this message translates to:
  /// **'It is erased here and a delete request is sent to the other person — but they may already have seen or copied it.'**
  String get chatDeleteForEveryoneBody;

  /// No description provided for @chatDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatDeleteConfirm;

  /// No description provided for @chatEdited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get chatEdited;

  /// No description provided for @identityPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose an identity'**
  String get identityPickerTitle;

  /// No description provided for @identityPickerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This vault holds several identities — pick one to act as.'**
  String get identityPickerSubtitle;

  /// No description provided for @networkTitle.
  ///
  /// In en, this message translates to:
  /// **'Overlay network'**
  String get networkTitle;

  /// No description provided for @networkStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get networkStatusConnected;

  /// No description provided for @networkStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get networkStatusConnecting;

  /// No description provided for @networkStatusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get networkStatusOffline;

  /// No description provided for @networkPeers.
  ///
  /// In en, this message translates to:
  /// **'{count} peers'**
  String networkPeers(int count);

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get settingsIdentity;

  /// No description provided for @settingsStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage & spaces'**
  String get settingsStorage;

  /// No description provided for @settingsNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network & nodes'**
  String get settingsNetwork;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLockNow.
  ///
  /// In en, this message translates to:
  /// **'Lock now'**
  String get settingsLockNow;

  /// No description provided for @settingsSwitchIdentity.
  ///
  /// In en, this message translates to:
  /// **'Switch identity'**
  String get settingsSwitchIdentity;

  /// No description provided for @settingsAddIdentity.
  ///
  /// In en, this message translates to:
  /// **'Add identity'**
  String get settingsAddIdentity;

  /// No description provided for @addIdentityTitle.
  ///
  /// In en, this message translates to:
  /// **'Add identity'**
  String get addIdentityTitle;

  /// No description provided for @addIdentitySubtitle.
  ///
  /// In en, this message translates to:
  /// **'A new identity is hidden in the same file. The first time you add one, your current identity and the new one are managed by a master password you set below.'**
  String get addIdentitySubtitle;

  /// No description provided for @addIdentityCurrentName.
  ///
  /// In en, this message translates to:
  /// **'Name for your current identity'**
  String get addIdentityCurrentName;

  /// No description provided for @addIdentityNewName.
  ///
  /// In en, this message translates to:
  /// **'New identity name'**
  String get addIdentityNewName;

  /// No description provided for @addIdentityNewPassword.
  ///
  /// In en, this message translates to:
  /// **'New identity password'**
  String get addIdentityNewPassword;

  /// No description provided for @addIdentityMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Master password'**
  String get addIdentityMasterPassword;

  /// No description provided for @addIdentityMasterHint.
  ///
  /// In en, this message translates to:
  /// **'Unlocks the identity chooser. Must be different from each identity\'s own password.'**
  String get addIdentityMasterHint;

  /// No description provided for @addIdentityCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get addIdentityCreate;

  /// No description provided for @addIdentityIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Fill in every field.'**
  String get addIdentityIncomplete;

  /// No description provided for @addIdentityClash.
  ///
  /// In en, this message translates to:
  /// **'That master password is already used by an identity — choose a different one.'**
  String get addIdentityClash;

  /// No description provided for @addIdentityWorking.
  ///
  /// In en, this message translates to:
  /// **'Setting up your new identity…\nThis can take a few seconds.'**
  String get addIdentityWorking;

  /// No description provided for @settingsDecoyMaster.
  ///
  /// In en, this message translates to:
  /// **'Set up decoy access'**
  String get settingsDecoyMaster;

  /// No description provided for @decoyTitle.
  ///
  /// In en, this message translates to:
  /// **'Decoy (duress) access'**
  String get decoyTitle;

  /// No description provided for @decoySubtitle.
  ///
  /// In en, this message translates to:
  /// **'A separate password that, under coercion, opens only the identities you tick below. Your real master and every other identity stay hidden.'**
  String get decoySubtitle;

  /// No description provided for @decoyWarning.
  ///
  /// In en, this message translates to:
  /// **'Anyone you give this password to sees the FULL content of every identity you tick. Include only genuinely safe ones.'**
  String get decoyWarning;

  /// No description provided for @decoyPassword.
  ///
  /// In en, this message translates to:
  /// **'Duress password'**
  String get decoyPassword;

  /// No description provided for @decoyInclude.
  ///
  /// In en, this message translates to:
  /// **'Identities to show under duress'**
  String get decoyInclude;

  /// No description provided for @decoyCreate.
  ///
  /// In en, this message translates to:
  /// **'Create decoy access'**
  String get decoyCreate;

  /// No description provided for @decoyCreated.
  ///
  /// In en, this message translates to:
  /// **'Decoy access created.'**
  String get decoyCreated;

  /// No description provided for @decoyPickOne.
  ///
  /// In en, this message translates to:
  /// **'Select at least one identity.'**
  String get decoyPickOne;

  /// No description provided for @decoyClash.
  ///
  /// In en, this message translates to:
  /// **'That password is already in use — choose a different one.'**
  String get decoyClash;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystem;

  /// No description provided for @languageRussian.
  ///
  /// In en, this message translates to:
  /// **'Русский'**
  String get languageRussian;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @chatRequestTitle.
  ///
  /// In en, this message translates to:
  /// **'This contact wants to connect'**
  String get chatRequestTitle;

  /// No description provided for @actionAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get actionAccept;

  /// No description provided for @actionBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get actionBlock;

  /// No description provided for @actionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get actionOpen;

  /// No description provided for @inviteAddContact.
  ///
  /// In en, this message translates to:
  /// **'Add a contact'**
  String get inviteAddContact;

  /// No description provided for @inviteShowToContact.
  ///
  /// In en, this message translates to:
  /// **'Show this to your contact'**
  String get inviteShowToContact;

  /// No description provided for @inviteTooLarge.
  ///
  /// In en, this message translates to:
  /// **'invite too large'**
  String get inviteTooLarge;

  /// No description provided for @inviteCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite copied'**
  String get inviteCopied;

  /// No description provided for @inviteCopyMine.
  ///
  /// In en, this message translates to:
  /// **'Copy my invite'**
  String get inviteCopyMine;

  /// No description provided for @invitePasteTheirs.
  ///
  /// In en, this message translates to:
  /// **'Paste their invite'**
  String get invitePasteTheirs;

  /// No description provided for @inviteScanTooltip.
  ///
  /// In en, this message translates to:
  /// **'Scan QR (coming soon)'**
  String get inviteScanTooltip;

  /// No description provided for @inviteScanComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Camera scanning coming soon'**
  String get inviteScanComingSoon;

  /// No description provided for @inviteAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get inviteAddButton;

  /// No description provided for @inviteInvalid.
  ///
  /// In en, this message translates to:
  /// **'That is not a valid xVeil invite'**
  String get inviteInvalid;

  /// No description provided for @networkRouteTitle.
  ///
  /// In en, this message translates to:
  /// **'Route traffic (Proxy / VPN)'**
  String get networkRouteTitle;

  /// No description provided for @networkRouteSub.
  ///
  /// In en, this message translates to:
  /// **'oproxy / ogate — coming soon'**
  String get networkRouteSub;

  /// No description provided for @networkNodesTitle.
  ///
  /// In en, this message translates to:
  /// **'My nodes'**
  String get networkNodesTitle;

  /// No description provided for @networkNodesSub.
  ///
  /// In en, this message translates to:
  /// **'Add a node over SSH, run ogate/oproxy'**
  String get networkNodesSub;

  /// No description provided for @networkExtTitle.
  ///
  /// In en, this message translates to:
  /// **'Extensions (Lua)'**
  String get networkExtTitle;

  /// No description provided for @networkExtSub.
  ///
  /// In en, this message translates to:
  /// **'Load sandboxed add-ons'**
  String get networkExtSub;

  /// No description provided for @networkComingLater.
  ///
  /// In en, this message translates to:
  /// **'Coming in a later milestone'**
  String get networkComingLater;

  /// No description provided for @networkStatusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get networkStatusError;

  /// No description provided for @onboardRepeatPassword.
  ///
  /// In en, this message translates to:
  /// **'Repeat password'**
  String get onboardRepeatPassword;

  /// No description provided for @onboardPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Set a password'**
  String get onboardPasswordTitle;

  /// No description provided for @onboardPasswordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This password unlocks your space on this device. There is no reset.'**
  String get onboardPasswordSubtitle;

  /// No description provided for @onboardPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Use at least 6 characters'**
  String get onboardPasswordTooShort;

  /// No description provided for @onboardPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get onboardPasswordMismatch;

  /// No description provided for @onboardComingSoon.
  ///
  /// In en, this message translates to:
  /// **'{label} — coming in the next milestone'**
  String onboardComingSoon(String label);

  /// No description provided for @recoveryPhraseHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your recovery phrase, words separated by spaces'**
  String get recoveryPhraseHint;

  /// No description provided for @demoChatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Demo chat'**
  String get demoChatTooltip;

  /// No description provided for @demoNewChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get demoNewChat;

  /// No description provided for @demoPeerNodeId.
  ///
  /// In en, this message translates to:
  /// **'Peer node id (hex)'**
  String get demoPeerNodeId;

  /// No description provided for @demoChatWith.
  ///
  /// In en, this message translates to:
  /// **'Chat with a demo peer'**
  String get demoChatWith;
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppL10nEn();
    case 'ru':
      return AppL10nRu();
  }

  throw FlutterError(
    'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
