import 'package:caption_craft/core/utils/youtube_download_service.dart';
import 'package:caption_craft/features/editor/models/clip_motion_presets.dart';
import 'package:caption_craft/features/editor/models/subtitle_entry.dart';
import 'package:caption_craft/features/editor/models/subtitle_style_model.dart';
import 'package:caption_craft/features/editor/models/timeline_models.dart';
import 'package:caption_craft/features/editor/providers/subtitle_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'caption track style edits preserve other tracks and undo in one step',
    () {
      final notifier = SubtitleNotifier();
      addTearDown(notifier.dispose);
      final entries = [
        for (final id in ['a', 'b', 'other'])
          SubtitleEntry(
            id: id,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
            text: id,
          ),
      ];
      notifier.loadSubtitles(entries);
      final global = notifier.state.globalStyle;
      const style = SubtitleStyleModel(fontSize: 42, isBold: true);
      notifier.updateEntriesStyle({'a', 'b'}, style);
      expect(
        notifier.state.entries.take(2).every((e) => e.styleOverride == style),
        isTrue,
      );
      expect(notifier.state.entries.last.styleOverride, isNull);
      expect(notifier.state.globalStyle, same(global));
      notifier.undo();
      expect(
        notifier.state.entries.every((e) => e.styleOverride == null),
        isTrue,
      );
      notifier.redo();
      expect(notifier.state.entries.first.styleOverride, style);
    },
  );

  test(
    'motion recipes preserve unrelated channels and survive serialization',
    () {
      final opacity = TimelineKeyframe(
        time: Duration.zero,
        property: TimelineKeyframeProperty.opacity,
        value: 0.6,
      );
      final clip = TimelineClip(
        trackId: 'visual',
        type: TimelineTrackType.image,
        label: 'Image',
        startTime: const Duration(seconds: 3),
        endTime: const Duration(seconds: 5),
        keyframes: [opacity],
      );
      for (final preset in ClipMotionPreset.values) {
        final animated = preset.apply(clip);
        expect(
          animated.keyframes
              .where((k) => k.property == TimelineKeyframeProperty.opacity)
              .single,
          same(opacity),
        );
        final restored = TimelineClip.fromJson(animated.toJson());
        for (final milliseconds in [0, 250, 500, 1000, 1750, 2000]) {
          final transform = restored.transformAt(
            Duration(milliseconds: milliseconds),
          );
          expect(transform.scale.isFinite, isTrue);
          expect(
            transform.offsetX.isFinite && transform.offsetY.isFinite,
            isTrue,
          );
          expect(transform.scale, inInclusiveRange(0.2, 4));
        }
        expect(
          animated.keyframes
              .map((k) => '${k.property}:${k.time}')
              .toSet()
              .length,
          animated.keyframes.length,
        );
      }
    },
  );

  test(
    'YouTube fallback pairs compatible audio and preserves exact format tags',
    () {
      final info = YoutubeDownloadService.videoInfoFromExtractor(
        'jNQXAC9IVRw',
        {
          'title': 'Sample',
          'duration': 19.1,
          'formats': [
            {
              'format_id': '137',
              'ext': 'mp4',
              'height': 1080,
              'vcodec': 'avc1',
              'acodec': 'none',
              'filesize': 1000,
            },
            {
              'format_id': '140',
              'ext': 'm4a',
              'vcodec': 'none',
              'acodec': 'aac',
              'abr': 128,
              'filesize': 100,
            },
            {
              'format_id': '251',
              'ext': 'webm',
              'vcodec': 'none',
              'acodec': 'opus',
              'abr': 160,
            },
            {
              'format_id': 'storyboard',
              'ext': 'mhtml',
              'vcodec': 'none',
              'acodec': 'none',
            },
          ],
        },
      );
      final video = info.formats.first;
      expect(video.videoFormatTag, 137);
      expect(video.audioFormatTag, 140);
      expect(video.estimatedBytes, 1100);
      expect(info.formats, hasLength(3));
      expect(info.duration, const Duration(milliseconds: 19100));
      expect(
        () => YoutubeDownloadService.videoInfoFromExtractor('jNQXAC9IVRw', {
          'formats': [],
        }),
        throwsStateError,
      );
    },
  );
}
