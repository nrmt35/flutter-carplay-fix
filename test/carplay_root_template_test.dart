import 'package:flutter/services.dart';
import 'package:flutter_carplay/controllers/carplay_controller.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:flutter_test/flutter_test.dart';

const _carplayChannel = MethodChannel('com.oguzhnatly.flutter_carplay');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_carplayChannel, null);
    FlutterCarPlayController.templateHistory.clear();
  });

  CPTabBarTemplate tabBarWith(CPListItem item) => CPTabBarTemplate(
        templates: [
          CPListTemplate(
            id: 'tab-library',
            title: 'Library',
            sections: [
              CPListSection(items: [item])
            ],
          ),
        ],
      );

  test('allows CPSearchTemplate as a root template', () async {
    MethodCall? capturedCall;
    messenger.setMockMethodCallHandler(_carplayChannel, (call) async {
      capturedCall = call;
      return true;
    });

    await FlutterCarplay.setRootTemplate(rootTemplate: CPSearchTemplate());

    expect(capturedCall, isNotNull);
    expect(capturedCall!.method, 'setRootTemplate');
    final args = capturedCall!.arguments as Map<Object?, Object?>;
    final rootTemplate = args['rootTemplate'] as Map<Object?, Object?>;
    expect(rootTemplate['runtimeType'], 'FCPSearchTemplate');
  });

  // A root swap CarPlay reports as failed is still applied natively, so Dart
  // has to keep it too — otherwise it holds the previous template's element
  // ids and every row tap is dropped.
  test('keeps the new root when CarPlay reports the transition failed',
      () async {
    messenger.setMockMethodCallHandler(_carplayChannel, (call) async => false);

    var tapped = false;
    final item = CPListItem(
      text: 'Tracks',
      onPress: (complete, self) {
        tapped = true;
        complete();
      },
    );
    await FlutterCarplay.setRootTemplate(rootTemplate: tabBarWith(item));
    await FlutterCarPlayController().processFCPListItemSelectedChannel(
      item.uniqueId,
    );

    expect(tapped, isTrue, reason: 'tap on a row of the new root was dropped');
  });

  test('keeps the last root sent when replies come back out of order',
      () async {
    var call = 0;
    messenger.setMockMethodCallHandler(_carplayChannel, (_) async {
      // First call replies last, as a slow CarPlay transition would.
      final delay = call++ == 0 ? 60 : 1;
      await Future<void>.delayed(Duration(milliseconds: delay));
      return true;
    });

    final firstItem = CPListItem(text: 'first');
    final lastItem = CPListItem(text: 'last');
    final first = FlutterCarplay.setRootTemplate(
      rootTemplate: tabBarWith(firstItem),
    );
    final last = FlutterCarplay.setRootTemplate(
      rootTemplate: tabBarWith(lastItem),
    );
    await Future.wait([first, last]);

    final root =
        FlutterCarPlayController.templateHistory.single as CPTabBarTemplate;
    final rows = (root.templates.single as CPListTemplate).sections.single.items;
    expect(rows.single.uniqueId, lastItem.uniqueId);
  });

  test('restores the previous root when native rejects the template', () async {
    var accepted = 0;
    messenger.setMockMethodCallHandler(_carplayChannel, (call) async {
      if (accepted++ == 0) return true;
      throw PlatformException(code: 'ERROR', message: 'too many tabs');
    });

    final keptItem = CPListItem(text: 'kept');
    await FlutterCarplay.setRootTemplate(rootTemplate: tabBarWith(keptItem));
    await expectLater(
      FlutterCarplay.setRootTemplate(rootTemplate: tabBarWith(CPListItem())),
      throwsA(isA<PlatformException>()),
    );

    final root =
        FlutterCarPlayController.templateHistory.single as CPTabBarTemplate;
    final rows = (root.templates.single as CPListTemplate).sections.single.items;
    expect(rows.single.uniqueId, keptItem.uniqueId);
  });
}
