import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/services/timeline_snapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimelineSnapSettings', () {
    test(
      'round-trips independent targets and preserves an explicit empty set',
      () {
        const settings = TimelineSnapSettings(
          enabled: false,
          targets: {
            TimelineSnapTarget.frames,
            TimelineSnapTarget.beats,
            TimelineSnapTarget.workAreaBoundaries,
          },
        );

        final restored = TimelineSnapSettings.fromJson(settings.toJson());
        final empty = TimelineSnapSettings.fromJson({
          'enabled': true,
          'targets': <String>[],
        });

        expect(restored.enabled, isFalse);
        expect(restored.targets, settings.targets);
        expect(empty.targets, isEmpty);
      },
    );

    test('old workspace JSON receives safe professional defaults', () {
      final restored = TimelineWorkspaceSettings.fromJson({'frameRate': 24});

      expect(restored.frameRate, 24);
      expect(restored.snapping.enabled, isTrue);
      expect(restored.snapping.targets, kDefaultTimelineSnapTargets);
    });
  });

  group('TimelineSnapIndex', () {
    test('indexes edges, marker classes, and absolute keyframe times once', () {
      final clip = TimelineClip(
        id: 'animated',
        trackId: 'video',
        type: TimelineTrackType.video,
        label: 'Animated',
        startTime: const Duration(seconds: 3),
        endTime: const Duration(seconds: 5),
        keyframes: [
          TimelineKeyframe(
            time: const Duration(milliseconds: 500),
            property: TimelineKeyframeProperty.opacity,
            value: 0.5,
          ),
        ],
      );
      final timeline = EditorTimeline(
        tracks: [
          TimelineTrack(
            id: 'video',
            name: 'Video',
            type: TimelineTrackType.video,
            section: TimelineTrackSection.baseVideo,
            clips: [clip],
          ),
        ],
        markers: [
          TimelineMarker(position: const Duration(seconds: 1), label: 'Marker'),
          TimelineMarker(
            position: const Duration(seconds: 2),
            label: 'Beat',
            type: TimelineMarkerType.beat,
          ),
        ],
      );

      final index = TimelineSnapIndex.fromTimeline(timeline);

      expect(index.clipEdgesUs, [0, 3000000, 5000000]);
      expect(index.markersUs, [1000000]);
      expect(index.beatsUs, [2000000]);
      expect(index.keyframesUs, [3500000]);
      expect(index.keyframesByClipId['animated'], [3500000]);
    });
  });

  group('TimelineSnapEngine', () {
    const threshold = Duration(milliseconds: 20);

    test('only enabled targets participate', () {
      const index = TimelineSnapIndex(
        clipEdgesUs: [1000000],
        markersUs: [1010000],
      );
      const clipOnly = TimelineSnapSettings(
        targets: {TimelineSnapTarget.clipEdges},
      );
      const markerOnly = TimelineSnapSettings(
        targets: {TimelineSnapTarget.markers},
      );

      expect(
        TimelineSnapEngine.snapPoint(
          proposed: const Duration(milliseconds: 1007),
          settings: clipOnly,
          index: index,
          frameRate: 30,
          threshold: threshold,
        ),
        const Duration(seconds: 1),
      );
      expect(
        TimelineSnapEngine.snapPoint(
          proposed: const Duration(milliseconds: 1007),
          settings: markerOnly,
          index: index,
          frameRate: 30,
          threshold: threshold,
        ),
        const Duration(milliseconds: 1010),
      );
    });

    test('range snapping considers both the start and end edge', () {
      const index = TimelineSnapIndex(clipEdgesUs: [5000000]);
      final result = TimelineSnapEngine.snapRangeStart(
        proposedStart: const Duration(milliseconds: 3988),
        duration: const Duration(seconds: 1),
        settings: const TimelineSnapSettings(
          targets: {TimelineSnapTarget.clipEdges},
        ),
        index: index,
        frameRate: 30,
        threshold: threshold,
      );

      expect(result, const Duration(seconds: 4));
    });

    test('selection and work-area targets are independently configurable', () {
      const proposed = Duration(milliseconds: 1992);
      const index = TimelineSnapIndex();
      final selection = TimelineSnapEngine.snapPoint(
        proposed: proposed,
        settings: const TimelineSnapSettings(
          targets: {TimelineSnapTarget.selectionBoundaries},
        ),
        index: index,
        frameRate: 30,
        threshold: threshold,
        selectionBoundaries: const [Duration(seconds: 2)],
        workAreaStart: const Duration(milliseconds: 1988),
      );
      final workArea = TimelineSnapEngine.snapPoint(
        proposed: proposed,
        settings: const TimelineSnapSettings(
          targets: {TimelineSnapTarget.workAreaBoundaries},
        ),
        index: index,
        frameRate: 30,
        threshold: threshold,
        selectionBoundaries: const [Duration(seconds: 2)],
        workAreaStart: const Duration(milliseconds: 1988),
      );

      expect(selection, const Duration(seconds: 2));
      expect(workArea, const Duration(milliseconds: 1988));
    });

    test(
      'frame navigation uses absolute rational boundaries without drift',
      () {
        var position = Duration.zero;
        for (var index = 0; index < 10; index++) {
          position = TimelineSnapEngine.adjacentFrame(
            position,
            frameRate: 30,
            direction: 1,
          );
        }
        expect(position.inMicroseconds, 333333);

        for (var index = 0; index < 10; index++) {
          position = TimelineSnapEngine.adjacentFrame(
            position,
            frameRate: 30,
            direction: -1,
          );
        }
        expect(position, Duration.zero);
      },
    );

    test('moving clip does not snap to its own indexed keys or edges', () {
      const index = TimelineSnapIndex(
        clipEdgesUs: [1000000, 2000000, 3000000],
        keyframesUs: [1500000, 2500000],
        keyframesByClipId: {
          'moving': [1500000, 2500000],
        },
      );
      final result = TimelineSnapEngine.snapPoint(
        proposed: const Duration(milliseconds: 1501),
        settings: const TimelineSnapSettings(
          targets: {TimelineSnapTarget.clipEdges, TimelineSnapTarget.keyframes},
        ),
        index: index,
        frameRate: 30,
        threshold: const Duration(milliseconds: 10),
        excludedClipId: 'moving',
        excludedClipBoundaries: const [
          Duration(seconds: 1),
          Duration(seconds: 2),
        ],
      );

      expect(result, const Duration(milliseconds: 1501));
    });
  });
}
