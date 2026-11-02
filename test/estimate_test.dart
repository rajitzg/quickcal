import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/widgets/task_editor.dart';

void main() {
  // Entering a custom estimate used to crash (the text box's controller was
  // disposed while the dialog was still closing).
  for (final (input, minutes) in [('4', 240), ('1.5', 90), ('0.1', 15)]) {
    testWidgets('a custom estimate of $input hours', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      EditorResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showTaskEditor(
                context,
                task: Task(id: 'x', title: 'Essay', createdAt: DateTime(2026)),
                isNew: false,
                projects: const [],
                sessions: const [],
                newSessionId: () => 's',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, input);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((result! as SaveTask).task.estimate, Duration(minutes: minutes));
    });
  }
}
