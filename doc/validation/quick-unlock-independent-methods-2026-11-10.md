# Biometric startup entry with an existing screen-lock pattern

Confirmed in a real settings/vault widget fixture: create a screen-lock pattern,
leave startup entry unconfigured, then enable biometrics and startup entry without
redrawing the screen-lock pattern. The screen settings were saved, but startup
vault configuration failed because it also tried to enroll the unknown pattern.
This can leave no biometric button on the next container-opening screen. It is a
confirmed mechanism; the original reporter's exact configuration is unknown.

The settings form now enrolls biometric startup entry independently when the
existing screen pattern has not been re-entered. That screen-lock pattern remains
configured. A pattern is included in startup entry only when already enrolled
there or confirmed in the form. The form explains the biometric-only outcome.
Password confirmation, OS authentication, identity ownership checks and protected
storage are unchanged. Pattern-only enrollment still requires confirmation.

Checks: 35 passing tests across settings, startup vault, Android storage bridge
and screen-lock authentication, no skips. The old settings flow failed the
completed-save expectation in the confirmed case; the candidate passes. Initial
fixture attempts with offscreen controls were corrected and are not product reds.
Phone-sized widget checks also verify visible, working biometric buttons with no
pattern on both cold container startup and the reloaded screen cover. Those
checks use mocked OS authentication, not a physical fingerprint sensor.

Physical qualification of this particular settings flow on Android is pending.
