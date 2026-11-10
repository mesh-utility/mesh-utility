/// First-run ordering helper.
///
/// The Flutter privacy dialog must finish (accept or skip) before any OS
/// permission sheet is requested. Requesting location or notifications
/// while that dialog is visible lets the system location sheet sit under
/// the Flutter dialog and eat taps (the dialog is drawn on top, but the
/// system sheet still owns input).
bool canRequestStartupOsPermissions({
  required bool privacyAccepted,
  required bool privacyDialogResolved,
}) {
  return privacyAccepted || privacyDialogResolved;
}
