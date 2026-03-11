import 'package:flutter_test/flutter_test.dart';

import 'package:reflector/main.dart';

void main() {
  testWidgets('App renders title', (WidgetTester tester) async {
    await tester.pumpWidget(const ReflectorApp());
    expect(find.text('Reflector'), findsOneWidget);
  });
}
