import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'google_calendar_client.dart';
import 'google_setup.dart';

/// The connected Google account (if any) on this device. Separate from the
/// app's own sign-in: it only grants access to Google Calendar.
abstract class GoogleConnection extends ChangeNotifier {
  /// The right connection for this platform: Google's sign-in on Android,
  /// a browser sign-in on macOS.
  factory GoogleConnection.forPlatform() {
    if (!kIsWeb && Platform.isAndroid) return AndroidGoogleConnection();
    return DesktopGoogleConnection();
  }

  GoogleConnection.base();

  static const scopes = [gcal.CalendarApi.calendarScope];

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

/// Android: Google's own sign-in (Credential Manager), via the Android
/// implementation of google_sign_in directly, so that no Apple-platform
/// Google SDK is pulled into the macOS build (its dependencies clash with
/// Firebase's).
class AndroidGoogleConnection extends GoogleConnection {
  AndroidGoogleConnection() : super.base();

  GoogleSignInUserData? _user;
  Object? _error;
  bool _initialized = false;
  GoogleCalendarClient? _client;
  DateTime? _clientMadeAt;

  GoogleSignInPlatform get _platform => GoogleSignInPlatform.instance;

  @override
  bool get configured => googleWebClientId.isNotEmpty;
  @override
  String? get email => _user?.email;
  @override
  Object? get error => _error;

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    await _platform.init(
      const InitParameters(serverClientId: googleWebClientId),
    );
  }

  @override
  Future<void> start() async {
    if (!configured) return;
    try {
      await _init();
      final result = await _platform.attemptLightweightAuthentication(
        const AttemptLightweightAuthenticationParameters(),
      );
      _user = result?.user;
    } catch (e) {
      _error = e;
    }
    notifyListeners();
  }

  @override
  Future<void> connect() async {
    _error = null;
    try {
      await _init();
      final result = await _platform.authenticate(
        const AuthenticateParameters(scopeHint: GoogleConnection.scopes),
      );
      _user = result.user;
      // Ask for calendar access now, while the user is here.
      await _token(prompt: true);
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<String?> _token({required bool prompt}) async {
    final user = _user;
    if (user == null) return null;
    final data = await _platform.clientAuthorizationTokensForScopes(
      ClientAuthorizationTokensForScopesParameters(
        request: AuthorizationRequestDetails(
          scopes: GoogleConnection.scopes,
          userId: user.id,
          email: user.email,
          promptIfUnauthorized: prompt,
        ),
      ),
    );
    return data?.accessToken;
  }

  @override
  Future<void> disconnect() async {
    await _platform.disconnect(const DisconnectParams());
    _user = null;
    _client = null;
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client() async {
    // Access tokens last an hour; get a fresh one well before then.
    final madeAt = _clientMadeAt;
    if (_client != null &&
        madeAt != null &&
        DateTime.now().difference(madeAt) < const Duration(minutes: 40)) {
      return _client;
    }
    final token = await _token(prompt: false);
    if (token == null) return null;
    _clientMadeAt = DateTime.now();
    final credentials = gauth.AccessCredentials(
      gauth.AccessToken(
        'Bearer',
        token,
        DateTime.now().toUtc().add(const Duration(minutes: 50)),
      ),
      null,
      GoogleConnection.scopes,
    );
    return _client = GoogleApiCalendarClient(
      gcal.CalendarApi(gauth.authenticatedClient(http.Client(), credentials)),
    );
  }
}

/// macOS: the standard desktop sign-in. Opens Google's sign-in page in the
/// browser, receives the result on a local port, and keeps the refresh token
/// in the app's private container so you stay connected.
class DesktopGoogleConnection extends GoogleConnection {
  DesktopGoogleConnection({Future<File> Function()? credentialsFile})
    : _credentialsFile = credentialsFile ?? _defaultFile,
      super.base();

  final Future<File> Function() _credentialsFile;
  gauth.AutoRefreshingAuthClient? _auth;
  StreamSubscription<gauth.AccessCredentials>? _updates;
  String? _email;
  Object? _error;

  static final _clientId = gauth.ClientId(
    googleDesktopClientId,
    googleDesktopClientSecret,
  );

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/google_account.json',
  );

  @override
  bool get configured =>
      googleDesktopClientId.isNotEmpty && googleDesktopClientSecret.isNotEmpty;
  @override
  String? get email => _email;
  @override
  Object? get error => _error;

  @override
  Future<void> start() async {
    if (!configured) return;
    try {
      final file = await _credentialsFile();
      if (!await file.exists()) return;
      final saved =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _use(
        gauth.autoRefreshingClient(
          _clientId,
          gauth.AccessCredentials.fromJson(
            Map<String, dynamic>.from(saved['credentials'] as Map),
          ),
          http.Client(),
        ),
        saved['email'] as String?,
      );
    } catch (e) {
      _error = e;
    }
    notifyListeners();
  }

  @override
  Future<void> connect() async {
    _error = null;
    try {
      final auth = await gauth.clientViaUserConsent(
        _clientId,
        GoogleConnection.scopes,
        (url) => launchUrl(Uri.parse(url)),
        customPostAuthPage:
            '<html><body style="font-family:-apple-system,sans-serif;'
            'text-align:center;padding-top:80px">'
            '<h2>Connected to Taskflow</h2>'
            '<p>You can close this tab and go back to the app.</p>'
            '</body></html>',
      );
      // The primary calendar's id is the account's address.
      final calendars = await GoogleApiCalendarClient(gcal.CalendarApi(auth))
          .calendars();
      final primary = calendars.where((c) => c.primary).firstOrNull;
      _use(auth, primary?.id ?? 'Google account');
      await _save();
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void _use(gauth.AutoRefreshingAuthClient auth, String? email) {
    _updates?.cancel();
    _auth?.close();
    _auth = auth;
    _email = email;
    // Save refreshed tokens, so a restart doesn't need a new sign-in.
    _updates = auth.credentialUpdates.listen((_) => _save());
  }

  Future<void> _save() async {
    final auth = _auth;
    if (auth == null) return;
    final file = await _credentialsFile();
    await file.writeAsString(
      jsonEncode({'email': _email, 'credentials': auth.credentials.toJson()}),
    );
  }

  @override
  Future<void> disconnect() async {
    await _updates?.cancel();
    _auth?.close();
    _auth = null;
    _email = null;
    try {
      final file = await _credentialsFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client() async {
    final auth = _auth;
    return auth == null
        ? null
        : GoogleApiCalendarClient(gcal.CalendarApi(auth));
  }

  @override
  void dispose() {
    _updates?.cancel();
    _auth?.close();
    super.dispose();
  }
}
