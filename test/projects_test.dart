import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_controller.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/logic/task_views.dart';
import 'package:taskflow/models/project_calendar.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';
import 'package:taskflow/screens/home_screen.dart';

Task task(String id, {String project = ''}) =>
    Task(id: id, title: id, project: project, createdAt: DateTime(2026));

void main() {
  group('store', () {
    test('a project used by a task is kept after the task is gone', () async {
      final store = MemoryPlannerStore();
      final t = task('essay', project: 'English');
      await store.saveTask(t);
      expect(store.savedProjects.map((p) => p.name), ['English']);
      await store.setDone(store.taskById('essay')!, true);
      await store.deleteTask(store.taskById('essay')!);
      expect(store.allProjects.map((p) => p.name), ['English']);
    });

    test('remembering keeps existing settings', () async {
      final store = MemoryPlannerStore(
        projects: const [ProjectCalendar(name: 'English', color: 7)],
      );
      await store.saveTask(task('essay', project: 'English'));
      expect(store.project('English').color, 7);
      expect(store.savedProjects, hasLength(1));
    });

    test('deleting a project moves its tasks and sessions to Inbox', () async {
      final store = MemoryPlannerStore(
        tasks: [
          task('essay', project: 'English'),
          task('other'),
        ],
        sessions: [
          WorkSession(
            id: 's',
            taskId: 'essay',
            title: 'essay',
            project: 'English',
            start: DateTime(2026, 10, 28, 9),
            end: DateTime(2026, 10, 28, 10),
          ),
        ],
        projects: const [ProjectCalendar(name: 'English', color: 7)],
      );
      await store.deleteProject('English');
      expect(store.taskById('essay')!.project, '');
      expect(store.sessions.single.project, '');
      expect(store.allProjects.map((p) => p.name), ['']);
    });

    test('projectSections lists empty projects too', () {
      final sections = projectSections(
        [task('a', project: 'School')],
        projects: ['Thesis', 'School'],
      );
      expect(sections.map((s) => (s.title, s.tasks.length)), [
        ('School', 1),
        ('Thesis', 0),
      ]);
      expect(sections.last.project, 'Thesis');
    });
  });

  testWidgets('projects can be added, kept empty, and deleted', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryPlannerStore(
      tasks: [task('essay', project: 'English')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen.demo(
          store: store,
          calendar: CalendarController('test')..showDemo(const {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New project'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Thesis');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Thesis'), findsOneWidget);
    expect(find.text('No open tasks'), findsOneWidget);

    // Completing English's only task keeps the project.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(find.text('No open tasks'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Edit project').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Thesis"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Thesis'), findsNothing);
    expect(store.allProjects.map((p) => p.name), ['English']);
  });
}
