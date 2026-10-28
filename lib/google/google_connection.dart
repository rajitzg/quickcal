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

/// The Google accounts connected on this device (any number, e.g. a
/// personal one and a school one). Separate from the app's own sign-in: it
/// only grants access to Google Calendar.
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

  /// The connected accounts' addresses, in the order they were added.
  List<String> get accounts;
  bool get connected => accounts.isNotEmpty;

  /// The last sign-in problem, to show in the UI.
  Object? get error;

  /// Restores previous connections without showing any UI.
  Future<void> start();

  /// Asks the user to sign in to an account and allow calendar access, and
  /// adds it (connecting an account that's already there refreshes it).
  Future<void> connect();

  /// Removes [account] from this device.
  Future<void> disconnect(String account);

  /// An API client for [account] with a fresh token, or null when it isn't
  /// connected (or the user needs to grant access again).
  Future<GoogleCalendarClient?> client(String account);
}

/// Android: Google's own sign-in (Credential Manager), via the Android
/// implementation of google_sign_in directly, so that no Apple-platform
/// Google SDK is pulled into the macOS build (its dependencies clash with
/// Firebase's).
///
/// Google's sign-in remembers one account at a time, so the app keeps its
/// own list of the accounts added, and asks for a token for each by address.
class AndroidGoogleConnection extends GoogleConnection {
  AndroidGoogleConnection({Future<File> Function()? accountsFile})
    : _accountsFile = accountsFile ?? _defaultFile,
      super.base();

  final Future<File> Function() _accountsFile;
  final _users = <GoogleSignInUserData>[];
  Object? _error;
  bool _initialized = false;
  final _clients = <String, (GoogleCalendarClient, DateTime)>{};

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/google_accounts.json',
  );

  GoogleSignInPlatform get _platform => GoogleSignInPlatform.instance;

  @override
  bool get configured => googleWebClientId.isNotEmpty;
  @override
  List<String> get accounts => [for (final u in _users) u.email];
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
      final file = await _accountsFile();
      if (await file.exists()) {
        for (final u in jsonDecode(await file.readAsString()) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          _users.add(
            GoogleSignInUserData(
              id: m['id'] as String,
              email: m['email'] as String,
              displayName: m['displayName'] as String?,
            ),
          );
        }
      } else {
        // Connected before the app kept a list: pick that account up.
        final result = await _platform.attemptLightweightAuthentication(
          const AttemptLightweightAuthenticationParameters(),
        );
        if (result?.user case final user?) {
          _users.add(user);
          await _save();
        }
      }
    } catch (e) {
      _error = e;
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final file = await _accountsFile();
    await file.writeAsString(
      jsonEncode([
        for (final u in _users)
          {'id': u.id, 'email': u.email, 'displayName': u.displayName},
      ]),
    );
  }

  @override
  Future<void> connect() async {
    _error = null;
    try {
      await _init();
      final result = await _platform.authenticate(
        const AuthenticateParameters(scopeHint: GoogleConnection.scopes),
      );
      final user = result.user;
      // Ask for calendar access now, while the user is here.
      await _token(user, prompt: true);
      _users.removeWhere((u) => u.email == user.email);
      _users.add(user);
      _clients.remove(user.email);
      await _save();
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<String?> _token(
    GoogleSignInUserData user, {
    required bool prompt,
  }) async {
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
  Future<void> disconnect(String account) async {
    _users.removeWhere((u) => u.email == account);
    _clients.remove(account);
    try {
      await _save();
      if (_users.isEmpty) await _platform.disconnect(const DisconnectParams());
    } catch (e) {
      _error = e;
    }
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client(String account) async {
    final user = _users.where((u) => u.email == account).firstOrNull;
    if (user == null) return null;
    // Access tokens last an hour; get a fresh one well before then.
    if (_clients[account] case (final client, final madeAt)
        when DateTime.now().difference(madeAt) < const Duration(minutes: 40)) {
      return client;
    }
    final token = await _token(user, prompt: false);
    if (token == null) return null;
    final credentials = gauth.AccessCredentials(
      gauth.AccessToken(
        'Bearer',
        token,
        DateTime.now().toUtc().add(const Duration(minutes: 50)),
      ),
      null,
      GoogleConnection.scopes,
    );
    final client = GoogleApiCalendarClient(
      gcal.CalendarApi(gauth.authenticatedClient(http.Client(), credentials)),
    );
    _clients[account] = (client, DateTime.now());
    return client;
  }
}

/// macOS: the standard desktop sign-in. Opens Google's sign-in page in the
/// browser, receives the result on a local port, and keeps each account's
/// refresh token in the app's private container so you stay connected.
class DesktopGoogleConnection extends GoogleConnection {
  DesktopGoogleConnection({Future<File> Function()? credentialsFile})
    : _credentialsFile = credentialsFile ?? _defaultFile,
      super.base();

  final Future<File> Function() _credentialsFile;

  /// Account address → its signed-in HTTP client.
  final _auth = <String, gauth.AutoRefreshingAuthClient>{};
  final _updates = <String, StreamSubscription<gauth.AccessCredentials>>{};
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
  List<String> get accounts => _auth.keys.toList();
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
      // Older versions saved a single {email, credentials}.
      final list = saved['accounts'] as List<dynamic>? ?? [saved];
      for (final a in list) {
        final m = Map<String, dynamic>.from(a as Map);
        _use(
          m['email'] as String? ?? 'Google account',
          gauth.autoRefreshingClient(
            _clientId,
            gauth.AccessCredentials.fromJson(
              Map<String, dynamic>.from(m['credentials'] as Map),
            ),
            http.Client(),
          ),
        );
      }
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
      _use(primary?.id ?? 'Google account ${_auth.length + 1}', auth);
      await _save();
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void _use(String email, gauth.AutoRefreshingAuthClient auth) {
    _drop(email);
    _auth[email] = auth;
    // Save refreshed tokens, so a restart doesn't need a new sign-in.
    _updates[email] = auth.credentialUpdates.listen((_) => _save());
  }

  void _drop(String email) {
    _updates.remove(email)?.cancel();
    _auth.remove(email)?.close();
  }

  Future<void> _save() async {
    final file = await _credentialsFile();
    if (_auth.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(
      jsonEncode({
        'accounts': [
          for (final MapEntry(key: email, value: auth) in _auth.entries)
            {'email': email, 'credentials': auth.credentials.toJson()},
        ],
      }),
    );
  }

  @override
  Future<void> disconnect(String account) async {
    _drop(account);
    try {
      await _save();
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client(String account) async {
    final auth = _auth[account];
    return auth == null
        ? null
        : GoogleApiCalendarClient(gcal.CalendarApi(auth));
  }

  @override
  void dispose() {
    for (final email in _auth.keys.toList()) {
      _drop(email);
    }
    super.dispose();
  }
}
