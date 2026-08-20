import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/storage/app_profile.dart';
import '../../data/storage/profile_prefs_store.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final support = await getApplicationSupportDirectory();
    final names = <String>{AppProfiles.defaultName, activeProfile};
    final dir = Directory('${support.path}/profiles');
    if (dir.existsSync()) {
      for (final entry in dir.listSync().whereType<Directory>()) {
        final name = entry.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
        // Only list what this build would actually accept, so a directory
        // created by hand under a name we refuse cannot look selectable.
        if (AppProfiles.isValidName(name)) names.add(name);
      }
    }
    // NOT a preference (audit XV-16): the choice has to be readable before the
    // per-profile preference file it would otherwise live in is even located,
    // and as a preference it sat in the system store that iOS backs up — where
    // the name of the profile in use is exactly the fact worth hiding.
    final remembered = await readRememberedProfile(support.path);
    if (!mounted) return;
    setState(() {
      _profiles = names.toList()..sort();
      _selected = remembered ?? activeProfile;
    });
  }

  Future<void> _choose(String name) async {
    final support = await getApplicationSupportDirectory();
    final recorded = await writeRememberedProfile(support.path, name);
    if (!mounted) return;
    final l = AppL10n.of(context);
    if (!recorded) {
      // The write reports honestly now (audit X-02). Showing the choice as
      // taken when the next launch will not see it is how someone ends up in a
      // different identity than the one they picked.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileChoiceNotSaved)));
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
    if (name == null || name.isEmpty) return;
    if (!AppProfiles.isValidName(name.toLowerCase())) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileNameRule)));
      return;
    }
    final support = await getApplicationSupportDirectory();
    await Directory(
      AppProfiles.directory(support.path, name.toLowerCase()),
    ).create(recursive: true);
    await _load();
    await _choose(name.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final profiles = _profiles;
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.profileTitle),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(l.commonCreate),
      ),
      body: profiles == null
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
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hint,
          helperText: widget.helper,
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
