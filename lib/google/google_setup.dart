// OAuth client IDs for "Connect Google Calendar". Fill these in once (see
// "Google Calendar setup" in README.md). They only identify the app to
// Google; for desktop apps Google doesn't treat the "secret" as secret.

/// Android: the *Web application* OAuth client of the same Google Cloud
/// project (Google calls it the server client id). Android also needs your
/// app's SHA-1 fingerprint registered (see README).
const googleWebClientId = '';

/// macOS: a *Desktop app* OAuth client, used for signing in through the
/// browser.
const googleDesktopClientId = '';
const googleDesktopClientSecret = '';
