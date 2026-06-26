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
  String get chatMsgCopy => 'Copy text';

  @override
  String get chatMsgCopied => 'Copied';

  @override
  String get chatLoadEarlier => 'Load earlier messages';

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
  String get inviteScanComingSoon => 'Camera scanning coming soon';

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
  String get networkRouteSub => 'oproxy / ogate — coming soon';

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
}
