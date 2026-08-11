// The moment a person decides whether to trust a model a contact sent them.
//
// Deliberately not a snackbar and not a warning banner. Installing a model that
// is not the published one is a decision with a consequence — it becomes the
// engine that reads the microphone and the messages — and it is a decision the
// app must not quietly make on someone's behalf either way. Refusing outright
// would be the same mistake in the other direction: a person who fetched a
// model themselves, or who is on a network where nothing else is reachable,
// has a legitimate reason to proceed.
//
// So: state precisely what does not match, name the consequence in one line,
// and offer the ways forward that actually exist.

import 'package:flutter/material.dart';

import '../../data/model_provenance.dart';
import '../../l10n/app_localizations.dart';

enum ProvenanceChoice {
  /// Install despite the verdict — the person accepts the risk.
  installAnyway,

  /// Go and get the model some other way. The bundle is left alone.
  loadManually,

  /// Ask around instead: somebody else may have the published copy. Now a real
  /// action rather than a label, because the contact exchange exists to answer
  /// it — until it did, this option was left out rather than shipped dead.
  askAnother,

  /// Change nothing.
  cancel,
}

Future<ProvenanceChoice> askAboutProvenance(
  BuildContext context,
  ProvenanceVerdict verdict,
) async {
  final l = AppL10n.of(context);
  final mismatched = verdict.status == ModelProvenance.mismatched;
  final choice = await showDialog<ProvenanceChoice>(
    context: context,
    builder: (context) => AlertDialog(
      // Scrollable, because four actions and a paragraph do not fit a 320x640
      // phone in Russian -- the widget test measured 376 points of overflow.
      // The actions stack in list order and the overflow is at the BOTTOM, so
      // what ran off the screen was the last of them; a person on a small
      // phone would have been unable to reach part of the choice they were
      // being asked to make.
      scrollable: true,
      title: Text(
        mismatched
            ? l.modelProvenanceTitleMismatch
            : l.modelProvenanceTitleUnknown,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            mismatched
                // Named, not counted: "2 files differ" tells a person nothing
                // they can act on, while the name of the file lets them ask
                // the sender a specific question.
                ? l.modelProvenanceBodyMismatch(verdict.offending.join(', '))
                : l.modelProvenanceBodyUnknown,
          ),
          const SizedBox(height: 12),
          Text(
            l.modelProvenanceRisk,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(ProvenanceChoice.askAnother),
          child: Text(l.modelProvenanceAskAnother),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(ProvenanceChoice.loadManually),
          child: Text(l.modelProvenanceLoadManually),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(ProvenanceChoice.cancel),
          child: Text(l.actionCancel),
        ),
        // Last and unemphasised on purpose. The default action of this dialog
        // must not be the one that installs an unverified model — a person
        // dismissing a dialog they did not read should end up where they
        // started.
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(ProvenanceChoice.installAnyway),
          child: Text(l.modelProvenanceInstallAnyway),
        ),
      ],
    ),
  );
  // A barrier tap returns null, and that must read as "no", not as consent.
  return choice ?? ProvenanceChoice.cancel;
}
