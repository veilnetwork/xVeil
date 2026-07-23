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

  /// No description provided for @navCommunities.
  ///
  /// In en, this message translates to:
  /// **'Communities'**
  String get navCommunities;

  /// No description provided for @navFeed.
  ///
  /// In en, this message translates to:
  /// **'Feed'**
  String get navFeed;

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

  /// No description provided for @spaceCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'New community'**
  String get spaceCreateTitle;

  /// No description provided for @spaceCreateAction.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get spaceCreateAction;

  /// No description provided for @spaceNameHint.
  ///
  /// In en, this message translates to:
  /// **'Community name'**
  String get spaceNameHint;

  /// No description provided for @spaceDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get spaceDescriptionLabel;

  /// No description provided for @spaceDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'What this community is for'**
  String get spaceDescriptionHint;

  /// No description provided for @spaceDescriptionEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit description'**
  String get spaceDescriptionEditTitle;

  /// No description provided for @spaceDescriptionSave.
  ///
  /// In en, this message translates to:
  /// **'Save description'**
  String get spaceDescriptionSave;

  /// No description provided for @spaceVisibilityLabel.
  ///
  /// In en, this message translates to:
  /// **'Visibility'**
  String get spaceVisibilityLabel;

  /// No description provided for @spaceVisibilityPublic.
  ///
  /// In en, this message translates to:
  /// **'Public'**
  String get spaceVisibilityPublic;

  /// No description provided for @spaceVisibilityPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get spaceVisibilityPrivate;

  /// No description provided for @spaceVisibilitySecret.
  ///
  /// In en, this message translates to:
  /// **'Secret'**
  String get spaceVisibilitySecret;

  /// No description provided for @spaceVisibilityPublicHint.
  ///
  /// In en, this message translates to:
  /// **'Posts may be shared publicly. Automatic discovery is not enabled until the holder protocol is ready.'**
  String get spaceVisibilityPublicHint;

  /// No description provided for @spaceVisibilityPrivateHint.
  ///
  /// In en, this message translates to:
  /// **'Membership is by invitation and community content is encrypted for current members.'**
  String get spaceVisibilityPrivateHint;

  /// No description provided for @spaceVisibilitySecretHint.
  ///
  /// In en, this message translates to:
  /// **'Invitations hide the community name; content is encrypted and the community is never searchable.'**
  String get spaceVisibilitySecretHint;

  /// No description provided for @spaceEmpty.
  ///
  /// In en, this message translates to:
  /// **'No communities yet'**
  String get spaceEmpty;

  /// No description provided for @spaceOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the community. Check the network and try again.'**
  String get spaceOperationFailed;

  /// No description provided for @spaceChannelsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No channels in this community'**
  String get spaceChannelsEmpty;

  /// No description provided for @spaceChannelCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get spaceChannelCreateTitle;

  /// No description provided for @spaceChannelNameHint.
  ///
  /// In en, this message translates to:
  /// **'Channel name'**
  String get spaceChannelNameHint;

  /// No description provided for @spaceChannelDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get spaceChannelDescriptionHint;

  /// No description provided for @spaceChannelKind.
  ///
  /// In en, this message translates to:
  /// **'Channel type'**
  String get spaceChannelKind;

  /// No description provided for @spaceChannelText.
  ///
  /// In en, this message translates to:
  /// **'Text channel'**
  String get spaceChannelText;

  /// No description provided for @spaceChannelVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice channel'**
  String get spaceChannelVoice;

  /// No description provided for @spaceChannelCategory.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get spaceChannelCategory;

  /// No description provided for @spaceChannelCategoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Place in category'**
  String get spaceChannelCategoryLabel;

  /// No description provided for @spaceChannelNoCategory.
  ///
  /// In en, this message translates to:
  /// **'Community root'**
  String get spaceChannelNoCategory;

  /// No description provided for @spaceChannelAccess.
  ///
  /// In en, this message translates to:
  /// **'Access'**
  String get spaceChannelAccess;

  /// No description provided for @spaceChannelAccessSpace.
  ///
  /// In en, this message translates to:
  /// **'All community members'**
  String get spaceChannelAccessSpace;

  /// No description provided for @spaceChannelAccessRestricted.
  ///
  /// In en, this message translates to:
  /// **'Restricted · admins only initially'**
  String get spaceChannelAccessRestricted;

  /// No description provided for @spaceChannelAccessSecret.
  ///
  /// In en, this message translates to:
  /// **'Secret · admins only initially'**
  String get spaceChannelAccessSecret;

  /// No description provided for @spaceChannelHistory.
  ///
  /// In en, this message translates to:
  /// **'History for new members'**
  String get spaceChannelHistory;

  /// No description provided for @spaceChannelHistoryFromJoin.
  ///
  /// In en, this message translates to:
  /// **'Only from the time they join'**
  String get spaceChannelHistoryFromJoin;

  /// No description provided for @spaceChannelHistoryFull.
  ///
  /// In en, this message translates to:
  /// **'Full channel history'**
  String get spaceChannelHistoryFull;

  /// No description provided for @spaceChannelHistorySinceNow.
  ///
  /// In en, this message translates to:
  /// **'Messages from now on'**
  String get spaceChannelHistorySinceNow;

  /// No description provided for @spaceChannelManage.
  ///
  /// In en, this message translates to:
  /// **'Manage channel'**
  String get spaceChannelManage;

  /// No description provided for @spaceChannelEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit channel'**
  String get spaceChannelEdit;

  /// No description provided for @spaceChannelSave.
  ///
  /// In en, this message translates to:
  /// **'Save channel'**
  String get spaceChannelSave;

  /// No description provided for @spaceChannelArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive channel'**
  String get spaceChannelArchive;

  /// No description provided for @spaceChannelRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore channel'**
  String get spaceChannelRestore;

  /// No description provided for @spaceChannelMakeDefault.
  ///
  /// In en, this message translates to:
  /// **'Make default channel'**
  String get spaceChannelMakeDefault;

  /// No description provided for @spaceChannelArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get spaceChannelArchived;

  /// No description provided for @spaceChannelArchiveCategoryBlocked.
  ///
  /// In en, this message translates to:
  /// **'Move or archive the active channels in this category first.'**
  String get spaceChannelArchiveCategoryBlocked;

  /// No description provided for @spaceVoiceStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start or join this voice session.'**
  String get spaceVoiceStartFailed;

  /// No description provided for @spacePostsTitle.
  ///
  /// In en, this message translates to:
  /// **'Publications'**
  String get spacePostsTitle;

  /// No description provided for @spacePostsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No publications yet'**
  String get spacePostsEmpty;

  /// No description provided for @spacePostCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'New publication'**
  String get spacePostCreateTitle;

  /// No description provided for @spacePostTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Title (optional)'**
  String get spacePostTitleHint;

  /// No description provided for @spacePostBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Share an update with the community…'**
  String get spacePostBodyHint;

  /// No description provided for @spacePostBlocks.
  ///
  /// In en, this message translates to:
  /// **'Blocks'**
  String get spacePostBlocks;

  /// No description provided for @spacePostBlockParagraph.
  ///
  /// In en, this message translates to:
  /// **'Paragraph'**
  String get spacePostBlockParagraph;

  /// No description provided for @spacePostBlockHeading1.
  ///
  /// In en, this message translates to:
  /// **'Large heading'**
  String get spacePostBlockHeading1;

  /// No description provided for @spacePostBlockHeading2.
  ///
  /// In en, this message translates to:
  /// **'Medium heading'**
  String get spacePostBlockHeading2;

  /// No description provided for @spacePostBlockHeading3.
  ///
  /// In en, this message translates to:
  /// **'Small heading'**
  String get spacePostBlockHeading3;

  /// No description provided for @spacePostBlockBulletList.
  ///
  /// In en, this message translates to:
  /// **'Bulleted list'**
  String get spacePostBlockBulletList;

  /// No description provided for @spacePostBlockOrderedList.
  ///
  /// In en, this message translates to:
  /// **'Numbered list'**
  String get spacePostBlockOrderedList;

  /// No description provided for @spacePostBlockCode.
  ///
  /// In en, this message translates to:
  /// **'Code block'**
  String get spacePostBlockCode;

  /// No description provided for @spacePostBlockDivider.
  ///
  /// In en, this message translates to:
  /// **'Divider'**
  String get spacePostBlockDivider;

  /// No description provided for @spacePostPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview publication'**
  String get spacePostPreview;

  /// No description provided for @spacePostContinueEditing.
  ///
  /// In en, this message translates to:
  /// **'Continue editing'**
  String get spacePostContinueEditing;

  /// No description provided for @spacePostPublish.
  ///
  /// In en, this message translates to:
  /// **'Publish'**
  String get spacePostPublish;

  /// No description provided for @spacePostDraftHint.
  ///
  /// In en, this message translates to:
  /// **'Saved encrypted on this device. The draft is not shared until you publish it.'**
  String get spacePostDraftHint;

  /// No description provided for @spacePostSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get spacePostSchedule;

  /// No description provided for @spacePostScheduleClear.
  ///
  /// In en, this message translates to:
  /// **'Publish immediately instead'**
  String get spacePostScheduleClear;

  /// No description provided for @spacePostScheduleFuture.
  ///
  /// In en, this message translates to:
  /// **'Choose a time in the future.'**
  String get spacePostScheduleFuture;

  /// No description provided for @spacePostScheduleDeviceHint.
  ///
  /// In en, this message translates to:
  /// **'Encrypted on this device and not shared before publication. If xVeil is closed or locked at that time, it will publish after the next unlock.'**
  String get spacePostScheduleDeviceHint;

  /// No description provided for @spacePostScheduledSuccess.
  ///
  /// In en, this message translates to:
  /// **'Publication scheduled'**
  String get spacePostScheduledSuccess;

  /// No description provided for @spacePostScheduledPublications.
  ///
  /// In en, this message translates to:
  /// **'Scheduled publications'**
  String get spacePostScheduledPublications;

  /// No description provided for @spacePostScheduledFailed.
  ///
  /// In en, this message translates to:
  /// **'Not published. Review it and retry or cancel.'**
  String get spacePostScheduledFailed;

  /// No description provided for @spacePostPublishNow.
  ///
  /// In en, this message translates to:
  /// **'Publish now'**
  String get spacePostPublishNow;

  /// No description provided for @spacePostPublishedNow.
  ///
  /// In en, this message translates to:
  /// **'Publication published'**
  String get spacePostPublishedNow;

  /// No description provided for @spacePostCancelSchedule.
  ///
  /// In en, this message translates to:
  /// **'Cancel schedule'**
  String get spacePostCancelSchedule;

  /// No description provided for @spacePostCancelScheduleTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel scheduled publication?'**
  String get spacePostCancelScheduleTitle;

  /// No description provided for @spacePostCancelScheduleBody.
  ///
  /// In en, this message translates to:
  /// **'The encrypted local copy of this scheduled publication will be removed.'**
  String get spacePostCancelScheduleBody;

  /// No description provided for @spacePostScheduleCancelled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled publication cancelled'**
  String get spacePostScheduleCancelled;

  /// No description provided for @spacePostMediaAttach.
  ///
  /// In en, this message translates to:
  /// **'Add media or file'**
  String get spacePostMediaAttach;

  /// No description provided for @spacePostMediaRejected.
  ///
  /// In en, this message translates to:
  /// **'Some files couldn\'t be attached'**
  String get spacePostMediaRejected;

  /// No description provided for @spacePostRecordVoice.
  ///
  /// In en, this message translates to:
  /// **'Record voice message'**
  String get spacePostRecordVoice;

  /// No description provided for @spacePostRecordShortVideo.
  ///
  /// In en, this message translates to:
  /// **'Record short video'**
  String get spacePostRecordShortVideo;

  /// No description provided for @spacePostUseRecording.
  ///
  /// In en, this message translates to:
  /// **'Use recording'**
  String get spacePostUseRecording;

  /// No description provided for @spacePostEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit publication'**
  String get spacePostEdit;

  /// No description provided for @spacePostEdited.
  ///
  /// In en, this message translates to:
  /// **'Edited'**
  String get spacePostEdited;

  /// No description provided for @spacePostPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get spacePostPin;

  /// No description provided for @spacePostUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get spacePostUnpin;

  /// No description provided for @spacePostPinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get spacePostPinned;

  /// No description provided for @spacePostCommentsTitle.
  ///
  /// In en, this message translates to:
  /// **'Comments'**
  String get spacePostCommentsTitle;

  /// No description provided for @spacePostCommentsOpen.
  ///
  /// In en, this message translates to:
  /// **'Open comments'**
  String get spacePostCommentsOpen;

  /// No description provided for @spacePostCommentsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No comments yet'**
  String get spacePostCommentsEmpty;

  /// No description provided for @spacePostCommentsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Start a discussion about this publication.'**
  String get spacePostCommentsEmptyHint;

  /// No description provided for @spacePostCommentsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No comments} one{1 comment} other{{count} comments}}'**
  String spacePostCommentsCount(int count);

  /// No description provided for @spacePostCommentHint.
  ///
  /// In en, this message translates to:
  /// **'Write a comment…'**
  String get spacePostCommentHint;

  /// No description provided for @spacePostCommentSend.
  ///
  /// In en, this message translates to:
  /// **'Send comment'**
  String get spacePostCommentSend;

  /// No description provided for @spacePostCommentReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get spacePostCommentReply;

  /// No description provided for @spacePostCommentEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get spacePostCommentEdit;

  /// No description provided for @spacePostCommentEditing.
  ///
  /// In en, this message translates to:
  /// **'Editing comment'**
  String get spacePostCommentEditing;

  /// No description provided for @spacePostCommentCancelEdit.
  ///
  /// In en, this message translates to:
  /// **'Cancel editing'**
  String get spacePostCommentCancelEdit;

  /// No description provided for @spacePostCommentSaveEdit.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get spacePostCommentSaveEdit;

  /// No description provided for @spacePostCommentEdited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get spacePostCommentEdited;

  /// No description provided for @spacePostCommentEditFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the comment changes'**
  String get spacePostCommentEditFailed;

  /// No description provided for @spacePostCommentReplyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to {author}'**
  String spacePostCommentReplyingTo(String author);

  /// No description provided for @spacePostCommentCancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get spacePostCommentCancelReply;

  /// No description provided for @spacePostCommentFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not publish this comment'**
  String get spacePostCommentFailed;

  /// No description provided for @spacePostCommentTooLong.
  ///
  /// In en, this message translates to:
  /// **'The comment is too large to encrypt and send.'**
  String get spacePostCommentTooLong;

  /// No description provided for @spacePostCommentReadOnly.
  ///
  /// In en, this message translates to:
  /// **'This discussion is read-only.'**
  String get spacePostCommentReadOnly;

  /// No description provided for @feedPinnedTitle.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get feedPinnedTitle;

  /// No description provided for @feedRecentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get feedRecentTitle;

  /// No description provided for @spacePostDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete publication'**
  String get spacePostDelete;

  /// No description provided for @spacePostDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this publication?'**
  String get spacePostDeleteTitle;

  /// No description provided for @spacePostDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'A signed tombstone will remove it from the community feed on every synchronized member device. This cannot be undone.'**
  String get spacePostDeleteBody;

  /// No description provided for @spacePostTypePost.
  ///
  /// In en, this message translates to:
  /// **'Post'**
  String get spacePostTypePost;

  /// No description provided for @spacePostTypeArticle.
  ///
  /// In en, this message translates to:
  /// **'Article'**
  String get spacePostTypeArticle;

  /// No description provided for @spacePostTypeVideo.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get spacePostTypeVideo;

  /// No description provided for @spacePostTypeShortVideo.
  ///
  /// In en, this message translates to:
  /// **'Short video'**
  String get spacePostTypeShortVideo;

  /// No description provided for @spacePostTypeAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get spacePostTypeAudio;

  /// No description provided for @spacePostTypeVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get spacePostTypeVoiceMessage;

  /// No description provided for @spaceFeedEnable.
  ///
  /// In en, this message translates to:
  /// **'Show this community in Feed'**
  String get spaceFeedEnable;

  /// No description provided for @spaceFeedDisable.
  ///
  /// In en, this message translates to:
  /// **'Hide this community from Feed'**
  String get spaceFeedDisable;

  /// No description provided for @spaceSubscriptionSettings.
  ///
  /// In en, this message translates to:
  /// **'Feed and notifications'**
  String get spaceSubscriptionSettings;

  /// No description provided for @spaceFeedSetting.
  ///
  /// In en, this message translates to:
  /// **'Publications in the main Feed'**
  String get spaceFeedSetting;

  /// No description provided for @spaceFeedSettingHint.
  ///
  /// In en, this message translates to:
  /// **'This changes only your combined Feed; you remain a community member.'**
  String get spaceFeedSettingHint;

  /// No description provided for @spaceNotificationsSetting.
  ///
  /// In en, this message translates to:
  /// **'Publication notifications'**
  String get spaceNotificationsSetting;

  /// No description provided for @spaceNotificationsSettingHint.
  ///
  /// In en, this message translates to:
  /// **'Alert on this device when a new community publication arrives.'**
  String get spaceNotificationsSettingHint;

  /// No description provided for @spaceCommentNotificationsSetting.
  ///
  /// In en, this message translates to:
  /// **'Discussion notifications'**
  String get spaceCommentNotificationsSetting;

  /// No description provided for @spaceCommentNotificationsSettingHint.
  ///
  /// In en, this message translates to:
  /// **'Choose which new comments alert this device.'**
  String get spaceCommentNotificationsSettingHint;

  /// No description provided for @spaceCommentNotificationsAll.
  ///
  /// In en, this message translates to:
  /// **'All comments'**
  String get spaceCommentNotificationsAll;

  /// No description provided for @spaceCommentNotificationsReplies.
  ///
  /// In en, this message translates to:
  /// **'Replies to me and comments on my posts'**
  String get spaceCommentNotificationsReplies;

  /// No description provided for @spaceCommentNotificationsNone.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get spaceCommentNotificationsNone;

  /// No description provided for @spaceHideRecommendationsSetting.
  ///
  /// In en, this message translates to:
  /// **'Do not recommend this community to me'**
  String get spaceHideRecommendationsSetting;

  /// No description provided for @spaceHideRecommendationsSettingHint.
  ///
  /// In en, this message translates to:
  /// **'Keep this community out of recommendation surfaces on this device.'**
  String get spaceHideRecommendationsSettingHint;

  /// No description provided for @spaceSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Members and settings'**
  String get spaceSettingsTitle;

  /// No description provided for @spaceMembersTooltip.
  ///
  /// In en, this message translates to:
  /// **'Members and settings'**
  String get spaceMembersTooltip;

  /// No description provided for @spaceRetentionTitle.
  ///
  /// In en, this message translates to:
  /// **'History retention'**
  String get spaceRetentionTitle;

  /// No description provided for @spaceRetentionSafetyHint.
  ///
  /// In en, this message translates to:
  /// **'Community policy and this device\'s local history are independent.'**
  String get spaceRetentionSafetyHint;

  /// No description provided for @spaceRetentionGlobal.
  ///
  /// In en, this message translates to:
  /// **'Community policy'**
  String get spaceRetentionGlobal;

  /// No description provided for @spaceRetentionGlobalHint.
  ///
  /// In en, this message translates to:
  /// **'Signed by the owner and enforced by every member.'**
  String get spaceRetentionGlobalHint;

  /// No description provided for @spaceRetentionLocal.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get spaceRetentionLocal;

  /// No description provided for @spaceRetentionLocalHint.
  ///
  /// In en, this message translates to:
  /// **'Only hides local history; it never deletes content for other members.'**
  String get spaceRetentionLocalHint;

  /// No description provided for @spaceRetentionMediaOnly.
  ///
  /// In en, this message translates to:
  /// **'Delete only media'**
  String get spaceRetentionMediaOnly;

  /// No description provided for @spaceRetentionMediaOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Keep message and publication text while expiring attachments after the selected period.'**
  String get spaceRetentionMediaOnlyHint;

  /// No description provided for @spaceRetentionMediaExpired.
  ///
  /// In en, this message translates to:
  /// **'Media removed by the retention policy'**
  String get spaceRetentionMediaExpired;

  /// No description provided for @spaceActiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Community is active'**
  String get spaceActiveTitle;

  /// No description provided for @spaceActiveHint.
  ///
  /// In en, this message translates to:
  /// **'Members can publish, write in channels, and join voice rooms.'**
  String get spaceActiveHint;

  /// No description provided for @spaceArchivedTitle.
  ///
  /// In en, this message translates to:
  /// **'Community is archived'**
  String get spaceArchivedTitle;

  /// No description provided for @spaceArchivedHint.
  ///
  /// In en, this message translates to:
  /// **'History remains readable, but messages, posts, reactions, voice rooms, and settings are read-only.'**
  String get spaceArchivedHint;

  /// No description provided for @spaceDeletedTitle.
  ///
  /// In en, this message translates to:
  /// **'Community is awaiting deletion'**
  String get spaceDeletedTitle;

  /// No description provided for @spaceDeletedHint.
  ///
  /// In en, this message translates to:
  /// **'Content is hidden and all activity is stopped. The owner can restore the community until the recovery period ends.'**
  String get spaceDeletedHint;

  /// No description provided for @spaceDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete community?'**
  String get spaceDeleteTitle;

  /// No description provided for @spaceDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'The community will be recoverable for 7 days. After that, encrypted local copies are purged in the background and old snapshots cannot restore them.'**
  String get spaceDeleteConfirm;

  /// No description provided for @spaceDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete community'**
  String get spaceDeleteAction;

  /// No description provided for @spaceDeleteHint.
  ///
  /// In en, this message translates to:
  /// **'Starts a 7-day recovery period before physical cleanup.'**
  String get spaceDeleteHint;

  /// No description provided for @spaceRecoveryUntil.
  ///
  /// In en, this message translates to:
  /// **'Recovery is available until {date}'**
  String spaceRecoveryUntil(String date);

  /// No description provided for @spaceArchiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Archive community?'**
  String get spaceArchiveTitle;

  /// No description provided for @spaceArchiveConfirm.
  ///
  /// In en, this message translates to:
  /// **'This creates an owner-signed boundary and makes the community read-only on every device. You can restore it later.'**
  String get spaceArchiveConfirm;

  /// No description provided for @spaceArchiveAction.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get spaceArchiveAction;

  /// No description provided for @spaceRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore community?'**
  String get spaceRestoreTitle;

  /// No description provided for @spaceRestoreConfirm.
  ///
  /// In en, this message translates to:
  /// **'New content will start in a fresh signed lifecycle epoch. Archived history remains available.'**
  String get spaceRestoreConfirm;

  /// No description provided for @spaceRestoreAction.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get spaceRestoreAction;

  /// No description provided for @spaceMembers.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String spaceMembers(int count);

  /// No description provided for @spaceMemberAdd.
  ///
  /// In en, this message translates to:
  /// **'Invite member'**
  String get spaceMemberAdd;

  /// No description provided for @spaceNoContactsToAdd.
  ///
  /// In en, this message translates to:
  /// **'All accepted contacts are already members'**
  String get spaceNoContactsToAdd;

  /// No description provided for @spaceInviteSent.
  ///
  /// In en, this message translates to:
  /// **'Invitation sent. Membership and keys stay private until they accept.'**
  String get spaceInviteSent;

  /// No description provided for @spaceInvitesTitle.
  ///
  /// In en, this message translates to:
  /// **'Invitations'**
  String get spaceInvitesTitle;

  /// No description provided for @spaceSecretInviteTitle.
  ///
  /// In en, this message translates to:
  /// **'Secret community'**
  String get spaceSecretInviteTitle;

  /// No description provided for @spaceInviteFrom.
  ///
  /// In en, this message translates to:
  /// **'From {peer}'**
  String spaceInviteFrom(String peer);

  /// No description provided for @spaceInviteAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get spaceInviteAccept;

  /// No description provided for @spaceInviteDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get spaceInviteDecline;

  /// No description provided for @spaceInviteJoining.
  ///
  /// In en, this message translates to:
  /// **'Accepted · waiting for verified membership'**
  String get spaceInviteJoining;

  /// No description provided for @spaceJoinAction.
  ///
  /// In en, this message translates to:
  /// **'Join with link'**
  String get spaceJoinAction;

  /// No description provided for @spaceJoinDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Request to join a community'**
  String get spaceJoinDialogTitle;

  /// No description provided for @spaceJoinCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Paste an xveil://space link'**
  String get spaceJoinCodeHint;

  /// No description provided for @spaceJoinSafetyHint.
  ///
  /// In en, this message translates to:
  /// **'The link sends only a membership request. Channels, members and keys stay unavailable until an administrator approves it with a signed grant.'**
  String get spaceJoinSafetyHint;

  /// No description provided for @spaceJoinRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Request sent. The community will appear after signed approval.'**
  String get spaceJoinRequestSent;

  /// No description provided for @spaceJoinRequestsTitle.
  ///
  /// In en, this message translates to:
  /// **'Join requests'**
  String get spaceJoinRequestsTitle;

  /// No description provided for @spaceJoinRequestFrom.
  ///
  /// In en, this message translates to:
  /// **'Request from {peer}'**
  String spaceJoinRequestFrom(String peer);

  /// No description provided for @spaceJoinRequestPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval'**
  String get spaceJoinRequestPending;

  /// No description provided for @spaceJoinRequestApproved.
  ///
  /// In en, this message translates to:
  /// **'Approved · receiving verified membership'**
  String get spaceJoinRequestApproved;

  /// No description provided for @spaceJoinRequestDeclined.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get spaceJoinRequestDeclined;

  /// No description provided for @spaceMembershipStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Membership status'**
  String get spaceMembershipStatusTitle;

  /// No description provided for @spaceMembershipPending.
  ///
  /// In en, this message translates to:
  /// **'Membership pending'**
  String get spaceMembershipPending;

  /// No description provided for @spaceMembershipActive.
  ///
  /// In en, this message translates to:
  /// **'Active member'**
  String get spaceMembershipActive;

  /// No description provided for @spaceMembershipSuspended.
  ///
  /// In en, this message translates to:
  /// **'Membership suspended'**
  String get spaceMembershipSuspended;

  /// No description provided for @spaceMembershipSuspendedUntil.
  ///
  /// In en, this message translates to:
  /// **'Membership suspended until {until}'**
  String spaceMembershipSuspendedUntil(String until);

  /// No description provided for @spaceMembershipLeft.
  ///
  /// In en, this message translates to:
  /// **'No longer a member'**
  String get spaceMembershipLeft;

  /// No description provided for @spaceMembershipBanned.
  ///
  /// In en, this message translates to:
  /// **'Membership banned'**
  String get spaceMembershipBanned;

  /// No description provided for @spaceJoinDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get spaceJoinDismiss;

  /// No description provided for @spaceJoinApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get spaceJoinApprove;

  /// No description provided for @spaceJoinDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get spaceJoinDecline;

  /// No description provided for @spaceJoinLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Public join link'**
  String get spaceJoinLinkTitle;

  /// No description provided for @spaceJoinLinkHint.
  ///
  /// In en, this message translates to:
  /// **'Anyone with this revocable link may request membership. The link never grants access by itself.'**
  String get spaceJoinLinkHint;

  /// No description provided for @spaceJoinLinkCreate.
  ///
  /// In en, this message translates to:
  /// **'Create link'**
  String get spaceJoinLinkCreate;

  /// No description provided for @spaceJoinLinkCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get spaceJoinLinkCopy;

  /// No description provided for @spaceJoinLinkRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke link'**
  String get spaceJoinLinkRevoke;

  /// No description provided for @spaceJoinLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Join link copied'**
  String get spaceJoinLinkCopied;

  /// No description provided for @spaceJoinLinkRevoked.
  ///
  /// In en, this message translates to:
  /// **'Join link revoked'**
  String get spaceJoinLinkRevoked;

  /// No description provided for @spaceRecommendationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendations'**
  String get spaceRecommendationsTitle;

  /// No description provided for @spaceRecommendationsHint.
  ///
  /// In en, this message translates to:
  /// **'Create a signed public campaign. Members can then recommend this community only to contacts they explicitly select.'**
  String get spaceRecommendationsHint;

  /// No description provided for @spaceRecommendationCreate.
  ///
  /// In en, this message translates to:
  /// **'Create campaign'**
  String get spaceRecommendationCreate;

  /// No description provided for @spaceRecommendationTextHint.
  ///
  /// In en, this message translates to:
  /// **'What members may send with the community card'**
  String get spaceRecommendationTextHint;

  /// No description provided for @spaceRecommendationShare.
  ///
  /// In en, this message translates to:
  /// **'Recommend community'**
  String get spaceRecommendationShare;

  /// No description provided for @spaceRecommendationSelectCampaign.
  ///
  /// In en, this message translates to:
  /// **'Choose a campaign'**
  String get spaceRecommendationSelectCampaign;

  /// No description provided for @spaceRecommendationSelectContact.
  ///
  /// In en, this message translates to:
  /// **'Choose a recipient'**
  String get spaceRecommendationSelectContact;

  /// No description provided for @spaceRecommendationRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke campaign'**
  String get spaceRecommendationRevoke;

  /// No description provided for @spaceRecommendationSent.
  ///
  /// In en, this message translates to:
  /// **'Recommendation sent'**
  String get spaceRecommendationSent;

  /// No description provided for @spaceRecommendationDuplicate.
  ///
  /// In en, this message translates to:
  /// **'This campaign was already sent to that contact'**
  String get spaceRecommendationDuplicate;

  /// No description provided for @spaceRecommendationRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Recommendation limit reached. Try again later.'**
  String get spaceRecommendationRateLimited;

  /// No description provided for @spaceRecommendationAlreadyMember.
  ///
  /// In en, this message translates to:
  /// **'This contact is already a member'**
  String get spaceRecommendationAlreadyMember;

  /// No description provided for @spaceRecommendationEmpty.
  ///
  /// In en, this message translates to:
  /// **'No active recommendation campaigns'**
  String get spaceRecommendationEmpty;

  /// No description provided for @spaceRecommendationReceive.
  ///
  /// In en, this message translates to:
  /// **'Community recommendations'**
  String get spaceRecommendationReceive;

  /// No description provided for @spaceRecommendationReceiveHint.
  ///
  /// In en, this message translates to:
  /// **'Allow accepted contacts to send community cards. Turning this off silently discards new recommendations.'**
  String get spaceRecommendationReceiveHint;

  /// No description provided for @spaceRoleLabel.
  ///
  /// In en, this message translates to:
  /// **'Community role'**
  String get spaceRoleLabel;

  /// No description provided for @spaceRoleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get spaceRoleOwner;

  /// No description provided for @spaceRoleAdmin.
  ///
  /// In en, this message translates to:
  /// **'Administrator'**
  String get spaceRoleAdmin;

  /// No description provided for @spaceRoleMember.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get spaceRoleMember;

  /// No description provided for @spaceAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Roles and access'**
  String get spaceAccessTitle;

  /// No description provided for @spaceAccessHint.
  ///
  /// In en, this message translates to:
  /// **'Reusable permission sets, participant groups, and direct member roles. Every change is signed and audited.'**
  String get spaceAccessHint;

  /// No description provided for @spaceAccessEmpty.
  ///
  /// In en, this message translates to:
  /// **'No custom roles yet. Built-in community roles continue to apply.'**
  String get spaceAccessEmpty;

  /// No description provided for @spaceAccessRoles.
  ///
  /// In en, this message translates to:
  /// **'Custom roles'**
  String get spaceAccessRoles;

  /// No description provided for @spaceAccessGroups.
  ///
  /// In en, this message translates to:
  /// **'Participant groups'**
  String get spaceAccessGroups;

  /// No description provided for @spaceAccessRoleAdd.
  ///
  /// In en, this message translates to:
  /// **'Add role'**
  String get spaceAccessRoleAdd;

  /// No description provided for @spaceAccessRoleEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit role'**
  String get spaceAccessRoleEdit;

  /// No description provided for @spaceAccessRoleDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete role'**
  String get spaceAccessRoleDelete;

  /// No description provided for @spaceAccessRoleDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the role “{name}”? Its assignments will be removed in the same signed change.'**
  String spaceAccessRoleDeleteConfirm(Object name);

  /// No description provided for @spaceAccessRoleName.
  ///
  /// In en, this message translates to:
  /// **'Role name'**
  String get spaceAccessRoleName;

  /// No description provided for @spaceAccessRolePermissions.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 permission} other{{count} permissions}}'**
  String spaceAccessRolePermissions(num count);

  /// No description provided for @spaceAccessGroupAdd.
  ///
  /// In en, this message translates to:
  /// **'Add group'**
  String get spaceAccessGroupAdd;

  /// No description provided for @spaceAccessGroupEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit group'**
  String get spaceAccessGroupEdit;

  /// No description provided for @spaceAccessGroupDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete group'**
  String get spaceAccessGroupDelete;

  /// No description provided for @spaceAccessGroupDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the participant group “{name}”?'**
  String spaceAccessGroupDeleteConfirm(Object name);

  /// No description provided for @spaceAccessGroupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get spaceAccessGroupName;

  /// No description provided for @spaceAccessGroupSummary.
  ///
  /// In en, this message translates to:
  /// **'{members, plural, =1{1 member} other{{members} members}} · {roles, plural, =1{1 role} other{{roles} roles}}'**
  String spaceAccessGroupSummary(num members, num roles);

  /// No description provided for @spaceAccessDirectRoles.
  ///
  /// In en, this message translates to:
  /// **'Assign custom roles'**
  String get spaceAccessDirectRoles;

  /// No description provided for @spaceAccessNoRoles.
  ///
  /// In en, this message translates to:
  /// **'Create a custom role before assigning it.'**
  String get spaceAccessNoRoles;

  /// No description provided for @spacePermissionView.
  ///
  /// In en, this message translates to:
  /// **'View community'**
  String get spacePermissionView;

  /// No description provided for @spacePermissionDistributeContent.
  ///
  /// In en, this message translates to:
  /// **'Distribute content'**
  String get spacePermissionDistributeContent;

  /// No description provided for @spacePermissionPublishMessages.
  ///
  /// In en, this message translates to:
  /// **'Publish messages'**
  String get spacePermissionPublishMessages;

  /// No description provided for @spacePermissionPublishPosts.
  ///
  /// In en, this message translates to:
  /// **'Publish posts'**
  String get spacePermissionPublishPosts;

  /// No description provided for @spacePermissionManagePosts.
  ///
  /// In en, this message translates to:
  /// **'Manage posts'**
  String get spacePermissionManagePosts;

  /// No description provided for @spacePermissionManageRecommendations.
  ///
  /// In en, this message translates to:
  /// **'Manage recommendations'**
  String get spacePermissionManageRecommendations;

  /// No description provided for @spacePermissionEnterVoice.
  ///
  /// In en, this message translates to:
  /// **'Join voice'**
  String get spacePermissionEnterVoice;

  /// No description provided for @spacePermissionManageMembers.
  ///
  /// In en, this message translates to:
  /// **'Manage members'**
  String get spacePermissionManageMembers;

  /// No description provided for @spacePermissionManageRoles.
  ///
  /// In en, this message translates to:
  /// **'Manage roles'**
  String get spacePermissionManageRoles;

  /// No description provided for @spacePermissionModerate.
  ///
  /// In en, this message translates to:
  /// **'Moderate'**
  String get spacePermissionModerate;

  /// No description provided for @spacePermissionManageSettings.
  ///
  /// In en, this message translates to:
  /// **'Manage settings'**
  String get spacePermissionManageSettings;

  /// No description provided for @spacePermissionManageEncryption.
  ///
  /// In en, this message translates to:
  /// **'Manage encryption'**
  String get spacePermissionManageEncryption;

  /// No description provided for @spacePermissionManageStorage.
  ///
  /// In en, this message translates to:
  /// **'Manage storage and retention'**
  String get spacePermissionManageStorage;

  /// No description provided for @spacePermissionManageChannels.
  ///
  /// In en, this message translates to:
  /// **'Manage channels'**
  String get spacePermissionManageChannels;

  /// No description provided for @spaceMemberMuted.
  ///
  /// In en, this message translates to:
  /// **'Cannot publish until unmuted'**
  String get spaceMemberMuted;

  /// No description provided for @spaceMemberMute.
  ///
  /// In en, this message translates to:
  /// **'Restrict publishing'**
  String get spaceMemberMute;

  /// No description provided for @spaceMemberUnmute.
  ///
  /// In en, this message translates to:
  /// **'Allow publishing'**
  String get spaceMemberUnmute;

  /// No description provided for @spaceMemberPromote.
  ///
  /// In en, this message translates to:
  /// **'Make administrator'**
  String get spaceMemberPromote;

  /// No description provided for @spaceMemberDemote.
  ///
  /// In en, this message translates to:
  /// **'Make member'**
  String get spaceMemberDemote;

  /// No description provided for @spaceMemberRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from community'**
  String get spaceMemberRemove;

  /// No description provided for @spaceMemberRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove {member} and rotate access keys?'**
  String spaceMemberRemoveConfirm(String member);

  /// No description provided for @spaceMemberTransferOwnership.
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership'**
  String get spaceMemberTransferOwnership;

  /// No description provided for @spaceMemberTransferOwnershipConfirm.
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership to {member}? You will become an administrator, and only the new owner can transfer it back.'**
  String spaceMemberTransferOwnershipConfirm(String member);

  /// No description provided for @spaceRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename community'**
  String get spaceRenameTitle;

  /// No description provided for @spaceRenameAction.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get spaceRenameAction;

  /// No description provided for @spaceRenameDenied.
  ///
  /// In en, this message translates to:
  /// **'You do not have permission to rename this community'**
  String get spaceRenameDenied;

  /// No description provided for @spaceLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave community'**
  String get spaceLeave;

  /// No description provided for @spaceLeaveConfirm.
  ///
  /// In en, this message translates to:
  /// **'You will lose access to its channels and publications. Protected keys will be rotated for the remaining members.'**
  String get spaceLeaveConfirm;

  /// No description provided for @spaceOwnerLeaveHint.
  ///
  /// In en, this message translates to:
  /// **'Transfer ownership to another member before leaving the community.'**
  String get spaceOwnerLeaveHint;

  /// No description provided for @spaceReplicationTitle.
  ///
  /// In en, this message translates to:
  /// **'P2P availability'**
  String get spaceReplicationTitle;

  /// No description provided for @spaceReplicationNeighbors.
  ///
  /// In en, this message translates to:
  /// **'Distribute through {count} nearby members'**
  String spaceReplicationNeighbors(int count);

  /// No description provided for @spaceReplicationHint.
  ///
  /// In en, this message translates to:
  /// **'More distributors improve offline availability and recovery, but use more traffic on this device.'**
  String get spaceReplicationHint;

  /// No description provided for @spaceYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get spaceYou;

  /// No description provided for @feedEmpty.
  ///
  /// In en, this message translates to:
  /// **'Your feed is empty'**
  String get feedEmpty;

  /// No description provided for @feedEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Publications from enabled communities will appear here in chronological order.'**
  String get feedEmptyHint;

  /// No description provided for @feedPostHide.
  ///
  /// In en, this message translates to:
  /// **'Hide from Feed'**
  String get feedPostHide;

  /// No description provided for @feedPostHidden.
  ///
  /// In en, this message translates to:
  /// **'Publication hidden from your Feed'**
  String get feedPostHidden;

  /// No description provided for @feedPostUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get feedPostUndo;

  /// No description provided for @feedPostHideFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update this Feed preference'**
  String get feedPostHideFailed;

  /// No description provided for @feedFilterTitle.
  ///
  /// In en, this message translates to:
  /// **'Filter publications'**
  String get feedFilterTitle;

  /// No description provided for @feedFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get feedFilterAll;

  /// No description provided for @feedFilterApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get feedFilterApply;

  /// No description provided for @feedFilterEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'No publications match the selected content types.'**
  String get feedFilterEmptyHint;

  /// No description provided for @feedFilterUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the Feed filter'**
  String get feedFilterUpdateFailed;

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

  /// No description provided for @notificationMention.
  ///
  /// In en, this message translates to:
  /// **'You were mentioned'**
  String get notificationMention;

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

  /// No description provided for @mentionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Mentions'**
  String get mentionsTitle;

  /// No description provided for @mentionsOpenTooltip.
  ///
  /// In en, this message translates to:
  /// **'All mentions'**
  String get mentionsOpenTooltip;

  /// No description provided for @mentionsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No mentions yet'**
  String get mentionsEmpty;

  /// No description provided for @mentionsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Messages, community posts and comments that mention you will appear here.'**
  String get mentionsEmptyHint;

  /// No description provided for @mentionsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load mentions'**
  String get mentionsLoadFailed;

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
  /// **'New group chat'**
  String get groupCreateTitle;

  /// No description provided for @groupCreateAction.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get groupCreateAction;

  /// No description provided for @groupOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the group. Check the network and try again.'**
  String get groupOperationFailed;

  /// No description provided for @groupEncrypted.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted'**
  String get groupEncrypted;

  /// No description provided for @groupEncryptionPending.
  ///
  /// In en, this message translates to:
  /// **'Encryption upgrade pending'**
  String get groupEncryptionPending;

  /// No description provided for @groupNameHint.
  ///
  /// In en, this message translates to:
  /// **'Group chat name'**
  String get groupNameHint;

  /// No description provided for @groupEmpty.
  ///
  /// In en, this message translates to:
  /// **'No group chats yet'**
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

  /// No description provided for @groupSyncSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Chat synchronization'**
  String get groupSyncSettingsTooltip;

  /// No description provided for @groupSyncNeighborsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat synchronization'**
  String get groupSyncNeighborsTitle;

  /// No description provided for @groupSyncNeighborsLabel.
  ///
  /// In en, this message translates to:
  /// **'XOR neighbours: {count}'**
  String groupSyncNeighborsLabel(int count);

  /// No description provided for @groupSyncNeighborsHint.
  ///
  /// In en, this message translates to:
  /// **'How many XOR-closest members this device connects to for chat history. More neighbours improve redundancy but use more traffic. This setting is local to this device.'**
  String get groupSyncNeighborsHint;

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

  /// No description provided for @stickerPackChooseTarget.
  ///
  /// In en, this message translates to:
  /// **'Add to which pack?'**
  String get stickerPackChooseTarget;

  /// No description provided for @stickerPackNew.
  ///
  /// In en, this message translates to:
  /// **'New pack…'**
  String get stickerPackNew;

  /// No description provided for @stickerPackNameHint.
  ///
  /// In en, this message translates to:
  /// **'Pack name'**
  String get stickerPackNameHint;

  /// No description provided for @stickerPackRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get stickerPackRename;

  /// No description provided for @stickerPackDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete pack'**
  String get stickerPackDelete;

  /// No description provided for @stickerPackDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\" and its stickers?'**
  String stickerPackDeleteConfirm(String name);

  /// No description provided for @stickerPackUnsigned.
  ///
  /// In en, this message translates to:
  /// **'Unsigned pack'**
  String get stickerPackUnsigned;

  /// No description provided for @stickerPackSignedBy.
  ///
  /// In en, this message translates to:
  /// **'Signed by {author}'**
  String stickerPackSignedBy(String author);

  /// No description provided for @stickerPackBadSignature.
  ///
  /// In en, this message translates to:
  /// **'Signature check failed — pack not installed'**
  String get stickerPackBadSignature;

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

  /// No description provided for @notificationMuteModeTitle.
  ///
  /// In en, this message translates to:
  /// **'What should still notify you?'**
  String get notificationMuteModeTitle;

  /// No description provided for @notificationMuteMentionsOnly.
  ///
  /// In en, this message translates to:
  /// **'Mentions only'**
  String get notificationMuteMentionsOnly;

  /// No description provided for @notificationMuteMentionsOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Silence new-message alerts, but notify when you are mentioned'**
  String get notificationMuteMentionsOnlyHint;

  /// No description provided for @notificationMuteNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing'**
  String get notificationMuteNone;

  /// No description provided for @notificationMuteNoneHint.
  ///
  /// In en, this message translates to:
  /// **'Silence all alerts, including mentions'**
  String get notificationMuteNoneHint;

  /// No description provided for @notificationMuteCurrentMentionsOnly.
  ///
  /// In en, this message translates to:
  /// **'Mentions only until {until}'**
  String notificationMuteCurrentMentionsOnly(String until);

  /// No description provided for @notificationMuteCurrentNone.
  ///
  /// In en, this message translates to:
  /// **'Muted until {until}'**
  String notificationMuteCurrentNone(String until);

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

  /// No description provided for @scanTorchOn.
  ///
  /// In en, this message translates to:
  /// **'Turn torch on'**
  String get scanTorchOn;

  /// No description provided for @scanTorchOff.
  ///
  /// In en, this message translates to:
  /// **'Turn torch off'**
  String get scanTorchOff;

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

  /// No description provided for @vpnTitle.
  ///
  /// In en, this message translates to:
  /// **'System VPN'**
  String get vpnTitle;

  /// No description provided for @vpnHint.
  ///
  /// In en, this message translates to:
  /// **'Route device traffic through a veil exit. VPN starts its local SOCKS5 transport automatically; the separate SOCKS5 switch is only for direct proxy use.'**
  String get vpnHint;

  /// No description provided for @vpnStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Packet tunnel active'**
  String get vpnStatusRunning;

  /// No description provided for @vpnStatusStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting packet tunnel…'**
  String get vpnStatusStarting;

  /// No description provided for @vpnStatusStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping packet tunnel…'**
  String get vpnStatusStopping;

  /// No description provided for @vpnStatusStopped.
  ///
  /// In en, this message translates to:
  /// **'Packet tunnel stopped'**
  String get vpnStatusStopped;

  /// No description provided for @vpnStatusError.
  ///
  /// In en, this message translates to:
  /// **'Packet tunnel error'**
  String get vpnStatusError;

  /// No description provided for @vpnStatusUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Packet tunnel unavailable in this build'**
  String get vpnStatusUnsupported;

  /// No description provided for @vpnUnsupportedDetail.
  ///
  /// In en, this message translates to:
  /// **'This platform build has no native packet-tunnel engine yet. SOCKS5 remains available; xVeil will not claim that a VPN is active.'**
  String get vpnUnsupportedDetail;

  /// No description provided for @vpnRouteMode.
  ///
  /// In en, this message translates to:
  /// **'Traffic selection'**
  String get vpnRouteMode;

  /// No description provided for @vpnRouteAll.
  ///
  /// In en, this message translates to:
  /// **'All traffic'**
  String get vpnRouteAll;

  /// No description provided for @vpnRouteInclude.
  ///
  /// In en, this message translates to:
  /// **'Only selected subnets'**
  String get vpnRouteInclude;

  /// No description provided for @vpnRouteExclude.
  ///
  /// In en, this message translates to:
  /// **'All except selected subnets'**
  String get vpnRouteExclude;

  /// No description provided for @vpnApplicationRouting.
  ///
  /// In en, this message translates to:
  /// **'Applications using VPN'**
  String get vpnApplicationRouting;

  /// No description provided for @vpnApplicationAll.
  ///
  /// In en, this message translates to:
  /// **'All applications'**
  String get vpnApplicationAll;

  /// No description provided for @vpnApplicationOnlySelected.
  ///
  /// In en, this message translates to:
  /// **'Only selected applications'**
  String get vpnApplicationOnlySelected;

  /// No description provided for @vpnApplicationOnlySelectedHint.
  ///
  /// In en, this message translates to:
  /// **'Only the selected Android applications enter the tunnel; all other applications use the normal network.'**
  String get vpnApplicationOnlySelectedHint;

  /// No description provided for @vpnApplicationUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Per-application routing is available on Android. Consumer iOS/macOS VPNs do not expose the source application; Linux and Windows need a future process-routing backend.'**
  String get vpnApplicationUnsupported;

  /// No description provided for @vpnApplicationSelect.
  ///
  /// In en, this message translates to:
  /// **'Select apps'**
  String get vpnApplicationSelect;

  /// No description provided for @vpnApplicationNoneSelected.
  ///
  /// In en, this message translates to:
  /// **'Select at least one application'**
  String get vpnApplicationNoneSelected;

  /// No description provided for @vpnApplicationSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} applications selected'**
  String vpnApplicationSelectedCount(Object count);

  /// No description provided for @vpnApplicationPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Applications using VPN'**
  String get vpnApplicationPickerTitle;

  /// No description provided for @vpnApplicationPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No launchable applications are visible to Android.'**
  String get vpnApplicationPickerEmpty;

  /// No description provided for @vpnApplicationSearchEmpty.
  ///
  /// In en, this message translates to:
  /// **'No applications match this search.'**
  String get vpnApplicationSearchEmpty;

  /// No description provided for @vpnApplicationLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not list applications: {error}'**
  String vpnApplicationLoadError(Object error);

  /// No description provided for @oproxyCatalogTitle.
  ///
  /// In en, this message translates to:
  /// **'oproxy exits'**
  String get oproxyCatalogTitle;

  /// No description provided for @oproxyAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add oproxy'**
  String get oproxyAddTitle;

  /// No description provided for @oproxyEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit oproxy'**
  String get oproxyEditTitle;

  /// No description provided for @oproxyName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get oproxyName;

  /// No description provided for @oproxyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Add at least one oproxy exit first.'**
  String get oproxyEmpty;

  /// No description provided for @oproxyNoDefault.
  ///
  /// In en, this message translates to:
  /// **'No default oproxy is configured'**
  String get oproxyNoDefault;

  /// No description provided for @oproxyDefaultSummary.
  ///
  /// In en, this message translates to:
  /// **'Default chain: {count} exits'**
  String oproxyDefaultSummary(Object count);

  /// No description provided for @oproxyDefaultOrderTitle.
  ///
  /// In en, this message translates to:
  /// **'Default oproxy and fallbacks'**
  String get oproxyDefaultOrderTitle;

  /// No description provided for @oproxyDefaultOrderAction.
  ///
  /// In en, this message translates to:
  /// **'Configure default and fallbacks'**
  String get oproxyDefaultOrderAction;

  /// No description provided for @oproxyPrimary.
  ///
  /// In en, this message translates to:
  /// **'Primary oproxy'**
  String get oproxyPrimary;

  /// No description provided for @oproxyUseDefault.
  ///
  /// In en, this message translates to:
  /// **'Use default chain'**
  String get oproxyUseDefault;

  /// No description provided for @oproxyVpnRouteTitle.
  ///
  /// In en, this message translates to:
  /// **'Main VPN oproxy chain'**
  String get oproxyVpnRouteTitle;

  /// No description provided for @oproxyRouteSummary.
  ///
  /// In en, this message translates to:
  /// **'{primary} + {fallbacks} fallbacks'**
  String oproxyRouteSummary(Object fallbacks, Object primary);

  /// No description provided for @oproxyAutoFailover.
  ///
  /// In en, this message translates to:
  /// **'Automatic oproxy failover'**
  String get oproxyAutoFailover;

  /// No description provided for @oproxyAutoFailoverHint.
  ///
  /// In en, this message translates to:
  /// **'New connections try the next exit when the primary cannot open a route. Existing connections stay on their current exit.'**
  String get oproxyAutoFailoverHint;

  /// No description provided for @oproxyApplicationRoutesTitle.
  ///
  /// In en, this message translates to:
  /// **'Application oproxy routes'**
  String get oproxyApplicationRoutesTitle;

  /// No description provided for @oproxyApplicationRoutesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No applications are selected for this VPN.'**
  String get oproxyApplicationRoutesEmpty;

  /// No description provided for @oproxyApplicationRoutesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} application overrides'**
  String oproxyApplicationRoutesCount(Object count);

  /// No description provided for @vpnIncludedCidrs.
  ///
  /// In en, this message translates to:
  /// **'Included subnets'**
  String get vpnIncludedCidrs;

  /// No description provided for @vpnExcludedCidrs.
  ///
  /// In en, this message translates to:
  /// **'Excluded subnets'**
  String get vpnExcludedCidrs;

  /// No description provided for @vpnCidrsHint.
  ///
  /// In en, this message translates to:
  /// **'One IPv4 or IPv6 CIDR per line, e.g. 10.20.0.0/16'**
  String get vpnCidrsHint;

  /// No description provided for @vpnCidrsInvalid.
  ///
  /// In en, this message translates to:
  /// **'Every route must be a valid IPv4 or IPv6 CIDR'**
  String get vpnCidrsInvalid;

  /// No description provided for @vpnIncludedCountries.
  ///
  /// In en, this message translates to:
  /// **'Countries routed through VPN (GeoIP)'**
  String get vpnIncludedCountries;

  /// No description provided for @vpnExcludedCountries.
  ///
  /// In en, this message translates to:
  /// **'Countries bypassing VPN (GeoIP)'**
  String get vpnExcludedCountries;

  /// No description provided for @vpnCountriesHint.
  ///
  /// In en, this message translates to:
  /// **'Two-letter country codes separated by spaces or commas, e.g. KZ, RU. Uses the bundled IPdeny snapshot; GeoIP is approximate.'**
  String get vpnCountriesHint;

  /// No description provided for @vpnCountriesInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use two-letter country codes such as KZ'**
  String get vpnCountriesInvalid;

  /// No description provided for @vpnRouteDns.
  ///
  /// In en, this message translates to:
  /// **'Route DNS through VPN'**
  String get vpnRouteDns;

  /// No description provided for @vpnRouteDnsHint.
  ///
  /// In en, this message translates to:
  /// **'Install the selected DNS servers on the tunnel interface to prevent resolver leaks.'**
  String get vpnRouteDnsHint;

  /// No description provided for @vpnDnsServers.
  ///
  /// In en, this message translates to:
  /// **'DNS servers'**
  String get vpnDnsServers;

  /// No description provided for @vpnDnsHint.
  ///
  /// In en, this message translates to:
  /// **'One IPv4 or IPv6 address per line'**
  String get vpnDnsHint;

  /// No description provided for @vpnDnsInvalid.
  ///
  /// In en, this message translates to:
  /// **'Every DNS server must be an IP address'**
  String get vpnDnsInvalid;

  /// No description provided for @vpnAllowLan.
  ///
  /// In en, this message translates to:
  /// **'Allow local network'**
  String get vpnAllowLan;

  /// No description provided for @vpnAllowLanHint.
  ///
  /// In en, this message translates to:
  /// **'Keep private and link-local subnets reachable outside the tunnel.'**
  String get vpnAllowLanHint;

  /// No description provided for @vpnMtu.
  ///
  /// In en, this message translates to:
  /// **'Tunnel MTU'**
  String get vpnMtu;

  /// No description provided for @vpnMtuHint.
  ///
  /// In en, this message translates to:
  /// **'1280–9000; 1280 is safe across IPv4 and IPv6 paths'**
  String get vpnMtuHint;

  /// No description provided for @vpnMtuInvalid.
  ///
  /// In en, this message translates to:
  /// **'MTU must be between 1280 and 9000'**
  String get vpnMtuInvalid;

  /// No description provided for @vpnNeedsProxy.
  ///
  /// In en, this message translates to:
  /// **'Select a valid exit node first. VPN starts its SOCKS5 transport automatically.'**
  String get vpnNeedsProxy;

  /// No description provided for @vpnStart.
  ///
  /// In en, this message translates to:
  /// **'Start VPN'**
  String get vpnStart;

  /// No description provided for @vpnStop.
  ///
  /// In en, this message translates to:
  /// **'Stop VPN'**
  String get vpnStop;

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

  /// No description provided for @nodesAddChoiceTitle.
  ///
  /// In en, this message translates to:
  /// **'What kind of node are you adding?'**
  String get nodesAddChoiceTitle;

  /// No description provided for @nodesAddExisting.
  ///
  /// In en, this message translates to:
  /// **'Add an existing node'**
  String get nodesAddExisting;

  /// No description provided for @nodesAddExistingHint.
  ///
  /// In en, this message translates to:
  /// **'Register a node that is already installed and has a node id.'**
  String get nodesAddExistingHint;

  /// No description provided for @nodesAddExistingFieldsHint.
  ///
  /// In en, this message translates to:
  /// **'Required: label and node ID. SSH fields are optional and only needed to manage the server. A password or key can be saved below in xVeil\'s encrypted storage.'**
  String get nodesAddExistingFieldsHint;

  /// No description provided for @nodesBootstrapNew.
  ///
  /// In en, this message translates to:
  /// **'Bootstrap a new node over SSH'**
  String get nodesBootstrapNew;

  /// No description provided for @nodesBootstrapNewHint.
  ///
  /// In en, this message translates to:
  /// **'Install veil on a Linux server; its node id will be saved automatically.'**
  String get nodesBootstrapNewHint;

  /// No description provided for @nodesBootstrapFieldsHint.
  ///
  /// In en, this message translates to:
  /// **'Required: label, SSH host, and SSH user. The port defaults to 22. A password or key can be saved below; the node ID is saved after provisioning.'**
  String get nodesBootstrapFieldsHint;

  /// No description provided for @nodesBootstrapContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue to provisioning'**
  String get nodesBootstrapContinue;

  /// No description provided for @nodeEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit node'**
  String get nodeEdit;

  /// No description provided for @nodeLabelLabel.
  ///
  /// In en, this message translates to:
  /// **'Label *'**
  String get nodeLabelLabel;

  /// No description provided for @nodeLabelRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a label'**
  String get nodeLabelRequired;

  /// No description provided for @nodeIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Node ID (64 hex, optional)'**
  String get nodeIdLabel;

  /// No description provided for @nodeIdRequiredLabel.
  ///
  /// In en, this message translates to:
  /// **'Node ID (64 hex) *'**
  String get nodeIdRequiredLabel;

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

  /// No description provided for @nodeIdRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the existing node\'s 64-character node id'**
  String get nodeIdRequired;

  /// No description provided for @nodeSshHostLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH host (optional)'**
  String get nodeSshHostLabel;

  /// No description provided for @nodeSshHostRequiredLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH host *'**
  String get nodeSshHostRequiredLabel;

  /// No description provided for @nodeSshHostRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the SSH host for the new server'**
  String get nodeSshHostRequired;

  /// No description provided for @nodeSshPortLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH port (defaults to 22)'**
  String get nodeSshPortLabel;

  /// No description provided for @nodeSshUserLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH user (optional)'**
  String get nodeSshUserLabel;

  /// No description provided for @nodeSshUserRequiredLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH user *'**
  String get nodeSshUserRequiredLabel;

  /// No description provided for @nodeSshUserRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the SSH user for the new server'**
  String get nodeSshUserRequired;

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

  /// No description provided for @nodeManage.
  ///
  /// In en, this message translates to:
  /// **'Manage node'**
  String get nodeManage;

  /// No description provided for @nodeInventory.
  ///
  /// In en, this message translates to:
  /// **'Inspect installation and status'**
  String get nodeInventory;

  /// No description provided for @nodeInstallUpdate.
  ///
  /// In en, this message translates to:
  /// **'Install or update software'**
  String get nodeInstallUpdate;

  /// No description provided for @nodeServices.
  ///
  /// In en, this message translates to:
  /// **'Services'**
  String get nodeServices;

  /// No description provided for @nodeAdvancedConfig.
  ///
  /// In en, this message translates to:
  /// **'Advanced configuration'**
  String get nodeAdvancedConfig;

  /// No description provided for @nodeServiceStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get nodeServiceStatus;

  /// No description provided for @nodeServiceStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get nodeServiceStart;

  /// No description provided for @nodeServiceStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get nodeServiceStop;

  /// No description provided for @nodeServiceRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get nodeServiceRestart;

  /// No description provided for @nodeServiceEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable and start'**
  String get nodeServiceEnable;

  /// No description provided for @nodeServiceDisable.
  ///
  /// In en, this message translates to:
  /// **'Stop and disable'**
  String get nodeServiceDisable;

  /// No description provided for @nodeConfigLoad.
  ///
  /// In en, this message translates to:
  /// **'Load from server'**
  String get nodeConfigLoad;

  /// No description provided for @nodeConfigApply.
  ///
  /// In en, this message translates to:
  /// **'Validate, apply and restart'**
  String get nodeConfigApply;

  /// No description provided for @nodeConfigNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Load the current server config before editing it.'**
  String get nodeConfigNotLoaded;

  /// No description provided for @nodeUninstallSoftware.
  ///
  /// In en, this message translates to:
  /// **'Uninstall software (keep data)'**
  String get nodeUninstallSoftware;

  /// No description provided for @nodeDebootstrap.
  ///
  /// In en, this message translates to:
  /// **'Debootstrap node (erase everything)'**
  String get nodeDebootstrap;

  /// No description provided for @nodeDebootstrapConfirm.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes the remote node identity, state, configs and all veil/ogate/oproxy software. Type DELETE to continue.'**
  String get nodeDebootstrapConfirm;

  /// No description provided for @nodeDebootstrapType.
  ///
  /// In en, this message translates to:
  /// **'Type DELETE'**
  String get nodeDebootstrapType;

  /// No description provided for @nodeOperationOutput.
  ///
  /// In en, this message translates to:
  /// **'Server output'**
  String get nodeOperationOutput;

  /// No description provided for @nodeOperationRun.
  ///
  /// In en, this message translates to:
  /// **'Run command'**
  String get nodeOperationRun;

  /// No description provided for @nodeOperationSuccess.
  ///
  /// In en, this message translates to:
  /// **'Remote operation completed'**
  String get nodeOperationSuccess;

  /// No description provided for @nodeSelectServices.
  ///
  /// In en, this message translates to:
  /// **'Select services'**
  String get nodeSelectServices;

  /// No description provided for @provisionTitle.
  ///
  /// In en, this message translates to:
  /// **'Provision over SSH'**
  String get provisionTitle;

  /// No description provided for @provisionReleaseSection.
  ///
  /// In en, this message translates to:
  /// **'veil-cli release'**
  String get provisionReleaseSection;

  /// No description provided for @provisionReleaseTarget.
  ///
  /// In en, this message translates to:
  /// **'Server architecture'**
  String get provisionReleaseTarget;

  /// No description provided for @provisionReleaseTargetX64.
  ///
  /// In en, this message translates to:
  /// **'x86_64 Linux (portable musl)'**
  String get provisionReleaseTargetX64;

  /// No description provided for @provisionReleaseTargetArm64.
  ///
  /// In en, this message translates to:
  /// **'ARM64 Linux (portable musl)'**
  String get provisionReleaseTargetArm64;

  /// No description provided for @provisionReleaseRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh GitHub fields'**
  String get provisionReleaseRefresh;

  /// No description provided for @provisionSourceGithub.
  ///
  /// In en, this message translates to:
  /// **'GitHub release'**
  String get provisionSourceGithub;

  /// No description provided for @provisionSourceCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom link'**
  String get provisionSourceCustom;

  /// No description provided for @provisionReleaseLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading the latest release from GitHub…'**
  String get provisionReleaseLoading;

  /// No description provided for @provisionReleaseLoaded.
  ///
  /// In en, this message translates to:
  /// **'Loaded GitHub release {tag}'**
  String provisionReleaseLoaded(String tag);

  /// No description provided for @provisionReleaseError.
  ///
  /// In en, this message translates to:
  /// **'Could not auto-fill from GitHub: {error}. You can enter both values manually.'**
  String provisionReleaseError(String error);

  /// No description provided for @provisionReleaseUrl.
  ///
  /// In en, this message translates to:
  /// **'veil-cli release URL'**
  String get provisionReleaseUrl;

  /// No description provided for @provisionReleaseHint.
  ///
  /// In en, this message translates to:
  /// **'Filled automatically from the official veilnetwork/veil GitHub release. Choose Custom link to override it.'**
  String get provisionReleaseHint;

  /// No description provided for @provisionCustomReleaseHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a direct HTTPS link to your binary. You must also supply its SHA-256 below.'**
  String get provisionCustomReleaseHint;

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

  /// No description provided for @provisionComponents.
  ///
  /// In en, this message translates to:
  /// **'Components'**
  String get provisionComponents;

  /// No description provided for @provisionTransports.
  ///
  /// In en, this message translates to:
  /// **'Incoming transports'**
  String get provisionTransports;

  /// No description provided for @provisionTransportObfs4TcpHint.
  ///
  /// In en, this message translates to:
  /// **'Obfuscated TCP listener for censorship-resistant peer connections.'**
  String get provisionTransportObfs4TcpHint;

  /// No description provided for @provisionTransportTcpHint.
  ///
  /// In en, this message translates to:
  /// **'Plain TCP listener without transport encryption.'**
  String get provisionTransportTcpHint;

  /// No description provided for @provisionTransportTlsHint.
  ///
  /// In en, this message translates to:
  /// **'TCP listener protected by the shared TLS certificate below.'**
  String get provisionTransportTlsHint;

  /// No description provided for @provisionTransportQuicHint.
  ///
  /// In en, this message translates to:
  /// **'QUIC listener over UDP, protected by the shared TLS certificate below.'**
  String get provisionTransportQuicHint;

  /// No description provided for @provisionTransportWssHint.
  ///
  /// In en, this message translates to:
  /// **'Secure WebSocket listener, protected by the shared TLS certificate below.'**
  String get provisionTransportWssHint;

  /// No description provided for @provisionTransportPort.
  ///
  /// In en, this message translates to:
  /// **'{transport} port'**
  String provisionTransportPort(String transport);

  /// No description provided for @provisionTransportNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network protocol: {protocol}'**
  String provisionTransportNetwork(String protocol);

  /// No description provided for @provisionTransportCommon.
  ///
  /// In en, this message translates to:
  /// **'Shared transport settings'**
  String get provisionTransportCommon;

  /// No description provided for @provisionTransportCommonHint.
  ///
  /// In en, this message translates to:
  /// **'These values apply to every selected incoming transport.'**
  String get provisionTransportCommonHint;

  /// No description provided for @provisionAdvertiseHost.
  ///
  /// In en, this message translates to:
  /// **'Public host / IP (optional)'**
  String get provisionAdvertiseHost;

  /// No description provided for @provisionAdvertiseHostHint.
  ///
  /// In en, this message translates to:
  /// **'The same public address is advertised for every selected transport; each one keeps its own port.'**
  String get provisionAdvertiseHostHint;

  /// No description provided for @provisionTlsShared.
  ///
  /// In en, this message translates to:
  /// **'TLS certificate'**
  String get provisionTlsShared;

  /// No description provided for @provisionTlsSharedHint.
  ///
  /// In en, this message translates to:
  /// **'Used by: {transports}. Choose how the certificate is supplied to every selected TLS transport.'**
  String provisionTlsSharedHint(String transports);

  /// No description provided for @provisionTlsMode.
  ///
  /// In en, this message translates to:
  /// **'Certificate source'**
  String get provisionTlsMode;

  /// No description provided for @provisionTlsModeExisting.
  ///
  /// In en, this message translates to:
  /// **'Existing files'**
  String get provisionTlsModeExisting;

  /// No description provided for @provisionTlsModeAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get provisionTlsModeAutomatic;

  /// No description provided for @provisionTlsModeSelfSigned.
  ///
  /// In en, this message translates to:
  /// **'Self-signed'**
  String get provisionTlsModeSelfSigned;

  /// No description provided for @provisionTlsAutomaticName.
  ///
  /// In en, this message translates to:
  /// **'Domain or IP (optional override)'**
  String get provisionTlsAutomaticName;

  /// No description provided for @provisionTlsAutomaticNameHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the public host / IP above. A DNS name gets Let\'s Encrypt; an IP gets a self-signed certificate with an IP SAN.'**
  String get provisionTlsAutomaticNameHint;

  /// No description provided for @provisionTlsLetsEncryptHint.
  ///
  /// In en, this message translates to:
  /// **'Let\'s Encrypt will be requested on the server. The domain must point to this server and inbound TCP port 80 must be open. Renewal is configured automatically.'**
  String get provisionTlsLetsEncryptHint;

  /// No description provided for @provisionTlsIpHint.
  ///
  /// In en, this message translates to:
  /// **'An IP address cannot use the standard Let\'s Encrypt flow here. A self-signed certificate with this IP in its SAN will be generated on the server.'**
  String get provisionTlsIpHint;

  /// No description provided for @provisionTlsUnknownHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a domain or IP here, or set the public host / IP above.'**
  String get provisionTlsUnknownHint;

  /// No description provided for @provisionTlsEmail.
  ///
  /// In en, this message translates to:
  /// **'Let\'s Encrypt account email'**
  String get provisionTlsEmail;

  /// No description provided for @provisionTlsAgreeTerms.
  ///
  /// In en, this message translates to:
  /// **'I agree to the Let\'s Encrypt terms of service'**
  String get provisionTlsAgreeTerms;

  /// No description provided for @provisionTlsSelfSignedName.
  ///
  /// In en, this message translates to:
  /// **'Domain or IP in the certificate'**
  String get provisionTlsSelfSignedName;

  /// No description provided for @provisionTlsSelfSignedNameHint.
  ///
  /// In en, this message translates to:
  /// **'The value is written into the certificate\'s DNS or IP subject alternative name.'**
  String get provisionTlsSelfSignedNameHint;

  /// No description provided for @provisionTlsSelfSignedDays.
  ///
  /// In en, this message translates to:
  /// **'Validity in days (1–3650)'**
  String get provisionTlsSelfSignedDays;

  /// No description provided for @provisionTlsSelfSignedHint.
  ///
  /// In en, this message translates to:
  /// **'Clients must trust this self-signed certificate explicitly. Its private key is generated and kept on the server.'**
  String get provisionTlsSelfSignedHint;

  /// No description provided for @provisionTlsCert.
  ///
  /// In en, this message translates to:
  /// **'Remote TLS certificate path'**
  String get provisionTlsCert;

  /// No description provided for @provisionTlsKey.
  ///
  /// In en, this message translates to:
  /// **'Remote TLS private-key path'**
  String get provisionTlsKey;

  /// No description provided for @provisionTlsCa.
  ///
  /// In en, this message translates to:
  /// **'Remote TLS CA path (optional)'**
  String get provisionTlsCa;

  /// No description provided for @provisionComponentUrl.
  ///
  /// In en, this message translates to:
  /// **'{component} release URL'**
  String provisionComponentUrl(String component);

  /// No description provided for @provisionComponentSha.
  ///
  /// In en, this message translates to:
  /// **'{component} SHA-256'**
  String provisionComponentSha(String component);

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

  /// No description provided for @provisionInvalidConfig.
  ///
  /// In en, this message translates to:
  /// **'Check the required release, transport, port, and TLS fields'**
  String get provisionInvalidConfig;

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
  /// **'Credentials entered here are used once. Manage saved credentials in the node card.'**
  String get sshCredsNotSaved;

  /// No description provided for @sshCredentialsTitle.
  ///
  /// In en, this message translates to:
  /// **'SSH authentication'**
  String get sshCredentialsTitle;

  /// No description provided for @sshSavedPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Saved SSH password (optional)'**
  String get sshSavedPasswordLabel;

  /// No description provided for @sshSavedPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to remove the saved password.'**
  String get sshSavedPasswordHint;

  /// No description provided for @sshCredentialsEncryptedHint.
  ///
  /// In en, this message translates to:
  /// **'The password and private key are stored only inside xVeil\'s encrypted container.'**
  String get sshCredentialsEncryptedHint;

  /// No description provided for @sshCredentialsEndpointCleared.
  ///
  /// In en, this message translates to:
  /// **'The SSH endpoint changed, so the saved password and key were cleared for safety.'**
  String get sshCredentialsEndpointCleared;

  /// No description provided for @sshGenerateEd25519.
  ///
  /// In en, this message translates to:
  /// **'Generate an Ed25519 key'**
  String get sshGenerateEd25519;

  /// No description provided for @sshRegenerateEd25519.
  ///
  /// In en, this message translates to:
  /// **'Generate a new Ed25519 key'**
  String get sshRegenerateEd25519;

  /// No description provided for @sshSavedEd25519Title.
  ///
  /// In en, this message translates to:
  /// **'Saved Ed25519 key'**
  String get sshSavedEd25519Title;

  /// No description provided for @sshPublicKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Add this line to ~/.ssh/authorized_keys on the server:'**
  String get sshPublicKeyLabel;

  /// No description provided for @sshCopyPublicKey.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get sshCopyPublicKey;

  /// No description provided for @sshPublicKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Public key copied'**
  String get sshPublicKeyCopied;

  /// No description provided for @sshRemoveSavedKey.
  ///
  /// In en, this message translates to:
  /// **'Remove saved key'**
  String get sshRemoveSavedKey;

  /// No description provided for @sshUseSavedKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the saved Ed25519 key.'**
  String get sshUseSavedKeyHint;

  /// No description provided for @sshOtherKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Another private key (PEM, this time only)'**
  String get sshOtherKeyLabel;

  /// No description provided for @sshCredentialRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a password or private key'**
  String get sshCredentialRequired;

  /// No description provided for @sshCredentialsSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get sshCredentialsSaving;

  /// No description provided for @sshCredentialsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save SSH credentials: {error}'**
  String sshCredentialsSaveFailed(String error);

  /// No description provided for @sshKeyGenerationFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not generate the key: {error}'**
  String sshKeyGenerationFailed(String error);

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

  /// No description provided for @callBatteryAllowTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep calls alive in the background?'**
  String get callBatteryAllowTitle;

  /// No description provided for @callBatteryAllowBody.
  ///
  /// In en, this message translates to:
  /// **'Some phones stop a call when you switch away from xVeil. Allow it to ignore battery optimization so backgrounded calls keep running.'**
  String get callBatteryAllowBody;

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

  /// No description provided for @recoveryPhraseHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your recovery phrase, words separated by spaces'**
  String get recoveryPhraseHint;

  /// No description provided for @securityCenterTooltip.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get securityCenterTooltip;

  /// No description provided for @securityCenterTitle.
  ///
  /// In en, this message translates to:
  /// **'Security & network'**
  String get securityCenterTitle;

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

  /// No description provided for @callDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get callDevices;

  /// No description provided for @callSettingsAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get callSettingsAudio;

  /// No description provided for @callSettingsVideo.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get callSettingsVideo;

  /// No description provided for @callAudioOutput.
  ///
  /// In en, this message translates to:
  /// **'Audio output'**
  String get callAudioOutput;

  /// No description provided for @callSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get callSpeaker;

  /// No description provided for @callEarpiece.
  ///
  /// In en, this message translates to:
  /// **'Phone earpiece'**
  String get callEarpiece;

  /// No description provided for @callCameras.
  ///
  /// In en, this message translates to:
  /// **'Cameras'**
  String get callCameras;

  /// No description provided for @callMicrophones.
  ///
  /// In en, this message translates to:
  /// **'Microphones'**
  String get callMicrophones;

  /// No description provided for @callScreens.
  ///
  /// In en, this message translates to:
  /// **'Screens'**
  String get callScreens;

  /// No description provided for @callNoCaptureDevices.
  ///
  /// In en, this message translates to:
  /// **'No capture devices available'**
  String get callNoCaptureDevices;

  /// No description provided for @callDeviceSwitchFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not switch device'**
  String get callDeviceSwitchFailed;

  /// No description provided for @callSwitchCamera.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get callSwitchCamera;

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

  /// No description provided for @callScreenWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for shared screen…'**
  String get callScreenWaiting;

  /// No description provided for @groupCallOngoing.
  ///
  /// In en, this message translates to:
  /// **'Group call in progress'**
  String get groupCallOngoing;

  /// No description provided for @groupCallJoinAction.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get groupCallJoinAction;

  /// No description provided for @callVideoPaused.
  ///
  /// In en, this message translates to:
  /// **'Video paused'**
  String get callVideoPaused;

  /// No description provided for @callVideoWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for video…'**
  String get callVideoWaiting;

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

  /// No description provided for @callPathNoDirectSession.
  ///
  /// In en, this message translates to:
  /// **'no direct link'**
  String get callPathNoDirectSession;

  /// No description provided for @groupCallTitle.
  ///
  /// In en, this message translates to:
  /// **'Group call'**
  String get groupCallTitle;

  /// No description provided for @groupCallIncoming.
  ///
  /// In en, this message translates to:
  /// **'Incoming group call'**
  String get groupCallIncoming;

  /// No description provided for @groupCallStartAudio.
  ///
  /// In en, this message translates to:
  /// **'Start group audio call'**
  String get groupCallStartAudio;

  /// No description provided for @groupCallStartVideo.
  ///
  /// In en, this message translates to:
  /// **'Start group video call'**
  String get groupCallStartVideo;

  /// No description provided for @groupCallBusy.
  ///
  /// In en, this message translates to:
  /// **'Another call is already active'**
  String get groupCallBusy;

  /// No description provided for @groupCallLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave call'**
  String get groupCallLeave;

  /// No description provided for @groupCallEndEveryone.
  ///
  /// In en, this message translates to:
  /// **'End for everyone'**
  String get groupCallEndEveryone;

  /// No description provided for @groupCallMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize group call'**
  String get groupCallMinimize;

  /// No description provided for @groupCallExpand.
  ///
  /// In en, this message translates to:
  /// **'Open group call'**
  String get groupCallExpand;

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

  /// No description provided for @composerCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get composerCamera;

  /// No description provided for @composerUploadPhoto.
  ///
  /// In en, this message translates to:
  /// **'Upload photo'**
  String get composerUploadPhoto;

  /// No description provided for @composerUploadVideo.
  ///
  /// In en, this message translates to:
  /// **'Upload video'**
  String get composerUploadVideo;

  /// No description provided for @composerUploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload file'**
  String get composerUploadFile;

  /// No description provided for @composerPoll.
  ///
  /// In en, this message translates to:
  /// **'Poll'**
  String get composerPoll;

  /// No description provided for @composerLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get composerLocation;

  /// No description provided for @composerPlanned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get composerPlanned;

  /// No description provided for @composerGif.
  ///
  /// In en, this message translates to:
  /// **'GIF'**
  String get composerGif;

  /// No description provided for @composerGifLocal.
  ///
  /// In en, this message translates to:
  /// **'Choose GIF from device'**
  String get composerGifLocal;

  /// No description provided for @composerGifPrivacy.
  ///
  /// In en, this message translates to:
  /// **'No external GIF search: your query never leaves xVeil.'**
  String get composerGifPrivacy;

  /// No description provided for @composerCameraUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Camera capture is unavailable on this device'**
  String get composerCameraUnavailable;

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

  /// No description provided for @cloudSharedCompact.
  ///
  /// In en, this message translates to:
  /// **'Compact history'**
  String get cloudSharedCompact;

  /// No description provided for @cloudSharedCompactTitle.
  ///
  /// In en, this message translates to:
  /// **'Ask current editors to confirm the exact synchronized state, then automatically replace the old encrypted history with a signed checkpoint? Offline editors will safely delay compaction. Current content, access and edit continuity are preserved.'**
  String get cloudSharedCompactTitle;

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

  /// No description provided for @spaceRulesTitle.
  ///
  /// In en, this message translates to:
  /// **'Community rules'**
  String get spaceRulesTitle;

  /// No description provided for @spaceRulesEmpty.
  ///
  /// In en, this message translates to:
  /// **'This community has not published rules yet.'**
  String get spaceRulesEmpty;

  /// No description provided for @spaceRulesPublish.
  ///
  /// In en, this message translates to:
  /// **'Publish rules'**
  String get spaceRulesPublish;

  /// No description provided for @spaceRulesPublishVersion.
  ///
  /// In en, this message translates to:
  /// **'Publish rules version {version}'**
  String spaceRulesPublishVersion(int version);

  /// No description provided for @spaceRulesFullText.
  ///
  /// In en, this message translates to:
  /// **'Full rules'**
  String get spaceRulesFullText;

  /// No description provided for @spaceRulesSummary.
  ///
  /// In en, this message translates to:
  /// **'Short summary'**
  String get spaceRulesSummary;

  /// No description provided for @spaceRulesEffectiveDate.
  ///
  /// In en, this message translates to:
  /// **'Effective date'**
  String get spaceRulesEffectiveDate;

  /// No description provided for @spaceRulesEffective.
  ///
  /// In en, this message translates to:
  /// **'Effective {date}'**
  String spaceRulesEffective(String date);

  /// No description provided for @spaceRulesVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String spaceRulesVersion(int version);

  /// No description provided for @spaceRulesAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept rules'**
  String get spaceRulesAccept;

  /// No description provided for @spaceRulesAccepted.
  ///
  /// In en, this message translates to:
  /// **'Rules accepted'**
  String get spaceRulesAccepted;

  /// No description provided for @spaceRulesAcceptanceRequired.
  ///
  /// In en, this message translates to:
  /// **'Please review and accept the current rules'**
  String get spaceRulesAcceptanceRequired;

  /// No description provided for @spaceRulesHistory.
  ///
  /// In en, this message translates to:
  /// **'Previous versions'**
  String get spaceRulesHistory;

  /// No description provided for @spaceModerationTitle.
  ///
  /// In en, this message translates to:
  /// **'Moderation'**
  String get spaceModerationTitle;

  /// No description provided for @spaceModerationEmpty.
  ///
  /// In en, this message translates to:
  /// **'No moderation actions have been recorded.'**
  String get spaceModerationEmpty;

  /// No description provided for @spaceModerationAdd.
  ///
  /// In en, this message translates to:
  /// **'New moderation action'**
  String get spaceModerationAdd;

  /// No description provided for @spaceModerationTarget.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get spaceModerationTarget;

  /// No description provided for @spaceModerationAction.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get spaceModerationAction;

  /// No description provided for @spaceModerationReason.
  ///
  /// In en, this message translates to:
  /// **'Reason'**
  String get spaceModerationReason;

  /// No description provided for @spaceModerationDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get spaceModerationDuration;

  /// No description provided for @spaceModerationNoExpiry.
  ///
  /// In en, this message translates to:
  /// **'Until revoked'**
  String get spaceModerationNoExpiry;

  /// No description provided for @spaceModerationOneHour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get spaceModerationOneHour;

  /// No description provided for @spaceModerationOneDay.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get spaceModerationOneDay;

  /// No description provided for @spaceModerationOneWeek.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get spaceModerationOneWeek;

  /// No description provided for @spaceModerationActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get spaceModerationActive;

  /// No description provided for @spaceModerationExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get spaceModerationExpired;

  /// No description provided for @spaceModerationRevoked.
  ///
  /// In en, this message translates to:
  /// **'Revoked'**
  String get spaceModerationRevoked;

  /// No description provided for @spaceModerationRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke action'**
  String get spaceModerationRevoke;

  /// No description provided for @spaceModerationRevokeReason.
  ///
  /// In en, this message translates to:
  /// **'Reason for revocation'**
  String get spaceModerationRevokeReason;

  /// No description provided for @spaceModerationWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get spaceModerationWarning;

  /// No description provided for @spaceModerationDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Remove message'**
  String get spaceModerationDeleteMessage;

  /// No description provided for @spaceModerationDeletePost.
  ///
  /// In en, this message translates to:
  /// **'Remove publication'**
  String get spaceModerationDeletePost;

  /// No description provided for @spaceModerationRestrictPublishing.
  ///
  /// In en, this message translates to:
  /// **'Temporarily restrict publications'**
  String get spaceModerationRestrictPublishing;

  /// No description provided for @spaceModerationRestrictMessages.
  ///
  /// In en, this message translates to:
  /// **'Prevent sending messages'**
  String get spaceModerationRestrictMessages;

  /// No description provided for @spaceModerationRestrictVoice.
  ///
  /// In en, this message translates to:
  /// **'Prevent joining voice channels'**
  String get spaceModerationRestrictVoice;

  /// No description provided for @spaceModerationMute.
  ///
  /// In en, this message translates to:
  /// **'Mute messages and voice'**
  String get spaceModerationMute;

  /// No description provided for @spaceModerationTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get spaceModerationTimeout;

  /// No description provided for @spaceModerationTemporaryBan.
  ///
  /// In en, this message translates to:
  /// **'Temporary ban'**
  String get spaceModerationTemporaryBan;

  /// No description provided for @spaceModerationPermanentBan.
  ///
  /// In en, this message translates to:
  /// **'Permanent ban'**
  String get spaceModerationPermanentBan;

  /// No description provided for @spaceModerationUntil.
  ///
  /// In en, this message translates to:
  /// **'Until {date}'**
  String spaceModerationUntil(String date);

  /// No description provided for @spaceModerationAppealsTitle.
  ///
  /// In en, this message translates to:
  /// **'Moderation appeals'**
  String get spaceModerationAppealsTitle;

  /// No description provided for @spaceModerationAppealAction.
  ///
  /// In en, this message translates to:
  /// **'Appeal'**
  String get spaceModerationAppealAction;

  /// No description provided for @spaceModerationAppealDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Appeal moderation action'**
  String get spaceModerationAppealDialogTitle;

  /// No description provided for @spaceModerationAppealText.
  ///
  /// In en, this message translates to:
  /// **'Explain why this action should be reviewed'**
  String get spaceModerationAppealText;

  /// No description provided for @spaceModerationAppealSent.
  ///
  /// In en, this message translates to:
  /// **'Appeal sent'**
  String get spaceModerationAppealSent;

  /// No description provided for @spaceModerationAppealPending.
  ///
  /// In en, this message translates to:
  /// **'Awaiting review'**
  String get spaceModerationAppealPending;

  /// No description provided for @spaceModerationAppealRejected.
  ///
  /// In en, this message translates to:
  /// **'Appeal rejected'**
  String get spaceModerationAppealRejected;

  /// No description provided for @spaceModerationAppealRevoked.
  ///
  /// In en, this message translates to:
  /// **'Action revoked after review'**
  String get spaceModerationAppealRevoked;

  /// No description provided for @spaceModerationAppealAcknowledged.
  ///
  /// In en, this message translates to:
  /// **'Appeal accepted; removed content cannot be restored'**
  String get spaceModerationAppealAcknowledged;

  /// No description provided for @spaceModerationAppealFrom.
  ///
  /// In en, this message translates to:
  /// **'Appeal from {node}'**
  String spaceModerationAppealFrom(String node);

  /// No description provided for @spaceModerationAppealReview.
  ///
  /// In en, this message translates to:
  /// **'Review appeal'**
  String get spaceModerationAppealReview;

  /// No description provided for @spaceModerationAppealDecisionReason.
  ///
  /// In en, this message translates to:
  /// **'Decision explanation'**
  String get spaceModerationAppealDecisionReason;

  /// No description provided for @spaceModerationAppealDecisionReject.
  ///
  /// In en, this message translates to:
  /// **'Uphold action'**
  String get spaceModerationAppealDecisionReject;

  /// No description provided for @spaceModerationAppealDecisionRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke action'**
  String get spaceModerationAppealDecisionRevoke;

  /// No description provided for @spaceModerationAppealDecisionAcknowledge.
  ///
  /// In en, this message translates to:
  /// **'Accept without restoration'**
  String get spaceModerationAppealDecisionAcknowledge;
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
