import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Respect app test environment smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(child: Text('Respect App')),
          ),
        ),
      ),
    );

    expect(find.text('Respect App'), findsOneWidget);
  });
}
