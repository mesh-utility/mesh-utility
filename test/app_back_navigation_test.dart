import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/main.dart';

void main() {
  test('back closes a map popup before leaving the page', () {
    final decision = decideAppBack(
      mapHandled: true,
      backTarget: historyTabIndex,
      index: mapTabIndex,
    );
    expect(decision.action, AppBackAction.handledByPage);
    expect(decision.tab, isNull);
  });

  test('back returns to the tab that opened the map', () {
    final fromHistory = decideAppBack(
      mapHandled: false,
      backTarget: historyTabIndex,
      index: mapTabIndex,
    );
    expect(fromHistory.action, AppBackAction.showTab);
    expect(fromHistory.tab, historyTabIndex);

    final fromNodes = decideAppBack(
      mapHandled: false,
      backTarget: nodesTabIndex,
      index: mapTabIndex,
    );
    expect(fromNodes.action, AppBackAction.showTab);
    expect(fromNodes.tab, nodesTabIndex);

    // Origin wins over "any other tab goes to the map".
    final originWhileElsewhere = decideAppBack(
      mapHandled: false,
      backTarget: historyTabIndex,
      index: 5,
    );
    expect(originWhileElsewhere.tab, historyTabIndex);
  });

  test('back from any other tab opens the map', () {
    for (final index in <int>[1, nodesTabIndex, historyTabIndex, 5, 7]) {
      final decision = decideAppBack(
        mapHandled: false,
        backTarget: null,
        index: index,
      );
      expect(decision.action, AppBackAction.showTab);
      expect(decision.tab, mapTabIndex);
    }
  });

  test('back on the map backgrounds the app and does not pop the route', () {
    final decision = decideAppBack(
      mapHandled: false,
      backTarget: null,
      index: mapTabIndex,
    );
    expect(decision.action, AppBackAction.moveToBackground);
    expect(decision.tab, isNull);
  });

  test('history list stays mounted only while returning to it', () {
    expect(
      keepHistoryListMounted(index: mapTabIndex, backTarget: historyTabIndex),
      isTrue,
    );
    expect(
      keepHistoryListMounted(
        index: historyTabIndex,
        backTarget: historyTabIndex,
      ),
      isFalse,
    );
    expect(
      keepHistoryListMounted(index: historyTabIndex, backTarget: null),
      isFalse,
    );
    expect(
      keepHistoryListMounted(index: mapTabIndex, backTarget: nodesTabIndex),
      isFalse,
    );
    expect(
      keepHistoryListMounted(index: mapTabIndex, backTarget: null),
      isFalse,
    );
  });
}
