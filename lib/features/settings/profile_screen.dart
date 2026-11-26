import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/error_journal.dart';
import '../../core/storage_acl_vault.dart';
import '../../data/storage/app_profile.dart';
import '../../data/storage/async_kv_log_store.dart'
    show managedStorageFailureReason;
import '../../data/storage/managed_fs_contract.dart' show ManagedFsFailure;
import '../../data/storage/profile_prefs_store.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../common/async_error_view.dart';
import '../bootstrap/startup_failed_app.dart'
    show preferencesFailureText, StorageAclDetails;

/// The hidden profile switcher: which on-disk profile the app starts on.
///
/// Reached only after the switcher has been revealed (three taps on the
/// settings title). A profile is a directory choice, not an identity and not a
/// security boundary — each holds its own container, so switching is closer to
/// "start a different installation" than to "switch account", and it takes
/// effect on the next launch rather than live: the container, the node and
/// every service below them are bound at startup.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  List<String>? _profiles;
  String? _selected;
  late String _supportPath;
  ({Object error, StackTrace stack})? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final support = await getApplicationSupportDirectory();
      final names = <String>{AppProfiles.defaultName, activeProfile};
      final dir = Directory('${support.path}/profiles');
      try {
        await for (final entry in dir.list().where(
          (entry) => entry is Directory,
        )) {
          final name = lastPathSegment(entry.path);
          if (AppProfiles.isValidName(name)) names.add(name);
        }
      } on PathNotFoundException {
        if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
      final remembered = await readProfileChoice(
        File(activeProfilePath(support.path)),
      );
      if (!mounted) return;
      setState(() {
        _supportPath = support.path;
        _profiles = names.toList()..sort();
        _selected = remembered ?? activeProfile;
      });
    } catch (error, stack) {
      if (!mounted) return;
      if (error is ManagedFsFailure &&
          error.aclWarnings.isNotEmpty &&
          await _reviewAcl(error)) {
        if (mounted) await _load();
        return;
      }
      if (!mounted) return;
      setState(() => _loadError = (error: error, stack: stack));
    }
  }

  Future<bool> _reviewAcl(ManagedFsFailure failure) async {
    final warning = failure.aclWarnings.single;
    if (await restoreRememberedStorageAcl(warning)) return true;
    if (!mounted) return false;
    final l = AppL10n.of(context);
    final remember = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(l.startupAclWarningTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.startupAclFileWarningRisk),
            const SizedBox(height: 8),
            StorageAclDetails(warning),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.actionCancel),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.profileAclContinueOnce),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.profileAclRememberChoice),
          ),
        ],
      ),
    );
    if (!mounted || remember == null) return false;
    final saved = await recordStorageAclApproval(warning, remember: remember);
    if (mounted && !saved) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.startupAclApprovalFailed)));
    }
    return saved;
  }

  void _retry() {
    if (_loadError == null) return;
    setState(() => _loadError = null);
    unawaited(_load());
  }

  Future<void> _forgetPermissionChoices() async {
    final l = AppL10n.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.profileAclResetTitle),
        content: Text(l.profileAclResetConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.profileAclResetTitle),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    final reset = await forgetRememberedStorageAclApprovals();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(reset ? l.profileAclResetDone : l.profileAclResetFailed),
      ),
    );
  }

  Future<void> _choose(String name) async {
    Object? failure;
    final recorded = await writeRememberedProfile(
      _supportPath,
      name,
      onFailure: (error) => failure = error,
    );
    if (!mounted) return;
    final l = AppL10n.of(context);
    if (!recorded) {
      // The write reports honestly now (audit X-02). Showing the choice as
      // taken when the next launch will not see it is how someone ends up in a
      // different identity than the one they picked.
      final error = failure;
      if (error is ManagedFsFailure && error.aclWarnings.isNotEmpty) {
        if (await _reviewAcl(error) && mounted) await _choose(name);
        return;
      }
      final explanation = error == null
          ? null
          : preferencesFailureText(l, managedStorageFailureReason(error));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(explanation ?? l.profileChoiceNotSaved)),
      );
      return;
    }
    setState(() => _selected = name);
    if (name != activeProfile) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileRestartRequired)));
    }
  }

  Future<void> _create() async {
    final l = AppL10n.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NewProfileNameDialog(
        title: l.profileCreateTitle,
        hint: l.profileNameHint,
        helper: l.profileNameRule,
        cancelLabel: l.actionCancel,
        createLabel: l.commonCreate,
      ),
    );
    if (!mounted || name == null || name.isEmpty) return;
    final profile = name.toLowerCase();
    if (!AppProfiles.isValidName(profile)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileNameRule)));
      return;
    }
    try {
      await Directory(
        AppProfiles.directory(_supportPath, profile),
      ).create(recursive: true);
    } catch (error, stack) {
      errorJournal.record(
        kind: 'profile-create',
        error: error,
        stack: stack,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileCreateFailed)));
      return;
    }
    if (!mounted) return;
    setState(() => _profiles = {..._profiles!, profile}.toList()..sort());
    await _choose(profile);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final profiles = _profiles;
    final failure = _loadError;
    final filesystemError = failure?.error;
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.profileTitle),
      ),
      floatingActionButton: profiles == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: Text(l.commonCreate),
            ),
      body: filesystemError is ManagedFsFailure
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preferencesFailureText(
                            l,
                            managedStorageFailureReason(filesystemError),
                          ) ??
                          l.profileChoiceNotSaved,
                    ),
                    if (filesystemError.path case final path?)
                      SelectableText(path),
                    TextButton(onPressed: _retry, child: Text(l.startupRetry)),
                  ],
                ),
              ),
            )
          : failure != null
          ? AsyncErrorView(
              key: ObjectKey(failure.error),
              error: failure.error,
              stack: failure.stack,
              where: 'profiles',
              onRetry: _retry,
            )
          : profiles == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    l.profileExplainer,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_reset_outlined),
                  title: Text(l.profileAclResetTitle),
                  subtitle: Text(l.profileAclResetHint),
                  onTap: _forgetPermissionChoices,
                ),
                for (final name in profiles)
                  ListTile(
                    leading: Icon(
                      name == _selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(
                      name == AppProfiles.defaultName
                          ? l.profileDefaultName
                          : name,
                    ),
                    subtitle: name == activeProfile
                        ? Text(l.profileRunningNow)
                        : null,
                    onTap: () => _choose(name),
                  ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l.profileSwitchNote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Names a new profile, owning the controller that holds the name.
///
/// A controller built beside `showDialog` and left to the caller is one
/// `dispose()` away from the disposal race that put a red screen on the cloud
/// prompts: `showDialog`'s future completes while the route is still animating
/// out, so a caller that disposes on the next line kills a live `TextField`.
/// Owned by the widget that renders it, the lifetime cannot be got wrong.
class _NewProfileNameDialog extends StatefulWidget {
  const _NewProfileNameDialog({
    required this.title,
    required this.hint,
    required this.helper,
    required this.cancelLabel,
    required this.createLabel,
  });

  final String title;
  final String hint;
  final String helper;
  final String cancelLabel;
  final String createLabel;

  @override
  State<_NewProfileNameDialog> createState() => _NewProfileNameDialogState();
}

class _NewProfileNameDialogState extends State<_NewProfileNameDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hint,
          helper: Text(widget.helper),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: Text(widget.createLabel),
        ),
      ],
    );
  }
}
