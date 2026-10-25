# Taskflow

A minimal, fast task list for macOS and Android, synced through Firebase Firestore.

- **Today**: overdue tasks and tasks due today
- **Upcoming**: the next 7 days by day, then Later and No date
- **Projects**: open tasks grouped by project (no project = Inbox)
- **Done**: the 50 most recently completed tasks, which you can reopen
- Works offline. Firestore caches everything locally, so edits are instant and sync when you're back online.
- ⌘N / Ctrl+N creates a new task.

## One-time setup

You'll need [Flutter](https://docs.flutter.dev/get-started/install/macos), Xcode (for the Mac app), and Android Studio or the Android SDK (for the phone app).

### 1. Create the Firebase project
1. Go to <https://console.firebase.google.com>, then **Add project**. Google Analytics isn't needed.
2. Open **Build → Authentication → Get started**, and enable **Email/Password**.
3. Open **Build → Firestore Database → Create database**. Choose **production mode** and a region near you.
4. In the **Rules** tab of Firestore, paste the contents of `firestore.rules` and click **Publish**.

### 2. Connect the app to it
```sh
dart pub global activate flutterfire_cli
npm install -g firebase-tools   # or: curl -sL https://firebase.tools | bash
firebase login
cd taskflow
flutterfire configure --platforms=android,macos
```
This replaces the placeholder `lib/firebase_options.dart` with your project's settings and adds `android/app/google-services.json`.

### 3. macOS signing (required for sign-in to work)
Firebase Auth stores your login in the macOS keychain, which requires a signed app:
1. `open macos/Runner.xcworkspace`
2. Select **Runner → Signing & Capabilities**, then pick your Apple ID under **Team**. A free personal team works.

The keychain and network entitlements are already set in `macos/Runner/*.entitlements`.

### 4. Run it
```sh
flutter run -d macos            # Mac
flutter run -d <android-device> # phone connected over USB with USB debugging on
```
Create an account on one device, then sign in with the same email on the other.

### Installing for everyday use
- **Mac:** `flutter build macos --release`, then copy `build/macos/Build/Products/Release/taskflow.app` to `/Applications`.
- **Android:** `flutter build apk --release`, then install `build/app/outputs/flutter-apk/app-release.apk` on the phone. Or run `flutter install` with the phone connected.

## Data model
Each task is a document at `users/{uid}/tasks/{taskId}` with these fields: `title`, `notes`, `project`, `due` (timestamp), `hasTime`, `done`, `completedAt` (present only while done), `createdAt`, `updatedAt`.

Both queries (`done == false`, and `orderBy completedAt`) use Firestore's automatic single-field indexes, so there are no indexes to create. A few hundred tasks stay far inside the free tier's 50k reads per day.

## Code layout
```
lib/
  main.dart                  Firebase init + sign-in gate
  models/task.dart           Task model and Firestore (de)serialization
  data/task_repository.dart  Firestore queries and writes
  logic/task_views.dart      Pure grouping/sorting for each tab (unit-tested)
  screens/                   Sign-in and home (nav rail on Mac, bottom bar on phone)
  widgets/                   Task row and the add/edit sheet
test/task_views_test.dart
```

## Next ideas
- Show class and calendar events in Today/Upcoming. Read them from the device's calendars, or from a Google/iCloud calendar's private iCal link.
- Due-time notifications (`flutter_local_notifications`)
- Recurring tasks
