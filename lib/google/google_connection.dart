import 'dart:async';
import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'google_calendar_client.dart';
import 'google_setup.dart';

/// The connected Google account (if any) on this device. Separate from the
/// app's own sign-in: it only grants access to Google Calendar.
abstract class GoogleConnection extends ChangeNotifier {
  /// Google sign-in is set up for this platform (client IDs filled in).
  bool get configured;

  /// The connected account's address, or null.
  String? get email;
  bool get connected => email != null;

  /// The last sign-in problem, to show in the UI.
  Object? get error;

  /// Restores a previous connection without showing any UI.
  Future<void> start();

  /// Asks the user to sign in and allow calendar access.
  Future<void> connect();
  Future<void> disconnect();

  /// An API client with a fresh token, or null when not connected (or the
  /// user needs to grant access again).
  Future<GoogleCalendarClient?> client();
}

/// [GoogleConnection] using the google_sign_in plugin (Android, macOS).
class SignInGoogleConnection extends GoogleConnection {
  static const _scopes = [gcal.CalendarApi.calendarScope];

  GoogleSignInAccount? _account;
  Object? _error;
  bool _initialized = false;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  GoogleCalendarClient? _client;
  DateTime? _clientMadeAt;

  @override
  bool get configured {
    if (kIsWeb) return false;
    if (Platform.isAndroid) return googleWebClientId.isNotEmpty;
    if (Platform.isMacOS) return googleAppleClientId.isNotEmpty;
    return false;
  }

  @override
  String? get email => _account?.email;
  @override
  Object? get error => _error;

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    await GoogleSignIn.instance.initialize(
      clientId: Platform.isMacOS ? googleAppleClientId : null,
      serverClientId: Platform.isAndroid ? googleWebClientId : null,
    );
    _events = GoogleSignIn.instance.authenticationEvents.listen(
      (event) {
        _account = switch (event) {
          GoogleSignInAuthenticationEventSignIn(:final user) => user,
          GoogleSignInAuthenticationEventSignOut() => null,
        };
        _client = null;
        notifyListeners();
      },
      onError: (Object e) {
        _error = e;
        notifyListeners();
      },
    );
  }

  @override
  Future<void> start() async {
    if (!configured) return;
    try {
      await _init();
      await GoogleSignIn.instance.attemptLightweightAuthentication();
    } catch (e) {
      _error = e;
      notifyListeners();
    }
  }

  @override
  Future<void> connect() async {
    _error = null;
    try {
      await _init();
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: _scopes,
      );
      await account.authorizationClient.authorizeScopes(_scopes);
      _account = account;
      _client = null;
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  @override
  Future<void> disconnect() async {
    await GoogleSignIn.instance.disconnect();
    _account = null;
    _client = null;
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client() async {
    final account = _account;
    if (account == null) return null;
    // Access tokens last an hour; get a fresh one well before then.
    final madeAt = _clientMadeAt;
    if (_client != null &&
        madeAt != null &&
        DateTime.now().difference(madeAt) < const Duration(minutes: 40)) {
      return _client;
    }
    final auth = await account.authorizationClient.authorizationForScopes(
      _scopes,
    );
    if (auth == null) return null;
    _clientMadeAt = DateTime.now();
    return _client = GoogleApiCalendarClient(
      gcal.CalendarApi(auth.authClient(scopes: _scopes)),
    );
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}
