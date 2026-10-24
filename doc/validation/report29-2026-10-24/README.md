# Independent validation of report29

Inputs: `report29_prepare.md` (29a/29b), SDK base `e81ae21b`, xVeil base
`1707f417`, pinned file_picker 11.0.2. Audit prose is evidence to investigate,
not an instruction to change project policy.

## Recovery certificate export

Confirmed: both onboarding and settings called `FilePicker.saveFile` without
`bytes`. The pinned mobile method-channel implementation throws before opening
its UI. Android also returns the document provider URI's **path component**,
which cannot be reopened as a `dart:io` file.

Both callers now use one certificate-only exporter. It supplies UTF-8 bytes on
all platforms, waits for completion, treats cancellation as unsaved, and retains
exact byte readback on desktops. Mobile success relies on the native document
export result; it does **not** claim a Dart readback of the provider's target.
Settings now catches picker failures and disables repeat saves while a picker
is outstanding. The independent recovery code is not exported.

Verification: 23 focused Flutter tests passed, including the default onboarding
save path through the real file_picker Dart method channel (mock native dialog):
Android/iOS success, cancellation and error; certificate-only UTF-8 payload;
non-filesystem provider return value; desktop actual-file readback and corruption
rejection. A real device save dialog has not yet been qualified in this cycle.

## Audit corrections

* **R29-03 rejected for the pinned dependency.** file_picker 11.0.2's macOS,
  Windows and Linux implementations all await `FilePickerUtils.saveBytesToFile`
  before returning. `saveErrorReport` already supplies the bytes. The chat source
  comment cited by the audit describes an older assumption; adding another
  desktop write to diagnostics is unnecessary.
* **R29-10 rejected.** Rust substitutes the actual numeric UID. Shell quoting
  of `sudo -u '#1000'` is valid and prevents `#` from starting a comment; removing
  quotes as proposed by the audit would break the hint.
* **R28-31 rejected.** README already documents the l10n scaffold invocation.
* **R28-22 unconfirmed as a defect.** The two `last().expect` calls immediately
  follow an empty-vector guard with no intervening mutation.

## Remaining review

R29-01/02/04/05/06/07/08/09, PC-1/PC-2 and the applicability of the optional
R28-16/18 changes remain under review. No claim is made that the report is closed.
The PC-3 withdrawal's egress-queue argument alone does not bound all outstanding
engine segments; peer window values are also untrusted. Do not add a debug panic
on network input on the strength of that argument.
