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

  /// No description provided for @preparingFirstRunTitle.
  ///
  /// In en, this message translates to:
  /// **'Creating this identity'**
  String get preparingFirstRunTitle;

  /// No description provided for @preparingFirstRunBody.
  ///
  /// In en, this message translates to:
  /// **'A one-time setup that can take up to a minute (a proof-of-work that makes the identity hard to forge). It only runs the first time — switching to it later is instant.'**
  String get preparingFirstRunBody;

  /// No description provided for @preparingUnlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Opening your container'**
  String get preparingUnlockTitle;

  /// No description provided for @preparingUnlockBody.
  ///
  /// In en, this message translates to:
  /// **'Deriving your key and decrypting on this device — this is deliberately slow to resist guessing. Please wait a moment.'**
  String get preparingUnlockBody;

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

  /// No description provided for @onboardRestoreBody.
  ///
  /// In en, this message translates to:
  /// **'Enter the 24-word recovery phrase you wrote down when the identity was created. The same identity will be recreated on this device.'**
  String get onboardRestoreBody;

  /// No description provided for @onboardRestoreSubmit.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get onboardRestoreSubmit;

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

  /// No description provided for @lockWipe.
  ///
  /// In en, this message translates to:
  /// **'Clear all data'**
  String get lockWipe;

  /// No description provided for @lockWipeBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes the container and EVERY identity inside it — including any hidden or decoy ones. This cannot be undone: without the container the data is unrecoverable, even with the right password.'**
  String get lockWipeBody;

  /// No description provided for @lockWipeTypePrompt.
  ///
  /// In en, this message translates to:
  /// **'To confirm permanent deletion, type this phrase exactly:'**
  String get lockWipeTypePrompt;

  /// No description provided for @lockWipePhrase.
  ///
  /// In en, this message translates to:
  /// **'I understand the consequences'**
  String get lockWipePhrase;

  /// No description provided for @lockWipeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete forever'**
  String get lockWipeConfirm;

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

  /// No description provided for @navCalls.
  ///
  /// In en, this message translates to:
  /// **'Calls'**
  String get navCalls;

  /// No description provided for @callLogEmpty.
  ///
  /// In en, this message translates to:
  /// **'No calls yet'**
  String get callLogEmpty;

  /// No description provided for @callLogEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Calls you make and receive on any of your devices will appear here'**
  String get callLogEmptyHint;

  /// No description provided for @callOutcomeMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get callOutcomeMissed;

  /// No description provided for @callOutcomeDeclined.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get callOutcomeDeclined;

  /// No description provided for @callOutcomeCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get callOutcomeCancelled;

  /// No description provided for @callOutcomeBusy.
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get callOutcomeBusy;

  /// No description provided for @callOutcomeFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get callOutcomeFailed;

  /// No description provided for @channelsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No channels yet'**
  String get channelsEmpty;

  /// No description provided for @channelsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Channels — owner-signed broadcast feeds — are coming in a future update. Your group chats now live in the Chats tab.'**
  String get channelsEmptyHint;

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

  /// No description provided for @notificationNewMessage.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get notificationNewMessage;

  /// No description provided for @notificationReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get notificationReply;

  /// No description provided for @notificationReplyHint.
  ///
  /// In en, this message translates to:
  /// **'Message…'**
  String get notificationReplyHint;

  /// No description provided for @notificationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsTitle;

  /// No description provided for @notificationsEnabled.
  ///
  /// In en, this message translates to:
  /// **'Show notifications'**
  String get notificationsEnabled;

  /// No description provided for @notificationsPreview.
  ///
  /// In en, this message translates to:
  /// **'Message preview'**
  String get notificationsPreview;

  /// No description provided for @notificationsPreviewHidden.
  ///
  /// In en, this message translates to:
  /// **'Hidden (“new message”, no sender or text)'**
  String get notificationsPreviewHidden;

  /// No description provided for @notificationsPreviewFull.
  ///
  /// In en, this message translates to:
  /// **'Full (sender and text)'**
  String get notificationsPreviewFull;

  /// No description provided for @chatRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Request sent — waiting for approval'**
  String get chatRequestSent;

  /// No description provided for @chatRequestResend.
  ///
  /// In en, this message translates to:
  /// **'Send again'**
  String get chatRequestResend;

  /// No description provided for @chatRequestCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatRequestCancel;

  /// No description provided for @chatRequestCancelTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel request?'**
  String get chatRequestCancelTitle;

  /// No description provided for @chatRequestCancelBody.
  ///
  /// In en, this message translates to:
  /// **'Removes this request and conversation from your device. If it already reached them, they may have seen it.'**
  String get chatRequestCancelBody;

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

  /// No description provided for @chatVoiceHold.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a voice message'**
  String get chatVoiceHold;

  /// No description provided for @chatVoiceSlideCancel.
  ///
  /// In en, this message translates to:
  /// **'Slide to cancel'**
  String get chatVoiceSlideCancel;

  /// No description provided for @chatVoiceReleaseCancel.
  ///
  /// In en, this message translates to:
  /// **'Release to cancel'**
  String get chatVoiceReleaseCancel;

  /// No description provided for @chatVoiceMicDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone access denied'**
  String get chatVoiceMicDenied;

  /// No description provided for @chatVoiceTooltip.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get chatVoiceTooltip;

  /// No description provided for @chatVnoteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Video message'**
  String get chatVnoteTooltip;

  /// No description provided for @stickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Stickers'**
  String get stickerTitle;

  /// No description provided for @stickerImport.
  ///
  /// In en, this message translates to:
  /// **'Import from photos'**
  String get stickerImport;

  /// No description provided for @groupCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get groupCreateTitle;

  /// No description provided for @groupCreateAction.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get groupCreateAction;

  /// No description provided for @groupNameHint.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNameHint;

  /// No description provided for @groupEmpty.
  ///
  /// In en, this message translates to:
  /// **'No groups yet'**
  String get groupEmpty;

  /// No description provided for @groupNoMessages.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get groupNoMessages;

  /// No description provided for @groupMembersTooltip.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get groupMembersTooltip;

  /// No description provided for @groupRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename group'**
  String get groupRenameTitle;

  /// No description provided for @groupRenameAction.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get groupRenameAction;

  /// No description provided for @groupRenameDenied.
  ///
  /// In en, this message translates to:
  /// **'You don\'t have permission to rename this group'**
  String get groupRenameDenied;

  /// No description provided for @groupMembers.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String groupMembers(int count);

  /// No description provided for @groupReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get groupReply;

  /// No description provided for @groupAddMember.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get groupAddMember;

  /// No description provided for @groupMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get groupMute;

  /// No description provided for @groupUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get groupUnmute;

  /// No description provided for @groupPromote.
  ///
  /// In en, this message translates to:
  /// **'Make admin'**
  String get groupPromote;

  /// No description provided for @groupDemote.
  ///
  /// In en, this message translates to:
  /// **'Remove admin'**
  String get groupDemote;

  /// No description provided for @groupRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from group'**
  String get groupRemove;

  /// No description provided for @groupLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get groupLeave;

  /// No description provided for @groupLeaveConfirm.
  ///
  /// In en, this message translates to:
  /// **'You will stop receiving this group\'s messages.'**
  String get groupLeaveConfirm;

  /// No description provided for @groupNoContactsToAdd.
  ///
  /// In en, this message translates to:
  /// **'No contacts left to add'**
  String get groupNoContactsToAdd;

  /// No description provided for @groupAttachImage.
  ///
  /// In en, this message translates to:
  /// **'Send image'**
  String get groupAttachImage;

  /// No description provided for @groupSendSticker.
  ///
  /// In en, this message translates to:
  /// **'Send sticker'**
  String get groupSendSticker;

  /// No description provided for @groupImageOnly.
  ///
  /// In en, this message translates to:
  /// **'Pick an image file'**
  String get groupImageOnly;

  /// No description provided for @groupImageTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Image too large to send inline'**
  String get groupImageTooLarge;

  /// No description provided for @groupVnoteRecord.
  ///
  /// In en, this message translates to:
  /// **'Record video note'**
  String get groupVnoteRecord;

  /// No description provided for @groupVoiceRecord.
  ///
  /// In en, this message translates to:
  /// **'Record voice message'**
  String get groupVoiceRecord;

  /// No description provided for @groupVoiceStop.
  ///
  /// In en, this message translates to:
  /// **'Stop and send'**
  String get groupVoiceStop;

  /// No description provided for @groupVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get groupVoiceMessage;

  /// No description provided for @groupVoiceTooLong.
  ///
  /// In en, this message translates to:
  /// **'Voice message is too long to send in a group'**
  String get groupVoiceTooLong;

  /// No description provided for @reactorsTitle.
  ///
  /// In en, this message translates to:
  /// **'Reactions'**
  String get reactorsTitle;

  /// No description provided for @reactorsYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get reactorsYou;

  /// No description provided for @settingsShowReactions.
  ///
  /// In en, this message translates to:
  /// **'Show reactions'**
  String get settingsShowReactions;

  /// No description provided for @settingsShowReactionsHint.
  ///
  /// In en, this message translates to:
  /// **'Reaction chips under messages and the quick-react bar in the message menu. Hiding is local only — reactions keep syncing.'**
  String get settingsShowReactionsHint;

  /// No description provided for @stickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No stickers yet — import your own pictures'**
  String get stickerEmpty;

  /// No description provided for @stickerSharePack.
  ///
  /// In en, this message translates to:
  /// **'Share pack'**
  String get stickerSharePack;

  /// No description provided for @stickerPackTitle.
  ///
  /// In en, this message translates to:
  /// **'Sticker pack'**
  String get stickerPackTitle;

  /// No description provided for @stickerPackDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get stickerPackDownload;

  /// No description provided for @stickerPackInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get stickerPackInstall;

  /// No description provided for @stickerImported.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 sticker added} other{{count} stickers added}}'**
  String stickerImported(int count);

  /// No description provided for @chatVnoteDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera or microphone access denied'**
  String get chatVnoteDenied;

  /// No description provided for @chatVoiceRecordFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t record — try again'**
  String get chatVoiceRecordFailed;

  /// No description provided for @chatVoiceTranscribe.
  ///
  /// In en, this message translates to:
  /// **'Transcribe'**
  String get chatVoiceTranscribe;

  /// No description provided for @chatVoiceTranscribing.
  ///
  /// In en, this message translates to:
  /// **'Transcribing…'**
  String get chatVoiceTranscribing;

  /// No description provided for @chatVoiceTranscribeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t transcribe'**
  String get chatVoiceTranscribeFailed;

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

  /// No description provided for @chatFileUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the file'**
  String get chatFileUnreadable;

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

  /// No description provided for @chatMsgCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy text'**
  String get chatMsgCopy;

  /// No description provided for @chatMsgCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get chatMsgCopied;

  /// No description provided for @chatLoadEarlier.
  ///
  /// In en, this message translates to:
  /// **'Load earlier messages'**
  String get chatLoadEarlier;

  /// No description provided for @settingsChatPageSize.
  ///
  /// In en, this message translates to:
  /// **'Messages per page'**
  String get settingsChatPageSize;

  /// No description provided for @settingsChatPageSizeHint.
  ///
  /// In en, this message translates to:
  /// **'How many recent messages a chat loads; older ones load on demand'**
  String get settingsChatPageSizeHint;

  /// No description provided for @settingsCloseToTray.
  ///
  /// In en, this message translates to:
  /// **'Close to tray'**
  String get settingsCloseToTray;

  /// No description provided for @settingsCloseToTrayHint.
  ///
  /// In en, this message translates to:
  /// **'Closing the window hides it to the system tray and keeps running, so messages and notifications keep arriving. Off = closing quits.'**
  String get settingsCloseToTrayHint;

  /// No description provided for @navChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get navChannels;

  /// No description provided for @navStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get navStorage;

  /// No description provided for @navMenuTiles.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get navMenuTiles;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @cloudTitle.
  ///
  /// In en, this message translates to:
  /// **'Personal cloud'**
  String get cloudTitle;

  /// No description provided for @cloudUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync is unavailable until the node is ready'**
  String get cloudUnavailable;

  /// No description provided for @cloudEmpty.
  ///
  /// In en, this message translates to:
  /// **'Your cloud is empty'**
  String get cloudEmpty;

  /// No description provided for @cloudEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Files and notes are encrypted locally and replicated only between your own linked devices.'**
  String get cloudEmptyHint;

  /// No description provided for @cloudAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to cloud'**
  String get cloudAdd;

  /// No description provided for @cloudAddFile.
  ///
  /// In en, this message translates to:
  /// **'Add file'**
  String get cloudAddFile;

  /// No description provided for @cloudAddNote.
  ///
  /// In en, this message translates to:
  /// **'New note'**
  String get cloudAddNote;

  /// No description provided for @cloudImported.
  ///
  /// In en, this message translates to:
  /// **'File added to your cloud'**
  String get cloudImported;

  /// No description provided for @cloudImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not import the file'**
  String get cloudImportFailed;

  /// No description provided for @cloudLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the cloud index'**
  String get cloudLoadFailed;

  /// No description provided for @cloudReplication.
  ///
  /// In en, this message translates to:
  /// **'Keep on this device'**
  String get cloudReplication;

  /// No description provided for @cloudModeAll.
  ///
  /// In en, this message translates to:
  /// **'Everything'**
  String get cloudModeAll;

  /// No description provided for @cloudModeSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get cloudModeSelected;

  /// No description provided for @cloudModeIndex.
  ///
  /// In en, this message translates to:
  /// **'Index only'**
  String get cloudModeIndex;

  /// No description provided for @cloudModeAllHint.
  ///
  /// In en, this message translates to:
  /// **'Automatically download every cloud item'**
  String get cloudModeAllHint;

  /// No description provided for @cloudModeSelectedHint.
  ///
  /// In en, this message translates to:
  /// **'Automatically download selected items'**
  String get cloudModeSelectedHint;

  /// No description provided for @cloudModeIndexHint.
  ///
  /// In en, this message translates to:
  /// **'Show the index and download only on demand'**
  String get cloudModeIndexHint;

  /// No description provided for @cloudLocal.
  ///
  /// In en, this message translates to:
  /// **'on this device'**
  String get cloudLocal;

  /// No description provided for @cloudRemote.
  ///
  /// In en, this message translates to:
  /// **'in cloud'**
  String get cloudRemote;

  /// No description provided for @cloudReplicas.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{no verified copies} =1{1 verified copy} other{{count} verified copies}}'**
  String cloudReplicas(int count);

  /// No description provided for @cloudDownload.
  ///
  /// In en, this message translates to:
  /// **'Download to this device'**
  String get cloudDownload;

  /// No description provided for @cloudShare.
  ///
  /// In en, this message translates to:
  /// **'Share with contact'**
  String get cloudShare;

  /// No description provided for @cloudShareTitle.
  ///
  /// In en, this message translates to:
  /// **'Share with'**
  String get cloudShareTitle;

  /// No description provided for @cloudNoContacts.
  ///
  /// In en, this message translates to:
  /// **'No accepted contacts to share with'**
  String get cloudNoContacts;

  /// No description provided for @cloudShared.
  ///
  /// In en, this message translates to:
  /// **'File shared'**
  String get cloudShared;

  /// No description provided for @cloudShareFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not share the file'**
  String get cloudShareFailed;

  /// No description provided for @cloudPublicLink.
  ///
  /// In en, this message translates to:
  /// **'Private link'**
  String get cloudPublicLink;

  /// No description provided for @cloudPublicCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get cloudPublicCopy;

  /// No description provided for @cloudPublicCopied.
  ///
  /// In en, this message translates to:
  /// **'Private link copied'**
  String get cloudPublicCopied;

  /// No description provided for @cloudPublicRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke link'**
  String get cloudPublicRevoke;

  /// No description provided for @cloudPublicRevoked.
  ///
  /// In en, this message translates to:
  /// **'Link revoked; existing downloads cannot be erased'**
  String get cloudPublicRevoked;

  /// No description provided for @cloudPublicFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not create the private link'**
  String get cloudPublicFailed;

  /// No description provided for @cloudPublicImport.
  ///
  /// In en, this message translates to:
  /// **'Open private link'**
  String get cloudPublicImport;

  /// No description provided for @cloudPublicPasteHint.
  ///
  /// In en, this message translates to:
  /// **'Paste an xveil://cloud link'**
  String get cloudPublicPasteHint;

  /// No description provided for @cloudPublicOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open or verify the private link'**
  String get cloudPublicOpenFailed;

  /// No description provided for @cloudSelect.
  ///
  /// In en, this message translates to:
  /// **'Keep selected'**
  String get cloudSelect;

  /// No description provided for @cloudUnselect.
  ///
  /// In en, this message translates to:
  /// **'Stop keeping selected'**
  String get cloudUnselect;

  /// No description provided for @cloudVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify and repair'**
  String get cloudVerify;

  /// No description provided for @cloudVerifyOk.
  ///
  /// In en, this message translates to:
  /// **'Local cloud files passed verification'**
  String get cloudVerifyOk;

  /// No description provided for @cloudRepairStarted.
  ///
  /// In en, this message translates to:
  /// **'Repair requested for {count} damaged files'**
  String cloudRepairStarted(int count);

  /// No description provided for @cloudDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get cloudDelete;

  /// No description provided for @cloudDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete from your cloud?'**
  String get cloudDeleteTitle;

  /// No description provided for @cloudDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'The item will disappear from every linked device. This cannot be undone.'**
  String get cloudDeleteBody;

  /// No description provided for @cloudNoteNew.
  ///
  /// In en, this message translates to:
  /// **'New note'**
  String get cloudNoteNew;

  /// No description provided for @cloudNoteEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit note'**
  String get cloudNoteEdit;

  /// No description provided for @cloudNoteTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get cloudNoteTitleHint;

  /// No description provided for @cloudNoteBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Write a private note…'**
  String get cloudNoteBodyHint;

  /// No description provided for @cloudNoteSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get cloudNoteSave;

  /// No description provided for @cloudNoteSaved.
  ///
  /// In en, this message translates to:
  /// **'Note saved'**
  String get cloudNoteSaved;

  /// No description provided for @cloudNoteLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load or verify the note'**
  String get cloudNoteLoadFailed;

  /// No description provided for @cloudNoteSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the note'**
  String get cloudNoteSaveFailed;

  /// No description provided for @cloudNoteTitleRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a title'**
  String get cloudNoteTitleRequired;

  /// No description provided for @cloudNoteTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The note is too large (maximum 1 MiB)'**
  String get cloudNoteTooLarge;

  /// No description provided for @cloudNoteConflictTitle.
  ///
  /// In en, this message translates to:
  /// **'This note changed on another device'**
  String get cloudNoteConflictTitle;

  /// No description provided for @cloudNoteConflictBody.
  ///
  /// In en, this message translates to:
  /// **'Review the current cloud version and merge it with your draft before saving.'**
  String get cloudNoteConflictBody;

  /// No description provided for @cloudNoteRemoteVersion.
  ///
  /// In en, this message translates to:
  /// **'Current cloud version'**
  String get cloudNoteRemoteVersion;

  /// No description provided for @cloudNoteYourDraft.
  ///
  /// In en, this message translates to:
  /// **'Your merged draft'**
  String get cloudNoteYourDraft;

  /// No description provided for @cloudNoteUseRemote.
  ///
  /// In en, this message translates to:
  /// **'Use cloud version'**
  String get cloudNoteUseRemote;

  /// No description provided for @cloudNoteSaveMerged.
  ///
  /// In en, this message translates to:
  /// **'Save merged version'**
  String get cloudNoteSaveMerged;

  /// No description provided for @cloudNoteBranches.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 version} other{{count} offline versions}} preserved'**
  String cloudNoteBranches(int count);

  /// No description provided for @cloudNoteReviewBranches.
  ///
  /// In en, this message translates to:
  /// **'Review versions'**
  String get cloudNoteReviewBranches;

  /// No description provided for @cloudNoteVersion.
  ///
  /// In en, this message translates to:
  /// **'Preserved version {number}'**
  String cloudNoteVersion(int number);

  /// No description provided for @cloudNoteBranchesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Download every preserved version before merging'**
  String get cloudNoteBranchesUnavailable;

  /// No description provided for @cloudNoteMergeReady.
  ///
  /// In en, this message translates to:
  /// **'Merge prepared — save the note to resolve every version'**
  String get cloudNoteMergeReady;

  /// No description provided for @settingsCatAccount.
  ///
  /// In en, this message translates to:
  /// **'Identities & account'**
  String get settingsCatAccount;

  /// No description provided for @settingsCatAccountHint.
  ///
  /// In en, this message translates to:
  /// **'Switch, add, manage, anonymity'**
  String get settingsCatAccountHint;

  /// No description provided for @settingsCatPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get settingsCatPrivacy;

  /// No description provided for @settingsCatPrivacyHint.
  ///
  /// In en, this message translates to:
  /// **'P2P policy, signature requests'**
  String get settingsCatPrivacyHint;

  /// No description provided for @settingsCatChats.
  ///
  /// In en, this message translates to:
  /// **'Chats & notifications'**
  String get settingsCatChats;

  /// No description provided for @settingsCatChatsHint.
  ///
  /// In en, this message translates to:
  /// **'Notifications, background delivery, page size'**
  String get settingsCatChatsHint;

  /// No description provided for @settingsCatData.
  ///
  /// In en, this message translates to:
  /// **'Data & storage'**
  String get settingsCatData;

  /// No description provided for @settingsCatDataHint.
  ///
  /// In en, this message translates to:
  /// **'Container size, compaction, files'**
  String get settingsCatDataHint;

  /// No description provided for @settingsCatAppearanceHint.
  ///
  /// In en, this message translates to:
  /// **'Language, folders panel'**
  String get settingsCatAppearanceHint;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchHint;

  /// No description provided for @searchMessagesSection.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get searchMessagesSection;

  /// No description provided for @searchNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get searchNoResults;

  /// No description provided for @chatMsgPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get chatMsgPin;

  /// No description provided for @chatMsgUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get chatMsgUnpin;

  /// No description provided for @chatPinnedLabel.
  ///
  /// In en, this message translates to:
  /// **'Pinned message'**
  String get chatPinnedLabel;

  /// No description provided for @savedMessages.
  ///
  /// In en, this message translates to:
  /// **'Saved Messages'**
  String get savedMessages;

  /// No description provided for @savedNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Note to self…'**
  String get savedNoteHint;

  /// No description provided for @chatFormatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Formatting'**
  String get chatFormatTooltip;

  /// No description provided for @chatFormatBold.
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get chatFormatBold;

  /// No description provided for @chatFormatItalic.
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get chatFormatItalic;

  /// No description provided for @chatFormatUnderline.
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get chatFormatUnderline;

  /// No description provided for @chatFormatStrike.
  ///
  /// In en, this message translates to:
  /// **'Strikethrough'**
  String get chatFormatStrike;

  /// No description provided for @chatFormatCode.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get chatFormatCode;

  /// No description provided for @chatFormatSpoiler.
  ///
  /// In en, this message translates to:
  /// **'Spoiler'**
  String get chatFormatSpoiler;

  /// No description provided for @chatFormatQuote.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get chatFormatQuote;

  /// No description provided for @chatLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get chatLinkCopied;

  /// No description provided for @chatCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Code copied'**
  String get chatCodeCopied;

  /// No description provided for @linkDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Open link?'**
  String get linkDialogTitle;

  /// No description provided for @linkOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get linkOpen;

  /// No description provided for @linkCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get linkCopy;

  /// No description provided for @linkOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the link'**
  String get linkOpenFailed;

  /// No description provided for @p2pSelectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Selected contacts'**
  String get p2pSelectedTitle;

  /// No description provided for @p2pSelectedHint.
  ///
  /// In en, this message translates to:
  /// **'Contacts allowed direct P2P under the \"Only selected\" policy. Turn one on to grant it; off follows the global policy.'**
  String get p2pSelectedHint;

  /// No description provided for @p2pSelectedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No accepted contacts yet'**
  String get p2pSelectedEmpty;

  /// No description provided for @trayShow.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get trayShow;

  /// No description provided for @trayHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get trayHide;

  /// No description provided for @trayIdentities.
  ///
  /// In en, this message translates to:
  /// **'Identities'**
  String get trayIdentities;

  /// No description provided for @trayLock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get trayLock;

  /// No description provided for @trayQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get trayQuit;

  /// No description provided for @trayUnread.
  ///
  /// In en, this message translates to:
  /// **'{count} unread'**
  String trayUnread(String count);

  /// No description provided for @chatListDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get chatListDelete;

  /// No description provided for @chatDeleteChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this chat?'**
  String get chatDeleteChatTitle;

  /// No description provided for @chatDeleteChatBody.
  ///
  /// In en, this message translates to:
  /// **'The conversation and all its messages are erased from this device. The other person is not notified.'**
  String get chatDeleteChatBody;

  /// No description provided for @chatDeleteNotifyPeer.
  ///
  /// In en, this message translates to:
  /// **'Notify the other person'**
  String get chatDeleteNotifyPeer;

  /// No description provided for @chatDeletedByPeer.
  ///
  /// In en, this message translates to:
  /// **'The other person deleted this chat on their device'**
  String get chatDeletedByPeer;

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

  /// No description provided for @chatMenuRetention.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete'**
  String get chatMenuRetention;

  /// No description provided for @retentionUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get retentionUnlimited;

  /// No description provided for @retention7.
  ///
  /// In en, this message translates to:
  /// **'After 1 week'**
  String get retention7;

  /// No description provided for @retention30.
  ///
  /// In en, this message translates to:
  /// **'After 1 month'**
  String get retention30;

  /// No description provided for @retention90.
  ///
  /// In en, this message translates to:
  /// **'After 3 months'**
  String get retention90;

  /// No description provided for @retention365.
  ///
  /// In en, this message translates to:
  /// **'After 1 year'**
  String get retention365;

  /// No description provided for @retentionCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get retentionCustom;

  /// No description provided for @retentionCustomN.
  ///
  /// In en, this message translates to:
  /// **'Custom ({days} days)'**
  String retentionCustomN(int days);

  /// No description provided for @retentionCustomTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete after (days)'**
  String get retentionCustomTitle;

  /// No description provided for @retentionDaysSuffix.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get retentionDaysSuffix;

  /// No description provided for @retentionApplied.
  ///
  /// In en, this message translates to:
  /// **'Older messages will be deleted'**
  String get retentionApplied;

  /// No description provided for @chatMenuRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get chatMenuRename;

  /// No description provided for @chatRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Local name'**
  String get chatRenameTitle;

  /// No description provided for @chatMenuPin.
  ///
  /// In en, this message translates to:
  /// **'Pin to top'**
  String get chatMenuPin;

  /// No description provided for @chatMenuUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get chatMenuUnpin;

  /// No description provided for @chatMenuMute.
  ///
  /// In en, this message translates to:
  /// **'Mute notifications'**
  String get chatMenuMute;

  /// No description provided for @chatMenuUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute notifications'**
  String get chatMenuUnmute;

  /// No description provided for @chatMenuMarkRead.
  ///
  /// In en, this message translates to:
  /// **'Mark as read'**
  String get chatMenuMarkRead;

  /// No description provided for @chatMenuArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get chatMenuArchive;

  /// No description provided for @chatMenuUnarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get chatMenuUnarchive;

  /// No description provided for @chatsArchiveSection.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get chatsArchiveSection;

  /// No description provided for @chatMenuFolders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get chatMenuFolders;

  /// No description provided for @chatsFolderAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get chatsFolderAll;

  /// No description provided for @chatsFolderNew.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get chatsFolderNew;

  /// No description provided for @chatsFolderName.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get chatsFolderName;

  /// No description provided for @chatsFolderRename.
  ///
  /// In en, this message translates to:
  /// **'Rename folder'**
  String get chatsFolderRename;

  /// No description provided for @chatsFolderDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete folder'**
  String get chatsFolderDelete;

  /// No description provided for @chatsFolderUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get chatsFolderUnnamed;

  /// No description provided for @chatsFolderEmpty.
  ///
  /// In en, this message translates to:
  /// **'No chats in this folder'**
  String get chatsFolderEmpty;

  /// No description provided for @chatsFolderNoneYet.
  ///
  /// In en, this message translates to:
  /// **'No folders yet'**
  String get chatsFolderNoneYet;

  /// No description provided for @chatMsgRequestSignature.
  ///
  /// In en, this message translates to:
  /// **'Request signature'**
  String get chatMsgRequestSignature;

  /// No description provided for @chatSignatureRequested.
  ///
  /// In en, this message translates to:
  /// **'Signature requested'**
  String get chatSignatureRequested;

  /// No description provided for @chatSignaturePending.
  ///
  /// In en, this message translates to:
  /// **'Awaiting the author\'s signature'**
  String get chatSignaturePending;

  /// No description provided for @chatSignatureVerified.
  ///
  /// In en, this message translates to:
  /// **'Authorship verified'**
  String get chatSignatureVerified;

  /// No description provided for @chatSignatureRefused.
  ///
  /// In en, this message translates to:
  /// **'The author declined to sign'**
  String get chatSignatureRefused;

  /// No description provided for @chatSignatureFailed.
  ///
  /// In en, this message translates to:
  /// **'Signature did not verify'**
  String get chatSignatureFailed;

  /// No description provided for @signatureAskTitle.
  ///
  /// In en, this message translates to:
  /// **'{who} asks you to confirm you wrote the message below'**
  String signatureAskTitle(String who);

  /// No description provided for @signatureAskConfirm.
  ///
  /// In en, this message translates to:
  /// **'Sign'**
  String get signatureAskConfirm;

  /// No description provided for @settingsSignaturePolicy.
  ///
  /// In en, this message translates to:
  /// **'Signature requests'**
  String get settingsSignaturePolicy;

  /// No description provided for @settingsSignaturePolicyHint.
  ///
  /// In en, this message translates to:
  /// **'How to answer when a contact asks you to prove you wrote a message'**
  String get settingsSignaturePolicyHint;

  /// No description provided for @settingsApiTitle.
  ///
  /// In en, this message translates to:
  /// **'Automation API'**
  String get settingsApiTitle;

  /// No description provided for @settingsApiHint.
  ///
  /// In en, this message translates to:
  /// **'Off. Local REST API for bots/scripts (localhost only)'**
  String get settingsApiHint;

  /// No description provided for @settingsApiReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get settingsApiReadOnly;

  /// No description provided for @settingsApiReadOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Reads and events only — writes (send, calls) are refused'**
  String get settingsApiReadOnlyHint;

  /// No description provided for @settingsApiAddToken.
  ///
  /// In en, this message translates to:
  /// **'Add token'**
  String get settingsApiAddToken;

  /// No description provided for @settingsApiTokenName.
  ///
  /// In en, this message translates to:
  /// **'Token name (e.g. bot)'**
  String get settingsApiTokenName;

  /// No description provided for @settingsApiRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get settingsApiRevoke;

  /// No description provided for @settingsApiToken.
  ///
  /// In en, this message translates to:
  /// **'API token'**
  String get settingsApiToken;

  /// No description provided for @settingsApiCopyToken.
  ///
  /// In en, this message translates to:
  /// **'Copy token'**
  String get settingsApiCopyToken;

  /// No description provided for @settingsApiRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate token'**
  String get settingsApiRegenerate;

  /// No description provided for @settingsApiTokenCopied.
  ///
  /// In en, this message translates to:
  /// **'Token copied'**
  String get settingsApiTokenCopied;

  /// No description provided for @settingsCommunication.
  ///
  /// In en, this message translates to:
  /// **'Communication'**
  String get settingsCommunication;

  /// No description provided for @settingsP2PPolicy.
  ///
  /// In en, this message translates to:
  /// **'P2P policy'**
  String get settingsP2PPolicy;

  /// No description provided for @settingsP2PPolicyHint.
  ///
  /// In en, this message translates to:
  /// **'Allows direct transport for calls, large media, files, and device-to-device exchange when both sides consent.'**
  String get settingsP2PPolicyHint;

  /// No description provided for @settingsP2PPolicyAnonymousHint.
  ///
  /// In en, this message translates to:
  /// **'P2P is disabled while this identity uses anonymous routing.'**
  String get settingsP2PPolicyAnonymousHint;

  /// No description provided for @p2pPolicyAllowAll.
  ///
  /// In en, this message translates to:
  /// **'Allow everyone'**
  String get p2pPolicyAllowAll;

  /// No description provided for @p2pPolicyContacts.
  ///
  /// In en, this message translates to:
  /// **'Allow contacts'**
  String get p2pPolicyContacts;

  /// No description provided for @p2pPolicySelected.
  ///
  /// In en, this message translates to:
  /// **'Only selected contacts'**
  String get p2pPolicySelected;

  /// No description provided for @p2pPolicyDenied.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get p2pPolicyDenied;

  /// No description provided for @signaturePolicyAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask each time'**
  String get signaturePolicyAsk;

  /// No description provided for @signaturePolicyAuto.
  ///
  /// In en, this message translates to:
  /// **'Sign automatically'**
  String get signaturePolicyAuto;

  /// No description provided for @signaturePolicyRefuse.
  ///
  /// In en, this message translates to:
  /// **'Always refuse'**
  String get signaturePolicyRefuse;

  /// No description provided for @settingsKeepNodeBackground.
  ///
  /// In en, this message translates to:
  /// **'Keep running in background'**
  String get settingsKeepNodeBackground;

  /// No description provided for @settingsKeepNodeBackgroundHint.
  ///
  /// In en, this message translates to:
  /// **'Keeps receiving messages when the app is minimised or the screen is off. Shows a persistent notification and uses more battery.'**
  String get settingsKeepNodeBackgroundHint;

  /// No description provided for @settingsFolderPanel.
  ///
  /// In en, this message translates to:
  /// **'Folders panel'**
  String get settingsFolderPanel;

  /// No description provided for @settingsFolderPanelHint.
  ///
  /// In en, this message translates to:
  /// **'Where chat folders are shown'**
  String get settingsFolderPanelHint;

  /// No description provided for @folderPanelLeft.
  ///
  /// In en, this message translates to:
  /// **'Left drawer'**
  String get folderPanelLeft;

  /// No description provided for @folderPanelRight.
  ///
  /// In en, this message translates to:
  /// **'Right drawer'**
  String get folderPanelRight;

  /// No description provided for @folderPanelTop.
  ///
  /// In en, this message translates to:
  /// **'Top bar'**
  String get folderPanelTop;

  /// No description provided for @mute30m.
  ///
  /// In en, this message translates to:
  /// **'30 minutes'**
  String get mute30m;

  /// No description provided for @mute1h.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get mute1h;

  /// No description provided for @mute8h.
  ///
  /// In en, this message translates to:
  /// **'8 hours'**
  String get mute8h;

  /// No description provided for @mute3d.
  ///
  /// In en, this message translates to:
  /// **'3 days'**
  String get mute3d;

  /// No description provided for @mute1w.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get mute1w;

  /// No description provided for @mute1mo.
  ///
  /// In en, this message translates to:
  /// **'1 month'**
  String get mute1mo;

  /// No description provided for @muteForever.
  ///
  /// In en, this message translates to:
  /// **'Until I turn it back on'**
  String get muteForever;

  /// No description provided for @muteCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get muteCustom;

  /// No description provided for @muteCustomTitle.
  ///
  /// In en, this message translates to:
  /// **'Mute for how long?'**
  String get muteCustomTitle;

  /// No description provided for @muteHoursSuffix.
  ///
  /// In en, this message translates to:
  /// **'hours'**
  String get muteHoursSuffix;

  /// No description provided for @chatMenuCommunicationSettings.
  ///
  /// In en, this message translates to:
  /// **'Communication settings'**
  String get chatMenuCommunicationSettings;

  /// No description provided for @chatMenuP2P.
  ///
  /// In en, this message translates to:
  /// **'P2P connection'**
  String get chatMenuP2P;

  /// No description provided for @contactP2PFollowGlobal.
  ///
  /// In en, this message translates to:
  /// **'Follow global policy'**
  String get contactP2PFollowGlobal;

  /// No description provided for @contactP2PAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get contactP2PAllow;

  /// No description provided for @contactP2PDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get contactP2PDeny;

  /// No description provided for @chatMenuAllowPeerDelete.
  ///
  /// In en, this message translates to:
  /// **'Let this contact delete at me'**
  String get chatMenuAllowPeerDelete;

  /// No description provided for @chatMenuAllowPeerDeleteHint.
  ///
  /// In en, this message translates to:
  /// **'When on, their unsend or clear removes your copy too. Off keeps your copies even if they delete for everyone.'**
  String get chatMenuAllowPeerDeleteHint;

  /// No description provided for @chatMenuUnblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get chatMenuUnblock;

  /// No description provided for @chatMenuClearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get chatMenuClearHistory;

  /// No description provided for @chatMenuDeleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation'**
  String get chatMenuDeleteConversation;

  /// No description provided for @chatClearHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear history?'**
  String get chatClearHistoryTitle;

  /// No description provided for @chatClearHistoryBody.
  ///
  /// In en, this message translates to:
  /// **'Every message in this chat is erased from this device. The contact stays, so you can keep messaging. The other person is not notified.'**
  String get chatClearHistoryBody;

  /// No description provided for @chatClearHistoryConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get chatClearHistoryConfirm;

  /// No description provided for @chatMsgInfo.
  ///
  /// In en, this message translates to:
  /// **'Message info'**
  String get chatMsgInfo;

  /// No description provided for @chatMsgHistory.
  ///
  /// In en, this message translates to:
  /// **'Edit history'**
  String get chatMsgHistory;

  /// No description provided for @chatHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No earlier versions'**
  String get chatHistoryEmpty;

  /// No description provided for @chatHistoryOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get chatHistoryOriginal;

  /// No description provided for @chatHistoryEdited.
  ///
  /// In en, this message translates to:
  /// **'Edited'**
  String get chatHistoryEdited;

  /// No description provided for @msgInfoId.
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get msgInfoId;

  /// No description provided for @msgInfoTime.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get msgInfoTime;

  /// No description provided for @msgInfoDirection.
  ///
  /// In en, this message translates to:
  /// **'Direction'**
  String get msgInfoDirection;

  /// No description provided for @msgInfoStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get msgInfoStatus;

  /// No description provided for @msgInfoFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get msgInfoFile;

  /// No description provided for @msgInfoSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get msgInfoSize;

  /// No description provided for @msgInfoAuthor.
  ///
  /// In en, this message translates to:
  /// **'Author'**
  String get msgInfoAuthor;

  /// No description provided for @msgInfoSeq.
  ///
  /// In en, this message translates to:
  /// **'Sequence'**
  String get msgInfoSeq;

  /// No description provided for @msgInfoEdited.
  ///
  /// In en, this message translates to:
  /// **'Edited'**
  String get msgInfoEdited;

  /// No description provided for @msgInfoYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get msgInfoYes;

  /// No description provided for @chatMsgCopyMeta.
  ///
  /// In en, this message translates to:
  /// **'Copy with metadata'**
  String get chatMsgCopyMeta;

  /// No description provided for @chatMsgReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get chatMsgReply;

  /// No description provided for @chatMsgForward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get chatMsgForward;

  /// No description provided for @chatMsgSelect.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get chatMsgSelect;

  /// No description provided for @chatMsgDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatMsgDelete;

  /// No description provided for @chatMsgDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete messages?'**
  String get chatMsgDeleteTitle;

  /// No description provided for @chatReplyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to'**
  String get chatReplyingTo;

  /// No description provided for @chatQuoteUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Quoted message'**
  String get chatQuoteUnavailable;

  /// No description provided for @chatFileLabel.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get chatFileLabel;

  /// No description provided for @chatForwarded.
  ///
  /// In en, this message translates to:
  /// **'Forwarded'**
  String get chatForwarded;

  /// No description provided for @chatYou.
  ///
  /// In en, this message translates to:
  /// **'you'**
  String get chatYou;

  /// No description provided for @chatForwardedFrom.
  ///
  /// In en, this message translates to:
  /// **'Forwarded from {name}'**
  String chatForwardedFrom(String name);

  /// No description provided for @chatForwardTo.
  ///
  /// In en, this message translates to:
  /// **'Forward to'**
  String get chatForwardTo;

  /// No description provided for @chatForwardNoTargets.
  ///
  /// In en, this message translates to:
  /// **'No accepted contacts to forward to'**
  String get chatForwardNoTargets;

  /// No description provided for @chatMsgDeleteSelectedBody.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} selected message(s)?'**
  String chatMsgDeleteSelectedBody(int count);

  /// No description provided for @dirIncoming.
  ///
  /// In en, this message translates to:
  /// **'Received'**
  String get dirIncoming;

  /// No description provided for @dirOutgoing.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get dirOutgoing;

  /// No description provided for @msgStatusSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get msgStatusSending;

  /// No description provided for @msgStatusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get msgStatusSent;

  /// No description provided for @msgStatusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get msgStatusDelivered;

  /// No description provided for @msgStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get msgStatusFailed;

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

  /// No description provided for @settingsStorageCompact.
  ///
  /// In en, this message translates to:
  /// **'Compact storage'**
  String get settingsStorageCompact;

  /// No description provided for @settingsStorageCompactBody.
  ///
  /// In en, this message translates to:
  /// **'Reclaim unused space — the app re-opens.'**
  String get settingsStorageCompactBody;

  /// No description provided for @settingsStorageCompactDone.
  ///
  /// In en, this message translates to:
  /// **'Reclaimed'**
  String get settingsStorageCompactDone;

  /// No description provided for @settingsStorageCompactFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t compact storage'**
  String get settingsStorageCompactFailed;

  /// No description provided for @settingsStorageAutoCompact.
  ///
  /// In en, this message translates to:
  /// **'Auto-compact on unlock'**
  String get settingsStorageAutoCompact;

  /// No description provided for @settingsStorageAutoCompactBody.
  ///
  /// In en, this message translates to:
  /// **'Compact automatically when the container bloats. Enable ONLY if no other hidden identity lives in this container — compaction keeps just the unlocked space.'**
  String get settingsStorageAutoCompactBody;

  /// No description provided for @settingsStorageLeanPadding.
  ///
  /// In en, this message translates to:
  /// **'Save storage space'**
  String get settingsStorageLeanPadding;

  /// No description provided for @settingsStorageLeanPaddingBody.
  ///
  /// In en, this message translates to:
  /// **'Enabled by default: future writes use less padding, so the container grows much less. Turn off for stronger size-change masking. Applies after the app reopens.'**
  String get settingsStorageLeanPaddingBody;

  /// No description provided for @settingsStoragePasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Your password'**
  String get settingsStoragePasswordHint;

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

  /// No description provided for @settingsFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get settingsFiles;

  /// No description provided for @settingsFilesHint.
  ///
  /// In en, this message translates to:
  /// **'Auto-download limit & blocked types'**
  String get settingsFilesHint;

  /// No description provided for @fileSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'File downloads'**
  String get fileSettingsTitle;

  /// No description provided for @fileAutoLimit.
  ///
  /// In en, this message translates to:
  /// **'Auto-download up to'**
  String get fileAutoLimit;

  /// No description provided for @fileAutoLimitHint.
  ///
  /// In en, this message translates to:
  /// **'Bigger files are offered — you choose whether to download.'**
  String get fileAutoLimitHint;

  /// No description provided for @fileAlwaysAsk.
  ///
  /// In en, this message translates to:
  /// **'Always ask'**
  String get fileAlwaysAsk;

  /// No description provided for @fileBlockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Never auto-download these types'**
  String get fileBlockedTitle;

  /// No description provided for @fileBlockedHint.
  ///
  /// In en, this message translates to:
  /// **'These always wait for your tap (e.g. apk, exe), even when small.'**
  String get fileBlockedHint;

  /// No description provided for @fileAddType.
  ///
  /// In en, this message translates to:
  /// **'Add type'**
  String get fileAddType;

  /// No description provided for @fileTypeHint.
  ///
  /// In en, this message translates to:
  /// **'Extension, e.g. apk'**
  String get fileTypeHint;

  /// No description provided for @fileDownloadTitle.
  ///
  /// In en, this message translates to:
  /// **'Download file'**
  String get fileDownloadTitle;

  /// No description provided for @fileSaveEncrypted.
  ///
  /// In en, this message translates to:
  /// **'Encrypted storage'**
  String get fileSaveEncrypted;

  /// No description provided for @fileSaveEncryptedHint.
  ///
  /// In en, this message translates to:
  /// **'Kept in the app, encrypted on disk'**
  String get fileSaveEncryptedHint;

  /// No description provided for @fileSavePlain.
  ///
  /// In en, this message translates to:
  /// **'Save to disk (unencrypted)'**
  String get fileSavePlain;

  /// No description provided for @fileSavePlainHint.
  ///
  /// In en, this message translates to:
  /// **'A plain file you choose — not protected'**
  String get fileSavePlainHint;

  /// No description provided for @fileSavePlainWarn.
  ///
  /// In en, this message translates to:
  /// **'This file will be saved UNENCRYPTED on disk. Anyone with access to the device can read it. Continue?'**
  String get fileSavePlainWarn;

  /// No description provided for @fileSavePlainConfirm.
  ///
  /// In en, this message translates to:
  /// **'Save unencrypted'**
  String get fileSavePlainConfirm;

  /// No description provided for @fileLargeMode.
  ///
  /// In en, this message translates to:
  /// **'Large files'**
  String get fileLargeMode;

  /// No description provided for @fileLargeModeHint.
  ///
  /// In en, this message translates to:
  /// **'When you download a file too big for the hidden volume'**
  String get fileLargeModeHint;

  /// No description provided for @fileLargeModeAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask each time'**
  String get fileLargeModeAsk;

  /// No description provided for @fileCustomSize.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get fileCustomSize;

  /// No description provided for @fileSizeMb.
  ///
  /// In en, this message translates to:
  /// **'Size in MB'**
  String get fileSizeMb;

  /// No description provided for @fileDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get fileDownloading;

  /// No description provided for @fileRequestingResend.
  ///
  /// In en, this message translates to:
  /// **'Requesting the file from the sender…'**
  String get fileRequestingResend;

  /// No description provided for @fileResuming.
  ///
  /// In en, this message translates to:
  /// **'Resuming…'**
  String get fileResuming;

  /// No description provided for @fileGoneAskResend.
  ///
  /// In en, this message translates to:
  /// **'The sender no longer has this file — ask them to send it again.'**
  String get fileGoneAskResend;

  /// No description provided for @fileReofferFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t get the file — ask the sender to re-send it.'**
  String get fileReofferFailed;

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

  /// No description provided for @addIdentityAnonymous.
  ///
  /// In en, this message translates to:
  /// **'Route anonymously'**
  String get addIdentityAnonymous;

  /// No description provided for @addIdentityAnonymousHint.
  ///
  /// In en, this message translates to:
  /// **'Hide this identity\'s network activity through veil\'s overlay so it can\'t be linked to your other identities. Slower.'**
  String get addIdentityAnonymousHint;

  /// No description provided for @settingsKeepAllOnline.
  ///
  /// In en, this message translates to:
  /// **'Keep all identities online'**
  String get settingsKeepAllOnline;

  /// No description provided for @settingsKeepAllOnlineHint.
  ///
  /// In en, this message translates to:
  /// **'Run every identity\'s node at once so switching is instant and none goes offline (the default). Turn off for strict unlinkability — an observer may link always-on identities by their shared device. Mark sensitive identities to route anonymously.'**
  String get settingsKeepAllOnlineHint;

  /// No description provided for @settingsPhraseStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery phrase'**
  String get settingsPhraseStatusTitle;

  /// No description provided for @settingsPhraseBackedHint.
  ///
  /// In en, this message translates to:
  /// **'This identity derives from its recovery phrase — the phrase you wrote down restores it.'**
  String get settingsPhraseBackedHint;

  /// No description provided for @settingsPhraseNoneHint.
  ///
  /// In en, this message translates to:
  /// **'This identity was created without a recovery phrase — a phrase cannot restore it. Keep the app data backed up by other means.'**
  String get settingsPhraseNoneHint;

  /// No description provided for @settingsAnonymousRouting.
  ///
  /// In en, this message translates to:
  /// **'Anonymous routing (onion)'**
  String get settingsAnonymousRouting;

  /// No description provided for @settingsAnonymousEnabledHint.
  ///
  /// In en, this message translates to:
  /// **'now routes over onion — applies on its next start'**
  String get settingsAnonymousEnabledHint;

  /// No description provided for @settingsAnonymousDisabledHint.
  ///
  /// In en, this message translates to:
  /// **'no longer routes over onion — applies on its next start'**
  String get settingsAnonymousDisabledHint;

  /// No description provided for @settingsLazyMining.
  ///
  /// In en, this message translates to:
  /// **'Lazy mining (raise trust)'**
  String get settingsLazyMining;

  /// No description provided for @settingsLazyMiningEnabledHint.
  ///
  /// In en, this message translates to:
  /// **'grinds extra anti-sybil difficulty in the background — uses CPU; applies on its next start'**
  String get settingsLazyMiningEnabledHint;

  /// No description provided for @settingsLazyMiningDisabledHint.
  ///
  /// In en, this message translates to:
  /// **'off — no background difficulty grind (recommended); applies on its next start'**
  String get settingsLazyMiningDisabledHint;

  /// No description provided for @settingsManageIdentities.
  ///
  /// In en, this message translates to:
  /// **'Manage identities'**
  String get settingsManageIdentities;

  /// No description provided for @manageTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage identities'**
  String get manageTitle;

  /// No description provided for @manageActive.
  ///
  /// In en, this message translates to:
  /// **'active'**
  String get manageActive;

  /// No description provided for @manageAnonOn.
  ///
  /// In en, this message translates to:
  /// **'Route anonymously'**
  String get manageAnonOn;

  /// No description provided for @manageAnonOff.
  ///
  /// In en, this message translates to:
  /// **'Stop routing anonymously'**
  String get manageAnonOff;

  /// No description provided for @manageBind.
  ///
  /// In en, this message translates to:
  /// **'Bind existing identity'**
  String get manageBind;

  /// No description provided for @manageBindHint.
  ///
  /// In en, this message translates to:
  /// **'Add an identity you already have to this master'**
  String get manageBindHint;

  /// No description provided for @manageBindBody.
  ///
  /// In en, this message translates to:
  /// **'Enter the identity\'s own password to add it to this master. The identity is shared, not copied — it stays reachable by its own password too.'**
  String get manageBindBody;

  /// No description provided for @manageBindPassword.
  ///
  /// In en, this message translates to:
  /// **'Identity password'**
  String get manageBindPassword;

  /// No description provided for @manageBindLabel.
  ///
  /// In en, this message translates to:
  /// **'Name in this master'**
  String get manageBindLabel;

  /// No description provided for @manageBindError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t bind — wrong password, it\'s a master, or that name/identity is already here.'**
  String get manageBindError;

  /// No description provided for @manageUnbind.
  ///
  /// In en, this message translates to:
  /// **'Unbind from this master'**
  String get manageUnbind;

  /// No description provided for @manageUnbindBody.
  ///
  /// In en, this message translates to:
  /// **'Removes this identity from this master only. Its space is NOT deleted — it still opens by its own password and from any other master that lists it.'**
  String get manageUnbindBody;

  /// No description provided for @manageUnbindLastError.
  ///
  /// In en, this message translates to:
  /// **'Can\'t unbind the last identity. Delete it, or clear all data, instead.'**
  String get manageUnbindLastError;

  /// No description provided for @manageDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete identity'**
  String get manageDelete;

  /// No description provided for @manageDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Permanently and irreversibly erases this identity — its keys, contacts, messages and files are scrubbed from the container. This cannot be undone.'**
  String get manageDeleteBody;

  /// No description provided for @manageDeleteLastError.
  ///
  /// In en, this message translates to:
  /// **'Can\'t delete the last identity. Use \'Clear all data\' to remove everything.'**
  String get manageDeleteLastError;

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

  /// No description provided for @inviteIsSelf.
  ///
  /// In en, this message translates to:
  /// **'That\'s your own invite — you can\'t add yourself.'**
  String get inviteIsSelf;

  /// No description provided for @inviteCopyMine.
  ///
  /// In en, this message translates to:
  /// **'Copy my invite'**
  String get inviteCopyMine;

  /// No description provided for @identityDetails.
  ///
  /// In en, this message translates to:
  /// **'Identity details'**
  String get identityDetails;

  /// No description provided for @identityPublicKey.
  ///
  /// In en, this message translates to:
  /// **'public key'**
  String get identityPublicKey;

  /// No description provided for @identityAlgo.
  ///
  /// In en, this message translates to:
  /// **'algorithm'**
  String get identityAlgo;

  /// No description provided for @invitePasteTheirs.
  ///
  /// In en, this message translates to:
  /// **'Paste their invite'**
  String get invitePasteTheirs;

  /// No description provided for @inviteScanTooltip.
  ///
  /// In en, this message translates to:
  /// **'Scan QR with camera'**
  String get inviteScanTooltip;

  /// No description provided for @scanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan invite'**
  String get scanTitle;

  /// No description provided for @scanHint.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at a contact\'s invite QR code'**
  String get scanHint;

  /// No description provided for @scanUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Camera unavailable — paste the invite instead'**
  String get scanUnavailable;

  /// No description provided for @scanNotInvite.
  ///
  /// In en, this message translates to:
  /// **'That QR is not an xVeil invite'**
  String get scanNotInvite;

  /// No description provided for @scanTorch.
  ///
  /// In en, this message translates to:
  /// **'Torch'**
  String get scanTorch;

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

  /// No description provided for @networkRouteSubActive.
  ///
  /// In en, this message translates to:
  /// **'Routing active'**
  String get networkRouteSubActive;

  /// No description provided for @networkRouteSubIdle.
  ///
  /// In en, this message translates to:
  /// **'Route your traffic through veil'**
  String get networkRouteSubIdle;

  /// No description provided for @routeTitle.
  ///
  /// In en, this message translates to:
  /// **'Route traffic'**
  String get routeTitle;

  /// No description provided for @routeSocks5Title.
  ///
  /// In en, this message translates to:
  /// **'Route my traffic (SOCKS5)'**
  String get routeSocks5Title;

  /// No description provided for @routeSocks5Hint.
  ///
  /// In en, this message translates to:
  /// **'Bind a local SOCKS5 proxy and tunnel its traffic through veil to an exit node. Point a browser or system proxy at it to evade censorship and hide your location.'**
  String get routeSocks5Hint;

  /// No description provided for @routeListenLabel.
  ///
  /// In en, this message translates to:
  /// **'Local SOCKS5 address'**
  String get routeListenLabel;

  /// No description provided for @routeListenHint.
  ///
  /// In en, this message translates to:
  /// **'Loopback only (e.g. 127.0.0.1:1080) — keeps the proxy private to this device.'**
  String get routeListenHint;

  /// No description provided for @routeListenInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use a loopback host:port, e.g. 127.0.0.1:1080'**
  String get routeListenInvalid;

  /// No description provided for @routeExitNodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Exit node id (64-hex)'**
  String get routeExitNodeLabel;

  /// No description provided for @routeExitNodeHint.
  ///
  /// In en, this message translates to:
  /// **'node_id of an exit you trust — e.g. one of your own nodes from “My nodes”.'**
  String get routeExitNodeHint;

  /// No description provided for @routeExitNodeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Must be a 64-character hex node id'**
  String get routeExitNodeInvalid;

  /// No description provided for @routeNeedExit.
  ///
  /// In en, this message translates to:
  /// **'Set an exit node id to route through'**
  String get routeNeedExit;

  /// No description provided for @routeProxyAddress.
  ///
  /// In en, this message translates to:
  /// **'Point your apps / browser at {addr}'**
  String routeProxyAddress(String addr);

  /// No description provided for @routeServeTitle.
  ///
  /// In en, this message translates to:
  /// **'Be an exit node'**
  String get routeServeTitle;

  /// No description provided for @routeServeHint.
  ///
  /// In en, this message translates to:
  /// **'Let other peers route their traffic out to the internet through this node. More exits make the network more censorship-resistant — but traffic will appear to originate from this device.'**
  String get routeServeHint;

  /// No description provided for @routeAllowPrivate.
  ///
  /// In en, this message translates to:
  /// **'Allow private networks (advanced)'**
  String get routeAllowPrivate;

  /// No description provided for @routeAllowPrivateHint.
  ///
  /// In en, this message translates to:
  /// **'Let the exit reach loopback / RFC1918 / link-local addresses. Leave OFF on any public exit — it prevents reaching internal services and cloud metadata endpoints.'**
  String get routeAllowPrivateHint;

  /// No description provided for @routeAppliesNextStart.
  ///
  /// In en, this message translates to:
  /// **'Changes apply the next time the node starts.'**
  String get routeAppliesNextStart;

  /// No description provided for @routeRestartNode.
  ///
  /// In en, this message translates to:
  /// **'Restart node to apply now'**
  String get routeRestartNode;

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

  /// No description provided for @networkNodesSubCount.
  ///
  /// In en, this message translates to:
  /// **'{count} nodes'**
  String networkNodesSubCount(int count);

  /// No description provided for @nodesTitle.
  ///
  /// In en, this message translates to:
  /// **'My nodes'**
  String get nodesTitle;

  /// No description provided for @nodesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No nodes yet'**
  String get nodesEmpty;

  /// No description provided for @nodesEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Add a server you run as an exit / relay — then route your traffic through it from “Route traffic”.'**
  String get nodesEmptyHint;

  /// No description provided for @nodesAdd.
  ///
  /// In en, this message translates to:
  /// **'Add node'**
  String get nodesAdd;

  /// No description provided for @nodeEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit node'**
  String get nodeEdit;

  /// No description provided for @nodeLabelLabel.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get nodeLabelLabel;

  /// No description provided for @nodeLabelRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a label'**
  String get nodeLabelRequired;

  /// No description provided for @nodeIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Node id (64-hex)'**
  String get nodeIdLabel;

  /// No description provided for @nodeIdHintText.
  ///
  /// In en, this message translates to:
  /// **'The node\'s veil id — lets you route your traffic through it.'**
  String get nodeIdHintText;

  /// No description provided for @nodeIdInvalid.
  ///
  /// In en, this message translates to:
  /// **'Must be a 64-character hex node id'**
  String get nodeIdInvalid;

  /// No description provided for @nodeSshHostLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH host (optional)'**
  String get nodeSshHostLabel;

  /// No description provided for @nodeSshPortLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH port'**
  String get nodeSshPortLabel;

  /// No description provided for @nodeSshUserLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH user (optional)'**
  String get nodeSshUserLabel;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @nodeRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove node'**
  String get nodeRemove;

  /// No description provided for @nodeRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove this node from your list? The remote server is not touched.'**
  String get nodeRemoveConfirm;

  /// No description provided for @nodeUseAsExit.
  ///
  /// In en, this message translates to:
  /// **'Use as routing exit'**
  String get nodeUseAsExit;

  /// No description provided for @nodeUseAsExitDone.
  ///
  /// In en, this message translates to:
  /// **'Set as your SOCKS5 routing exit'**
  String get nodeUseAsExitDone;

  /// No description provided for @nodeNeedsNodeId.
  ///
  /// In en, this message translates to:
  /// **'Add the node id to route through this node'**
  String get nodeNeedsNodeId;

  /// No description provided for @nodeProvision.
  ///
  /// In en, this message translates to:
  /// **'Provision veil node over SSH'**
  String get nodeProvision;

  /// No description provided for @provisionTitle.
  ///
  /// In en, this message translates to:
  /// **'Provision over SSH'**
  String get provisionTitle;

  /// No description provided for @provisionReleaseUrl.
  ///
  /// In en, this message translates to:
  /// **'veil-cli release URL'**
  String get provisionReleaseUrl;

  /// No description provided for @provisionReleaseHint.
  ///
  /// In en, this message translates to:
  /// **'Direct link to a veil-cli binary for the server\'s arch (a GitHub release asset).'**
  String get provisionReleaseHint;

  /// No description provided for @provisionSha256.
  ///
  /// In en, this message translates to:
  /// **'veil-cli SHA-256'**
  String get provisionSha256;

  /// No description provided for @provisionSha256Hint.
  ///
  /// In en, this message translates to:
  /// **'Required. The 64-hex SHA-256 published with that binary. Installation aborts on the server if the download does not match — this is what stops a tampered binary from running as root.'**
  String get provisionSha256Hint;

  /// No description provided for @provisionRunExit.
  ///
  /// In en, this message translates to:
  /// **'Run as an exit (route my traffic through it)'**
  String get provisionRunExit;

  /// No description provided for @provisionScriptLabel.
  ///
  /// In en, this message translates to:
  /// **'Runs on the server as root — review before running:'**
  String get provisionScriptLabel;

  /// No description provided for @provisionPskMissing.
  ///
  /// In en, this message translates to:
  /// **'Deployment PSK isn\'t bundled in this build, so the node can\'t join the network. Provisioning is unavailable.'**
  String get provisionPskMissing;

  /// No description provided for @provisionRun.
  ///
  /// In en, this message translates to:
  /// **'Run over SSH'**
  String get provisionRun;

  /// No description provided for @provisionRunning.
  ///
  /// In en, this message translates to:
  /// **'Provisioning… (mining the identity can take a while)'**
  String get provisionRunning;

  /// No description provided for @provisionNeedUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter an https release URL'**
  String get provisionNeedUrl;

  /// No description provided for @provisionSavedNodeId.
  ///
  /// In en, this message translates to:
  /// **'Saved the node id reported by the server'**
  String get provisionSavedNodeId;

  /// No description provided for @nodeSshConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect over SSH'**
  String get nodeSshConnect;

  /// No description provided for @sshDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'SSH to {host}'**
  String sshDialogTitle(String host);

  /// No description provided for @sshUsePassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get sshUsePassword;

  /// No description provided for @sshUseKey.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get sshUseKey;

  /// No description provided for @sshPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get sshPasswordLabel;

  /// No description provided for @sshKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Private key (PEM)'**
  String get sshKeyLabel;

  /// No description provided for @sshKeyPassphraseLabel.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase (optional)'**
  String get sshKeyPassphraseLabel;

  /// No description provided for @sshCredsNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Used once for this connection — never saved.'**
  String get sshCredsNotSaved;

  /// No description provided for @sshConnectRun.
  ///
  /// In en, this message translates to:
  /// **'Connect & check'**
  String get sshConnectRun;

  /// No description provided for @sshConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get sshConnecting;

  /// No description provided for @sshDone.
  ///
  /// In en, this message translates to:
  /// **'Done (exit {code})'**
  String sshDone(String code);

  /// No description provided for @sshError.
  ///
  /// In en, this message translates to:
  /// **'Failed: {err}'**
  String sshError(String err);

  /// No description provided for @nodeCheckReachable.
  ///
  /// In en, this message translates to:
  /// **'Check reachability'**
  String get nodeCheckReachable;

  /// No description provided for @nodeChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get nodeChecking;

  /// No description provided for @nodeReachable.
  ///
  /// In en, this message translates to:
  /// **'Reachable'**
  String get nodeReachable;

  /// No description provided for @nodeUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Unreachable'**
  String get nodeUnreachable;

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

  /// No description provided for @networkBackgroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep running in background'**
  String get networkBackgroundTitle;

  /// No description provided for @networkBackgroundHint.
  ///
  /// In en, this message translates to:
  /// **'Android only. Keeps the node — your proxy and incoming-message delivery — alive after you switch away from the app. Requires a persistent notification (so it\'s visible the app is running) and uses more battery.'**
  String get networkBackgroundHint;

  /// No description provided for @networkBackgroundAllowTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow background work'**
  String get networkBackgroundAllowTitle;

  /// No description provided for @networkBackgroundAllowBody.
  ///
  /// In en, this message translates to:
  /// **'For messages to arrive while xVeil is in the background, allow it to run without battery restrictions. On some phones (e.g. Xiaomi, Samsung) you must ALSO enable “Autostart” / remove battery limits in the app\'s settings.'**
  String get networkBackgroundAllowBody;

  /// No description provided for @networkBackgroundAllowGrant.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get networkBackgroundAllowGrant;

  /// No description provided for @networkBackgroundOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'App settings'**
  String get networkBackgroundOpenSettings;

  /// No description provided for @networkBackgroundLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get networkBackgroundLater;

  /// No description provided for @peersTitle.
  ///
  /// In en, this message translates to:
  /// **'Connected peers'**
  String get peersTitle;

  /// No description provided for @peersSectionActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get peersSectionActive;

  /// No description provided for @peersSectionInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get peersSectionInactive;

  /// No description provided for @peersEmpty.
  ///
  /// In en, this message translates to:
  /// **'No peers yet'**
  String get peersEmpty;

  /// No description provided for @peersEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'When your node connects to others, they appear here.'**
  String get peersEmptyHint;

  /// No description provided for @peerActiveNow.
  ///
  /// In en, this message translates to:
  /// **'active now'**
  String get peerActiveNow;

  /// No description provided for @peerNeverSeen.
  ///
  /// In en, this message translates to:
  /// **'not yet connected'**
  String get peerNeverSeen;

  /// No description provided for @peerLastSeenLabel.
  ///
  /// In en, this message translates to:
  /// **'last active'**
  String get peerLastSeenLabel;

  /// No description provided for @peerDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Peer details'**
  String get peerDetailsTitle;

  /// No description provided for @peerFieldNodeId.
  ///
  /// In en, this message translates to:
  /// **'node_id'**
  String get peerFieldNodeId;

  /// No description provided for @peerFieldTransport.
  ///
  /// In en, this message translates to:
  /// **'transport'**
  String get peerFieldTransport;

  /// No description provided for @peerFieldState.
  ///
  /// In en, this message translates to:
  /// **'state'**
  String get peerFieldState;

  /// No description provided for @peerFieldDirection.
  ///
  /// In en, this message translates to:
  /// **'direction'**
  String get peerFieldDirection;

  /// No description provided for @peerFieldLastSeen.
  ///
  /// In en, this message translates to:
  /// **'last active (seen by this device)'**
  String get peerFieldLastSeen;

  /// No description provided for @peerStateActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get peerStateActive;

  /// No description provided for @peerStateConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get peerStateConnecting;

  /// No description provided for @peerStateClosed.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get peerStateClosed;

  /// No description provided for @peerStateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get peerStateUnknown;

  /// No description provided for @peerDirInbound.
  ///
  /// In en, this message translates to:
  /// **'Inbound'**
  String get peerDirInbound;

  /// No description provided for @peerDirOutbound.
  ///
  /// In en, this message translates to:
  /// **'Outbound'**
  String get peerDirOutbound;

  /// No description provided for @peerDirUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get peerDirUnknown;

  /// No description provided for @timeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// No description provided for @timeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{n}m ago'**
  String timeMinutesAgo(int n);

  /// No description provided for @timeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{n}h ago'**
  String timeHoursAgo(int n);

  /// No description provided for @timeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{n}d ago'**
  String timeDaysAgo(int n);

  /// No description provided for @peersShareAction.
  ///
  /// In en, this message translates to:
  /// **'Share entry nodes'**
  String get peersShareAction;

  /// No description provided for @peersShareTitle.
  ///
  /// In en, this message translates to:
  /// **'Share entry nodes'**
  String get peersShareTitle;

  /// No description provided for @peersShareSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick nodes to give a friend working entry points to the network — useful if the default seeds are blocked where they are. This shares ONLY these nodes, never your identity.'**
  String get peersShareSubtitle;

  /// No description provided for @peersShareNone.
  ///
  /// In en, this message translates to:
  /// **'No known entry nodes to share'**
  String get peersShareNone;

  /// No description provided for @peersShareSelectOne.
  ///
  /// In en, this message translates to:
  /// **'Select at least one node'**
  String get peersShareSelectOne;

  /// No description provided for @peersShareGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate link'**
  String get peersShareGenerate;

  /// No description provided for @peersShareScanHint.
  ///
  /// In en, this message translates to:
  /// **'Have your friend scan this or open the link in xVeil'**
  String get peersShareScanHint;

  /// No description provided for @peerActiveBadge.
  ///
  /// In en, this message translates to:
  /// **'active'**
  String get peerActiveBadge;

  /// No description provided for @peersImported.
  ///
  /// In en, this message translates to:
  /// **'Added {n} entry nodes'**
  String peersImported(int n);

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

  /// No description provided for @callStartTooltip.
  ///
  /// In en, this message translates to:
  /// **'Call'**
  String get callStartTooltip;

  /// No description provided for @callAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio call'**
  String get callAudio;

  /// No description provided for @callVideo.
  ///
  /// In en, this message translates to:
  /// **'Video call'**
  String get callVideo;

  /// No description provided for @callScreen.
  ///
  /// In en, this message translates to:
  /// **'Screen share'**
  String get callScreen;

  /// No description provided for @callIncoming.
  ///
  /// In en, this message translates to:
  /// **'Incoming call'**
  String get callIncoming;

  /// No description provided for @callDialing.
  ///
  /// In en, this message translates to:
  /// **'Calling…'**
  String get callDialing;

  /// No description provided for @callConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get callConnecting;

  /// No description provided for @callActive.
  ///
  /// In en, this message translates to:
  /// **'In call'**
  String get callActive;

  /// No description provided for @callAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get callAccept;

  /// No description provided for @callDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get callDecline;

  /// No description provided for @callEnd.
  ///
  /// In en, this message translates to:
  /// **'End call'**
  String get callEnd;

  /// No description provided for @callCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get callCancel;

  /// No description provided for @callEnded.
  ///
  /// In en, this message translates to:
  /// **'Call ended'**
  String get callEnded;

  /// No description provided for @callMicOn.
  ///
  /// In en, this message translates to:
  /// **'Mic on'**
  String get callMicOn;

  /// No description provided for @callMicOff.
  ///
  /// In en, this message translates to:
  /// **'Mic off'**
  String get callMicOff;

  /// No description provided for @callCameraOn.
  ///
  /// In en, this message translates to:
  /// **'Camera on'**
  String get callCameraOn;

  /// No description provided for @callCameraOff.
  ///
  /// In en, this message translates to:
  /// **'Camera off'**
  String get callCameraOff;

  /// No description provided for @callScreenOn.
  ///
  /// In en, this message translates to:
  /// **'Sharing screen'**
  String get callScreenOn;

  /// No description provided for @callScreenOff.
  ///
  /// In en, this message translates to:
  /// **'Share screen'**
  String get callScreenOff;

  /// No description provided for @callPathOnion.
  ///
  /// In en, this message translates to:
  /// **'Anonymous (onion)'**
  String get callPathOnion;

  /// No description provided for @callPathRelay.
  ///
  /// In en, this message translates to:
  /// **'Relayed'**
  String get callPathRelay;

  /// No description provided for @callPathP2P.
  ///
  /// In en, this message translates to:
  /// **'Direct (P2P)'**
  String get callPathP2P;

  /// No description provided for @settingsNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get settingsNickname;

  /// No description provided for @settingsNicknameHint.
  ///
  /// In en, this message translates to:
  /// **'Claim an @name others can find you by'**
  String get settingsNicknameHint;

  /// No description provided for @videoPlayError.
  ///
  /// In en, this message translates to:
  /// **'Could not play this video'**
  String get videoPlayError;

  /// No description provided for @emojiSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search emoji'**
  String get emojiSearchHint;

  /// No description provided for @chatEmojiTooltip.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get chatEmojiTooltip;

  /// No description provided for @chatMoreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get chatMoreActions;

  /// No description provided for @nicknameTitle.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get nicknameTitle;

  /// No description provided for @nicknameIntro.
  ///
  /// In en, this message translates to:
  /// **'A nickname is a public @name on the veil network that resolves to this identity. Claiming costs proof-of-work: short names cost much more. A name can be taken over by strictly more work, so you can reinforce yours anytime.'**
  String get nicknameIntro;

  /// No description provided for @nicknameFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Name (a–z, 0–9, _)'**
  String get nicknameFieldLabel;

  /// No description provided for @nicknameCheck.
  ///
  /// In en, this message translates to:
  /// **'Check availability'**
  String get nicknameCheck;

  /// No description provided for @nicknameFree.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get nicknameFree;

  /// No description provided for @nicknameMineVerdict.
  ///
  /// In en, this message translates to:
  /// **'Already yours'**
  String get nicknameMineVerdict;

  /// No description provided for @nicknameTakenWeight.
  ///
  /// In en, this message translates to:
  /// **'Taken — protection weight {weight}'**
  String nicknameTakenWeight(String weight);

  /// No description provided for @nicknameClaim.
  ///
  /// In en, this message translates to:
  /// **'Claim name'**
  String get nicknameClaim;

  /// No description provided for @nicknameMiningLabel.
  ///
  /// In en, this message translates to:
  /// **'Mining proof-of-work…'**
  String get nicknameMiningLabel;

  /// No description provided for @nicknameMiningStats.
  ///
  /// In en, this message translates to:
  /// **'weight {weight} / {target} · {hashes} hashes'**
  String nicknameMiningStats(String weight, String target, String hashes);

  /// No description provided for @nicknamePublishing.
  ///
  /// In en, this message translates to:
  /// **'Publishing…'**
  String get nicknamePublishing;

  /// No description provided for @nicknameOwnedTitle.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get nicknameOwnedTitle;

  /// No description provided for @nicknameWeightExplain.
  ///
  /// In en, this message translates to:
  /// **'Protection weight is the cumulative proof-of-work pinned to the name — the value shown is the live network weight. Taking the name over requires strictly more work; Reinforce raises that price.'**
  String get nicknameWeightExplain;

  /// No description provided for @nicknameOwnedTakenOver.
  ///
  /// In en, this message translates to:
  /// **'The name was taken over with heavier work (rival weight {weight}). Reinforce wins it back by mining strictly more.'**
  String nicknameOwnedTakenOver(String weight);

  /// No description provided for @nicknameOwnedWeight.
  ///
  /// In en, this message translates to:
  /// **'Protection weight {weight}'**
  String nicknameOwnedWeight(String weight);

  /// No description provided for @nicknameTopUp.
  ///
  /// In en, this message translates to:
  /// **'Reinforce (mine more)'**
  String get nicknameTopUp;

  /// No description provided for @nicknameClaimed.
  ///
  /// In en, this message translates to:
  /// **'Name published'**
  String get nicknameClaimed;

  /// No description provided for @newChatPeerOrNickname.
  ///
  /// In en, this message translates to:
  /// **'Node id (hex) or @name'**
  String get newChatPeerOrNickname;

  /// No description provided for @nicknameNotFound.
  ///
  /// In en, this message translates to:
  /// **'Name not found on the network'**
  String get nicknameNotFound;

  /// No description provided for @nicknameIsSelf.
  ///
  /// In en, this message translates to:
  /// **'That name points to you'**
  String get nicknameIsSelf;

  /// No description provided for @nicknameOwnerChanged.
  ///
  /// In en, this message translates to:
  /// **'This name has changed owners on the network. The contact still points to the person you added.'**
  String get nicknameOwnerChanged;

  /// No description provided for @settingsDevices.
  ///
  /// In en, this message translates to:
  /// **'My devices'**
  String get settingsDevices;

  /// No description provided for @settingsDevicesHint.
  ///
  /// In en, this message translates to:
  /// **'Link, review, or revoke devices that share this identity'**
  String get settingsDevicesHint;

  /// No description provided for @devicesThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get devicesThisDevice;

  /// No description provided for @devicesNoGroup.
  ///
  /// In en, this message translates to:
  /// **'No other devices are linked yet'**
  String get devicesNoGroup;

  /// No description provided for @devicesLinkNew.
  ///
  /// In en, this message translates to:
  /// **'Link a new device'**
  String get devicesLinkNew;

  /// No description provided for @devicesJoinExisting.
  ///
  /// In en, this message translates to:
  /// **'Join an existing device'**
  String get devicesJoinExisting;

  /// No description provided for @devicesPhrase.
  ///
  /// In en, this message translates to:
  /// **'Recovery phrase'**
  String get devicesPhrase;

  /// No description provided for @devicesPhraseHint.
  ///
  /// In en, this message translates to:
  /// **'The phrase decrypts the sovereign key for this one action. It is not stored.'**
  String get devicesPhraseHint;

  /// No description provided for @devicesRecoveryCode.
  ///
  /// In en, this message translates to:
  /// **'Recovery code'**
  String get devicesRecoveryCode;

  /// No description provided for @devicesRecoveryCodeHint.
  ///
  /// In en, this message translates to:
  /// **'The code decrypts the recovery certificate for this one action. It is not stored.'**
  String get devicesRecoveryCodeHint;

  /// No description provided for @devicesTargetInvite.
  ///
  /// In en, this message translates to:
  /// **'New device invite'**
  String get devicesTargetInvite;

  /// No description provided for @devicesTargetInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Scan or paste the bootstrap invite shown by the new device'**
  String get devicesTargetInviteHint;

  /// No description provided for @devicesShowMyInvite.
  ///
  /// In en, this message translates to:
  /// **'First, show this device invite to the existing device'**
  String get devicesShowMyInvite;

  /// No description provided for @devicesPrepare.
  ///
  /// In en, this message translates to:
  /// **'Prepare secure link'**
  String get devicesPrepare;

  /// No description provided for @devicesAdoptionQrTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan this on the new device'**
  String get devicesAdoptionQrTitle;

  /// No description provided for @devicesAdoptionQrHint.
  ///
  /// In en, this message translates to:
  /// **'First scan this setup code there. Then return here and send the encrypted setup.'**
  String get devicesAdoptionQrHint;

  /// No description provided for @devicesSendSetup.
  ///
  /// In en, this message translates to:
  /// **'New device is ready — send setup'**
  String get devicesSendSetup;

  /// No description provided for @devicesSetupSent.
  ///
  /// In en, this message translates to:
  /// **'Encrypted setup sent'**
  String get devicesSetupSent;

  /// No description provided for @devicesJoinToken.
  ///
  /// In en, this message translates to:
  /// **'Setup code from existing device'**
  String get devicesJoinToken;

  /// No description provided for @devicesJoinTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Scan or paste the device setup code'**
  String get devicesJoinTokenHint;

  /// No description provided for @devicesWaitTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready to receive'**
  String get devicesWaitTitle;

  /// No description provided for @devicesWaitHint.
  ///
  /// In en, this message translates to:
  /// **'On the existing device, press “send setup”. This screen will finish automatically.'**
  String get devicesWaitHint;

  /// No description provided for @devicesJoined.
  ///
  /// In en, this message translates to:
  /// **'Device linked'**
  String get devicesJoined;

  /// No description provided for @devicesInvalidToken.
  ///
  /// In en, this message translates to:
  /// **'Invalid or mismatched device setup code'**
  String get devicesInvalidToken;

  /// No description provided for @devicesExpiredToken.
  ///
  /// In en, this message translates to:
  /// **'This setup code has expired'**
  String get devicesExpiredToken;

  /// No description provided for @devicesRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke device'**
  String get devicesRevoke;

  /// No description provided for @devicesRevokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke {device}?'**
  String devicesRevokeTitle(String device);

  /// No description provided for @devicesOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete device linking'**
  String get devicesOperationFailed;

  /// No description provided for @devicesCancelPending.
  ///
  /// In en, this message translates to:
  /// **'Cancel waiting'**
  String get devicesCancelPending;

  /// No description provided for @devicesRecoverySection.
  ///
  /// In en, this message translates to:
  /// **'All devices lost'**
  String get devicesRecoverySection;

  /// No description provided for @devicesCreateRecovery.
  ///
  /// In en, this message translates to:
  /// **'Create recovery certificate'**
  String get devicesCreateRecovery;

  /// No description provided for @devicesCreateRecoveryHint.
  ///
  /// In en, this message translates to:
  /// **'Preserves the same sovereign node ID if every linked device is lost'**
  String get devicesCreateRecoveryHint;

  /// No description provided for @devicesRecover.
  ///
  /// In en, this message translates to:
  /// **'Recover device registry'**
  String get devicesRecover;

  /// No description provided for @devicesRecoverHint.
  ///
  /// In en, this message translates to:
  /// **'Use a certificate and its separately stored recovery code on a fresh registry'**
  String get devicesRecoverHint;

  /// No description provided for @devicesCertificate.
  ///
  /// In en, this message translates to:
  /// **'Recovery certificate'**
  String get devicesCertificate;

  /// No description provided for @devicesCertificateHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the complete xveil-recovery:v1 value'**
  String get devicesCertificateHint;

  /// No description provided for @devicesCertificateReady.
  ///
  /// In en, this message translates to:
  /// **'Recovery certificate created'**
  String get devicesCertificateReady;

  /// No description provided for @devicesCertificateWarning.
  ///
  /// In en, this message translates to:
  /// **'Anyone with both values controls your sovereign device identity. Store the certificate and code separately. The code is shown only now.'**
  String get devicesCertificateWarning;

  /// No description provided for @devicesCopyCertificate.
  ///
  /// In en, this message translates to:
  /// **'Copy certificate'**
  String get devicesCopyCertificate;

  /// No description provided for @devicesCopyCode.
  ///
  /// In en, this message translates to:
  /// **'Copy recovery code'**
  String get devicesCopyCode;

  /// No description provided for @devicesRecovered.
  ///
  /// In en, this message translates to:
  /// **'Device registry recovered with the same sovereign node ID'**
  String get devicesRecovered;

  /// No description provided for @devicesFreshRegistryRequired.
  ///
  /// In en, this message translates to:
  /// **'Recovery requires a fresh device registry'**
  String get devicesFreshRegistryRequired;

  /// No description provided for @actionReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get actionReject;

  /// No description provided for @cloudDocumentInvites.
  ///
  /// In en, this message translates to:
  /// **'Shared document invitations ({count})'**
  String cloudDocumentInvites(int count);

  /// No description provided for @cloudDocumentInviteFrom.
  ///
  /// In en, this message translates to:
  /// **'Invitation from {sender}'**
  String cloudDocumentInviteFrom(String sender);

  /// No description provided for @cloudDocumentInviteKind.
  ///
  /// In en, this message translates to:
  /// **'Encrypted {kind} document · inactive until accepted'**
  String cloudDocumentInviteKind(String kind);

  /// No description provided for @cloudDocumentAdopted.
  ///
  /// In en, this message translates to:
  /// **'Shared document added'**
  String get cloudDocumentAdopted;

  /// No description provided for @cloudDocumentAdoptFailed.
  ///
  /// In en, this message translates to:
  /// **'The invitation could not be verified'**
  String get cloudDocumentAdoptFailed;

  /// No description provided for @cloudDocumentRejected.
  ///
  /// In en, this message translates to:
  /// **'Invitation removed'**
  String get cloudDocumentRejected;

  /// No description provided for @cloudSharedNew.
  ///
  /// In en, this message translates to:
  /// **'New shared document'**
  String get cloudSharedNew;

  /// No description provided for @cloudSharedDocuments.
  ///
  /// In en, this message translates to:
  /// **'Shared documents ({count})'**
  String cloudSharedDocuments(int count);

  /// No description provided for @cloudSharedDocument.
  ///
  /// In en, this message translates to:
  /// **'Shared {kind} · {id}'**
  String cloudSharedDocument(String kind, String id);

  /// No description provided for @cloudSharedMembers.
  ///
  /// In en, this message translates to:
  /// **'{count} members · epoch {epoch} · {role}'**
  String cloudSharedMembers(int count, int epoch, String role);

  /// No description provided for @cloudSharedPickContact.
  ///
  /// In en, this message translates to:
  /// **'Invite an accepted contact'**
  String get cloudSharedPickContact;

  /// No description provided for @cloudSharedRole.
  ///
  /// In en, this message translates to:
  /// **'Document role'**
  String get cloudSharedRole;

  /// No description provided for @cloudSharedRoleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get cloudSharedRoleOwner;

  /// No description provided for @cloudSharedRoleEditor.
  ///
  /// In en, this message translates to:
  /// **'Editor'**
  String get cloudSharedRoleEditor;

  /// No description provided for @cloudSharedRoleViewer.
  ///
  /// In en, this message translates to:
  /// **'Viewer'**
  String get cloudSharedRoleViewer;

  /// No description provided for @cloudSharedCreated.
  ///
  /// In en, this message translates to:
  /// **'Shared document created and invitation queued'**
  String get cloudSharedCreated;

  /// No description provided for @cloudSharedFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the shared document'**
  String get cloudSharedFailed;

  /// No description provided for @cloudSharedPartial.
  ///
  /// In en, this message translates to:
  /// **'Saved locally, but delivery was not queued for every member'**
  String get cloudSharedPartial;

  /// No description provided for @cloudSharedAddMember.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get cloudSharedAddMember;

  /// No description provided for @cloudSharedRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke access'**
  String get cloudSharedRevoke;

  /// No description provided for @cloudSharedRevokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke access for {member}?'**
  String cloudSharedRevokeTitle(String member);

  /// No description provided for @cloudSharedRotate.
  ///
  /// In en, this message translates to:
  /// **'Rotate encryption key'**
  String get cloudSharedRotate;

  /// No description provided for @cloudSharedRotateTitle.
  ///
  /// In en, this message translates to:
  /// **'Rotate the document key for every member?'**
  String get cloudSharedRotateTitle;

  /// No description provided for @cloudSharedResend.
  ///
  /// In en, this message translates to:
  /// **'Resend invitation'**
  String get cloudSharedResend;

  /// No description provided for @cloudSharedQueued.
  ///
  /// In en, this message translates to:
  /// **'Update queued'**
  String get cloudSharedQueued;

  /// No description provided for @cloudRichTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared note'**
  String get cloudRichTitle;

  /// No description provided for @cloudRichCollaborative.
  ///
  /// In en, this message translates to:
  /// **'Encrypted collaborative editing'**
  String get cloudRichCollaborative;

  /// No description provided for @cloudRichReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read-only access'**
  String get cloudRichReadOnly;

  /// No description provided for @cloudRichManage.
  ///
  /// In en, this message translates to:
  /// **'Members and access'**
  String get cloudRichManage;

  /// No description provided for @cloudRichSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get cloudRichSave;

  /// No description provided for @cloudRichSaved.
  ///
  /// In en, this message translates to:
  /// **'Shared note saved and queued'**
  String get cloudRichSaved;

  /// No description provided for @cloudRichFailed.
  ///
  /// In en, this message translates to:
  /// **'The shared note could not be updated'**
  String get cloudRichFailed;

  /// No description provided for @cloudRichHint.
  ///
  /// In en, this message translates to:
  /// **'Write together…'**
  String get cloudRichHint;

  /// No description provided for @cloudRichRemotePending.
  ///
  /// In en, this message translates to:
  /// **'A remote change arrived while you were editing. Saving preserves both changes.'**
  String get cloudRichRemotePending;

  /// No description provided for @cloudRichRecovered.
  ///
  /// In en, this message translates to:
  /// **'An offline edit survived a concurrent deletion and was recovered here.'**
  String get cloudRichRecovered;

  /// No description provided for @cloudRichInvalid.
  ///
  /// In en, this message translates to:
  /// **'An authenticated but invalid edit was kept inert.'**
  String get cloudRichInvalid;

  /// No description provided for @cloudRichDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete visible version'**
  String get cloudRichDelete;

  /// No description provided for @cloudRichDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete the version visible here?'**
  String get cloudRichDeleteTitle;

  /// No description provided for @cloudRichDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'This deletion covers only changes already visible on this device. A concurrent offline edit is preserved and will reappear for review instead of being lost.'**
  String get cloudRichDeleteBody;

  /// No description provided for @cloudRichDeleted.
  ///
  /// In en, this message translates to:
  /// **'Visible version deleted; concurrent edits remain recoverable'**
  String get cloudRichDeleted;

  /// No description provided for @cloudRichBold.
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get cloudRichBold;

  /// No description provided for @cloudRichItalic.
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get cloudRichItalic;

  /// No description provided for @cloudRichUnderline.
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get cloudRichUnderline;

  /// No description provided for @cloudRichStrike.
  ///
  /// In en, this message translates to:
  /// **'Strikethrough'**
  String get cloudRichStrike;

  /// No description provided for @cloudRichCode.
  ///
  /// In en, this message translates to:
  /// **'Inline code'**
  String get cloudRichCode;

  /// No description provided for @cloudRichParagraph.
  ///
  /// In en, this message translates to:
  /// **'Paragraph'**
  String get cloudRichParagraph;

  /// No description provided for @cloudRichHeading1.
  ///
  /// In en, this message translates to:
  /// **'Heading 1'**
  String get cloudRichHeading1;

  /// No description provided for @cloudRichHeading2.
  ///
  /// In en, this message translates to:
  /// **'Heading 2'**
  String get cloudRichHeading2;

  /// No description provided for @cloudRichQuote.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get cloudRichQuote;

  /// No description provided for @cloudRichBullet.
  ///
  /// In en, this message translates to:
  /// **'Bullet'**
  String get cloudRichBullet;

  /// No description provided for @cloudRichCodeBlock.
  ///
  /// In en, this message translates to:
  /// **'Code block'**
  String get cloudRichCodeBlock;

  /// No description provided for @cloudSharedPickKind.
  ///
  /// In en, this message translates to:
  /// **'Shared document type'**
  String get cloudSharedPickKind;

  /// No description provided for @cloudKindNote.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get cloudKindNote;

  /// No description provided for @cloudKindTasks.
  ///
  /// In en, this message translates to:
  /// **'Task list'**
  String get cloudKindTasks;

  /// No description provided for @cloudKindCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get cloudKindCalendar;

  /// No description provided for @cloudTasksTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared tasks'**
  String get cloudTasksTitle;

  /// No description provided for @cloudCalendarTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared calendar'**
  String get cloudCalendarTitle;

  /// No description provided for @cloudCollectionCollaborative.
  ///
  /// In en, this message translates to:
  /// **'Encrypted collaborative collection'**
  String get cloudCollectionCollaborative;

  /// No description provided for @cloudCollectionEmptyTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks yet'**
  String get cloudCollectionEmptyTasks;

  /// No description provided for @cloudCollectionEmptyEvents.
  ///
  /// In en, this message translates to:
  /// **'No events yet'**
  String get cloudCollectionEmptyEvents;

  /// No description provided for @cloudTaskAdd.
  ///
  /// In en, this message translates to:
  /// **'Add task'**
  String get cloudTaskAdd;

  /// No description provided for @cloudTaskEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit task'**
  String get cloudTaskEdit;

  /// No description provided for @cloudTaskTitle.
  ///
  /// In en, this message translates to:
  /// **'Task'**
  String get cloudTaskTitle;

  /// No description provided for @cloudTaskNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get cloudTaskNotes;

  /// No description provided for @cloudTaskDue.
  ///
  /// In en, this message translates to:
  /// **'Due date'**
  String get cloudTaskDue;

  /// No description provided for @cloudTaskNoDue.
  ///
  /// In en, this message translates to:
  /// **'No due date'**
  String get cloudTaskNoDue;

  /// No description provided for @cloudEventAdd.
  ///
  /// In en, this message translates to:
  /// **'Add event'**
  String get cloudEventAdd;

  /// No description provided for @cloudEventEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit event'**
  String get cloudEventEdit;

  /// No description provided for @cloudEventTitle.
  ///
  /// In en, this message translates to:
  /// **'Event'**
  String get cloudEventTitle;

  /// No description provided for @cloudEventStart.
  ///
  /// In en, this message translates to:
  /// **'Starts'**
  String get cloudEventStart;

  /// No description provided for @cloudEventEnd.
  ///
  /// In en, this message translates to:
  /// **'Ends'**
  String get cloudEventEnd;

  /// No description provided for @cloudEventAllDay.
  ///
  /// In en, this message translates to:
  /// **'All day'**
  String get cloudEventAllDay;

  /// No description provided for @cloudEventLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get cloudEventLocation;

  /// No description provided for @cloudCollectionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get cloudCollectionDelete;

  /// No description provided for @cloudCollectionDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{title}\"?'**
  String cloudCollectionDeleteTitle(String title);

  /// No description provided for @cloudCollectionSaved.
  ///
  /// In en, this message translates to:
  /// **'Change saved and queued'**
  String get cloudCollectionSaved;

  /// No description provided for @cloudCollectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update this shared collection'**
  String get cloudCollectionFailed;

  /// No description provided for @cloudCollectionInvalidRange.
  ///
  /// In en, this message translates to:
  /// **'The event must end after it starts'**
  String get cloudCollectionInvalidRange;

  /// No description provided for @cloudCollectionInvalid.
  ///
  /// In en, this message translates to:
  /// **'An authenticated but invalid change was kept inert.'**
  String get cloudCollectionInvalid;
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
