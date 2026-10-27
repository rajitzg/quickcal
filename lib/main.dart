import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'home_widget/background.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const TaskflowApp());
  // Keeps the Android home screen widget fresh while the app is closed.
  scheduleWidgetRefresh().catchError(
    (Object e) => debugPrint('Could not schedule widget refresh: $e'),
  );
}

class TaskflowApp extends StatelessWidget {
  const TaskflowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taskflow',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final user = snap.data;
          return user == null
              ? const SignInScreen()
              : HomeScreen(key: ValueKey(user.uid), uid: user.uid);
        },
      ),
    );
  }
}
