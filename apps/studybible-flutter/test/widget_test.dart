import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/main.dart';

void main() {
  testWidgets('app boots', (tester) async {
    await tester.pumpWidget(const StudyBibleApp());
    // В узком окне (тест — 800×600) заголовок не рисуется: показана
    // нижняя навигация; вкладка «Библия» видна всегда.
    expect(find.text('Библия'), findsWidgets);
    expect(find.byType(HomeShell), findsOneWidget);
  });
}
