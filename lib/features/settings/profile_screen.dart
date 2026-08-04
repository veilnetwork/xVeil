import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/storage/app_profile.dart';
import '../../data/storage/profile_prefs_store.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart' show activeProfile;
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
    await writeRememberedProfile(support.path, name);
    if (!mounted) return;
    setState(() => _selected = name);
    final l = AppL10n.of(context);
    if (name != activeProfile) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileRestartRequired)));
    }
  }

  Future<void> _create() async {
    final l = AppL10n.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.profileCreateTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l.profileNameHint,
            helperText: l.profileNameRule,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l.commonCreate),
          ),
        ],
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
