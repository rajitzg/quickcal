// OAuth client IDs for "Connect Google Calendar". Fill these in once (see
// "Google Calendar setup" in README.md). Client IDs aren't secrets: they
// only identify the app to Google.

/// macOS: the iOS-type OAuth client ("…apps.googleusercontent.com"). Also
/// put its reversed form in macos/Runner/Info.plist (see README).
const googleAppleClientId = '';

/// Android: the *Web*-type OAuth client of the same Google Cloud project
/// (Google calls it the server client id). Android also needs your app's
/// SHA-1 fingerprint registered (see README).
const googleWebClientId = '';
