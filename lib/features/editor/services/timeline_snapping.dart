import 'dart:math' as math;

import '../models/timeline_models.dart';

/// Immutable, sorted targets used by timeline gestures.
///
/// Building this once per timeline revision prevents every pointer update from
/// scanning every clip and keyframe in a heavy project.
final class TimelineSnapIndex {
  final List<int> clipEdgesUs;
  final List<int> markersUs;
  final List<int> beatsUs;
  final List<int> keyframesUs;
  final Map<String, List<int>> keyframesByClipId;

  const TimelineSnapIndex({
    this.clipEdgesUs = const [],
    this.markersUs = const [],
    this.beatsUs = const [],
    this.keyframesUs = const [],
    this.keyframesByClipId = const {},
  });

  factory TimelineSnapIndex.fromTimeline(EditorTimeline timeline) {
    final clipEdges = <int>{0};
    final keyframes = <int>{};
    final keyframesByClipId = <String, List<int>>{};
    for (final track in timeline.tracks) {
      for (final clip in track.clips) {
        clipEdges
          ..add(clip.startTime.inMicroseconds)
          ..add(clip.endTime.inMicroseconds);
        for (final frame in clip.keyframes) {
          final positionUs =
              clip.startTime.inMicroseconds + frame.time.inMicroseconds;
          keyframes.add(positionUs);
          (keyframesByClipId[clip.id] ??= <int>[]).add(positionUs);
        }
      }
    }
    final markers = <int>{};
    final beats = <int>{};
    for (final marker in timeline.markers) {
      if (marker.type == TimelineMarkerType.beat) {
        beats.add(marker.position.inMicroseconds);
      } else {
        markers.add(marker.position.inMicroseconds);
      }
    }
    return TimelineSnapIndex(
      clipEdgesUs: _sorted(clipEdges),
      markersUs: _sorted(markers),
      beatsUs: _sorted(beats),
      keyframesUs: _sorted(keyframes),
      keyframesByClipId: Map.unmodifiable({
        for (final entry in keyframesByClipId.entries)
          entry.key: List.unmodifiable(entry.value..sort()),
      }),
    );
  }

  static List<int> _sorted(Set<int> values) {
    return List.unmodifiable(values.toList()..sort());
  }
}

final class TimelineSnapEngine {
  const TimelineSnapEngine._();

  /// Snaps one edge to the nearest enabled target within [threshold].
  static Duration snapPoint({
    required Duration proposed,
    required TimelineSnapSettings settings,
    required TimelineSnapIndex index,
    required int frameRate,
    required Duration threshold,
    Duration? playhead,
    Iterable<Duration> selectionBoundaries = const [],
    Iterable<Duration> excludedClipBoundaries = const [],
    String? excludedClipId,
    Duration? workAreaStart,
    Duration? workAreaEnd,
  }) {
    if (!settings.enabled) return proposed;
    final proposedUs = proposed.inMicroseconds;
    final thresholdUs = math.max(0, threshold.inMicroseconds);
    var bestUs = proposedUs;
    var bestDistance = thresholdUs + 1;

    void consider(int candidateUs) {
      final distance = (candidateUs - proposedUs).abs();
      if (distance < bestDistance ||
          (distance == bestDistance && candidateUs < bestUs)) {
        bestUs = candidateUs;
        bestDistance = distance;
      }
    }

    void considerSorted(List<int> candidates) {
      if (candidates.isEmpty) return;
      final insertion = _lowerBound(candidates, proposedUs);
      if (insertion < candidates.length) consider(candidates[insertion]);
      if (insertion > 0) consider(candidates[insertion - 1]);
    }

    if (settings.includes(TimelineSnapTarget.frames)) {
      consider(frameBoundaryUs(proposedUs, frameRate));
    }
    if (settings.includes(TimelineSnapTarget.playhead) && playhead != null) {
      consider(playhead.inMicroseconds);
    }
    if (settings.includes(TimelineSnapTarget.clipEdges)) {
      final blocked = excludedClipBoundaries
          .map((boundary) => boundary.inMicroseconds)
          .toSet();
      if (blocked.isEmpty) {
        considerSorted(index.clipEdgesUs);
      } else {
        _considerNearestUnblocked(
          index.clipEdgesUs,
          proposedUs,
          blocked,
          consider,
        );
      }
    }
    if (settings.includes(TimelineSnapTarget.markers)) {
      considerSorted(index.markersUs);
    }
    if (settings.includes(TimelineSnapTarget.beats)) {
      considerSorted(index.beatsUs);
    }
    if (settings.includes(TimelineSnapTarget.keyframes)) {
      final blocked = excludedClipId == null
          ? const <int>{}
          : index.keyframesByClipId[excludedClipId]?.toSet() ?? const <int>{};
      if (blocked.isEmpty) {
        considerSorted(index.keyframesUs);
      } else {
        _considerNearestUnblocked(
          index.keyframesUs,
          proposedUs,
          blocked,
          consider,
        );
      }
    }
    if (settings.includes(TimelineSnapTarget.selectionBoundaries)) {
      for (final boundary in selectionBoundaries) {
        consider(boundary.inMicroseconds);
      }
    }
    if (settings.includes(TimelineSnapTarget.workAreaBoundaries)) {
      if (workAreaStart != null) consider(workAreaStart.inMicroseconds);
      if (workAreaEnd != null) consider(workAreaEnd.inMicroseconds);
    }
    return bestDistance <= thresholdUs
        ? Duration(microseconds: bestUs)
        : proposed;
  }

  /// Snaps either edge of a moving range and returns the adjusted start.
  static Duration snapRangeStart({
    required Duration proposedStart,
    required Duration duration,
    required TimelineSnapSettings settings,
    required TimelineSnapIndex index,
    required int frameRate,
    required Duration threshold,
    Duration? playhead,
    Iterable<Duration> selectionBoundaries = const [],
    Iterable<Duration> excludedClipBoundaries = const [],
    String? excludedClipId,
    Duration? workAreaStart,
    Duration? workAreaEnd,
  }) {
    final snappedStart = snapPoint(
      proposed: proposedStart,
      settings: settings,
      index: index,
      frameRate: frameRate,
      threshold: threshold,
      playhead: playhead,
      selectionBoundaries: selectionBoundaries,
      excludedClipBoundaries: excludedClipBoundaries,
      excludedClipId: excludedClipId,
      workAreaStart: workAreaStart,
      workAreaEnd: workAreaEnd,
    );
    final proposedEnd = proposedStart + duration;
    final snappedEnd = snapPoint(
      proposed: proposedEnd,
      settings: settings,
      index: index,
      frameRate: frameRate,
      threshold: threshold,
      playhead: playhead,
      selectionBoundaries: selectionBoundaries,
      excludedClipBoundaries: excludedClipBoundaries,
      excludedClipId: excludedClipId,
      workAreaStart: workAreaStart,
      workAreaEnd: workAreaEnd,
    );
    final startDistance = (snappedStart - proposedStart).abs();
    final endDistance = (snappedEnd - proposedEnd).abs();
    if (endDistance < startDistance) return snappedEnd - duration;
    return snappedStart;
  }

  /// Returns the exact rational frame boundary nearest [positionUs].
  ///
  /// Calculating from the absolute frame number avoids accumulated rounded
  /// millisecond error at rates such as 24, 30, 60, and 120 fps.
  static int frameBoundaryUs(int positionUs, int frameRate) {
    final fps = frameRate.clamp(1, 120);
    final frame = (positionUs * fps / Duration.microsecondsPerSecond).round();
    return (frame * Duration.microsecondsPerSecond / fps).round();
  }

  static Duration adjacentFrame(
    Duration position, {
    required int frameRate,
    required int direction,
  }) {
    final fps = frameRate.clamp(1, 120);
    final scaled =
        position.inMicroseconds * fps / Duration.microsecondsPerSecond;
    final nearestFrame = scaled.round();
    final nearestBoundaryUs =
        (nearestFrame * Duration.microsecondsPerSecond / fps).round();
    final isOnBoundary =
        (position.inMicroseconds - nearestBoundaryUs).abs() <= 1;
    final target = direction < 0
        ? math.max(0, isOnBoundary ? nearestFrame - 1 : scaled.floor())
        : isOnBoundary
        ? nearestFrame + 1
        : scaled.ceil();
    return Duration(
      microseconds: (target * Duration.microsecondsPerSecond / fps).round(),
    );
  }

  static int _lowerBound(List<int> sorted, int target) {
    var lower = 0;
    var upper = sorted.length;
    while (lower < upper) {
      final middle = lower + ((upper - lower) >> 1);
      if (sorted[middle] < target) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    return lower;
  }

  static void _considerNearestUnblocked(
    List<int> sorted,
    int target,
    Set<int> blocked,
    void Function(int candidate) consider,
  ) {
    if (sorted.isEmpty) return;
    final insertion = _lowerBound(sorted, target);
    var left = insertion - 1;
    var right = insertion;
    var accepted = 0;
    while ((left >= 0 || right < sorted.length) && accepted < 2) {
      final useLeft =
          right >= sorted.length ||
          (left >= 0 &&
              (sorted[left] - target).abs() <= (sorted[right] - target).abs());
      final candidate = useLeft ? sorted[left--] : sorted[right++];
      if (blocked.contains(candidate)) continue;
      consider(candidate);
      accepted++;
    }
  }
}
