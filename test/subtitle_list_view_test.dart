import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/subtitle_list_view.dart';

// Long enough to wrap to two lines so each item is taller than the 48px
// bottom threshold.
const String kLine =
    '오늘 회의에서 논의된 안건은 다음 분기 예산 배분과 신규 채용 계획에 관한 것이며 모든 팀장이 참석해야 합니다';

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  // One List instance mutated in place, exactly like the tabs do.
  List<String> _texts = <String>[];

  void add() => setState(() => _texts.add(kLine));

  void clear() => setState(() => _texts = <String>[]);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          width: double.infinity,
          child: SubtitleListView(
            texts: _texts,
            speakingIndex: null,
            onTapItem: (_) {},
          ),
        ),
      ),
    );
  }
}

void main() {
  final hostKey = GlobalKey<_HostState>();

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(_Host(key: hostKey));
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  Future<void> fillAndSettle(WidgetTester tester, int n) async {
    for (var i = 0; i < n; i++) {
      hostKey.currentState!.add();
      await tester.pumpAndSettle();
    }
  }

  Future<void> dragUp(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    // Precondition: the drag left the viewport clearly above the bottom.
    expect(position(tester).extentAfter, greaterThan(48));
  }

  testWidgets('(a) follows the bottom during and after a subtitle stream', (
    tester,
  ) async {
    await mount(tester);

    for (var i = 0; i < 20; i++) {
      hostKey.currentState!.add();
      for (var f = 0; f < 6; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    await tester.pumpAndSettle();
    // Precondition: one item must exceed the 48px bottom threshold.
    expect(tester.getSize(find.byType(ListTile).last).height, greaterThan(48));
    expect(position(tester).extentAfter, moreOrLessEquals(0, epsilon: 1.0));

    await fillAndSettle(tester, 3);
    expect(position(tester).extentAfter, moreOrLessEquals(0, epsilon: 1.0));
  });

  testWidgets('(a2) a subtitle arriving mid-animation is included in target', (
    tester,
  ) async {
    await mount(tester);

    for (var i = 0; i < 20; i++) {
      hostKey.currentState!.add();
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    hostKey.currentState!.add();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(position(tester).extentAfter, moreOrLessEquals(0, epsilon: 1.0));
  });

  testWidgets('(b) dragging up turns auto-scroll off', (tester) async {
    await mount(tester);
    await fillAndSettle(tester, 20);
    await dragUp(tester);

    final before = position(tester).pixels;
    hostKey.currentState!.add();
    await tester.pumpAndSettle();

    expect(position(tester).pixels, before);
  });

  testWidgets('(c) flinging back to the bottom turns auto-scroll on again', (
    tester,
  ) async {
    await mount(tester);
    await fillAndSettle(tester, 20);
    await dragUp(tester);

    await tester.fling(find.byType(ListView), const Offset(0, -600), 2000);
    await tester.pumpAndSettle();

    hostKey.currentState!.add();
    await tester.pumpAndSettle();

    expect(position(tester).extentAfter, moreOrLessEquals(0, epsilon: 1.0));
  });

  testWidgets('(d) clearing the list restores auto-scroll', (tester) async {
    await mount(tester);
    await fillAndSettle(tester, 20);
    await dragUp(tester);

    hostKey.currentState!.clear();
    await tester.pumpAndSettle();

    // 3 items (the design's count) fit inside the 400px box and never scroll,
    // which would pass even without latch recovery. 10 items overflow it.
    await fillAndSettle(tester, 10);
    expect(position(tester).maxScrollExtent, greaterThan(0));
    expect(position(tester).extentAfter, moreOrLessEquals(0, epsilon: 1.0));
  });
}
