import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app icon source keeps the mark inside safe margins', () async {
    final bytes = await File(
      'assets/branding/captioncraft_app_icon.png',
    ).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(rgba, isNotNull);

    final bounds = _visibleBounds(
      rgba!.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      image.width,
      image.height,
    );
    expect(image.width, 1024);
    expect(image.height, 1024);
    expect(bounds.left / image.width, greaterThanOrEqualTo(0.16));
    expect(bounds.right / image.width, greaterThanOrEqualTo(0.16));
    expect(bounds.top / image.height, greaterThanOrEqualTo(0.25));
    expect(bounds.bottom / image.height, greaterThanOrEqualTo(0.25));

    image.dispose();
    codec.dispose();
  });

  test('platform icon and launch PNG dimensions remain complete', () async {
    const expected = <String, int>{
      'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
      'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
      'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
      'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
      'android/app/src/main/res/mipmap-mdpi/ic_launcher_round.png': 48,
      'android/app/src/main/res/mipmap-hdpi/ic_launcher_round.png': 72,
      'android/app/src/main/res/mipmap-xhdpi/ic_launcher_round.png': 96,
      'android/app/src/main/res/mipmap-xxhdpi/ic_launcher_round.png': 144,
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png': 192,
      'android/app/src/main/res/drawable-nodpi/launch_image.png': 128,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png':
          1024,
      'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png': 96,
      'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png': 192,
      'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png': 288,
    };

    for (final entry in expected.entries) {
      final dimensions = await _pngDimensions(File(entry.key));
      expect(dimensions, (
        width: entry.value,
        height: entry.value,
      ), reason: entry.key);
    }
  });

  test(
    'vector sources retain optical padding for raster and adaptive icons',
    () async {
      final logo = await File('captioncraft_logo.svg').readAsString();
      final androidForeground = await File(
        'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
      ).readAsString();

      expect(logo, contains('id="app-icon-mark"'));
      expect(logo, contains('translate(125.4 125.4) scale(0.8)'));
      expect(androidForeground, contains('android:scaleX="0.66"'));
      expect(androidForeground, contains('android:scaleY="0.66"'));
    },
  );
}

({int width, int height, int left, int top, int right, int bottom})
_visibleBounds(Uint8List rgba, int width, int height) {
  final background = rgba.sublist(0, 3);
  var minX = width;
  var minY = height;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      final difference = <int>[
        (rgba[offset] - background[0]).abs(),
        (rgba[offset + 1] - background[1]).abs(),
        (rgba[offset + 2] - background[2]).abs(),
      ].reduce((first, second) => first > second ? first : second);
      if (difference <= 20) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0 || maxY < 0) {
    throw StateError('The app icon does not contain a visible mark.');
  }
  return (
    width: maxX - minX + 1,
    height: maxY - minY + 1,
    left: minX,
    top: minY,
    right: width - maxX - 1,
    bottom: height - maxY - 1,
  );
}

Future<({int width, int height})> _pngDimensions(File file) async {
  final bytes = await file.readAsBytes();
  expect(bytes.length, greaterThanOrEqualTo(24), reason: file.path);
  expect(bytes.sublist(0, 8), <int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
  ], reason: file.path);
  final data = ByteData.sublistView(bytes);
  return (
    width: data.getUint32(16, Endian.big),
    height: data.getUint32(20, Endian.big),
  );
}
