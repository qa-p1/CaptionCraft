import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../services/desktop_workspace_preferences.dart';
import 'desktop_splitter.dart';

/// Responsive three-panel Windows editor shell.
///
/// The shell owns panel geometry and local preferences. Its children remain
/// ordinary editor widgets, which keeps provider state and mobile layouts
/// independent from desktop chrome.
class DesktopWorkspace extends StatefulWidget {
  final Widget mediaPanel;
  final Widget viewer;
  final Widget inspectorPanel;
  final Widget timeline;
  final Widget? statusFooter;
  final DesktopWorkspacePreferencesStore? preferencesStore;

  const DesktopWorkspace({
    super.key,
    required this.mediaPanel,
    required this.viewer,
    required this.inspectorPanel,
    required this.timeline,
    this.statusFooter,
    this.preferencesStore,
  });

  @override
  State<DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<DesktopWorkspace> {
  static const double _minLeftWidth = 180;
  static const double _minRightWidth = 220;
  static const double _minCenterWidth = 240;
  static const double _minTimelineHeight = 170;
  static const double _minViewerHeight = 146;
  static const double _toolbarHeight = 34;
  static const double _footerHeight = 25;
  static const double _splitterExtent = 9;

  late final DesktopWorkspacePreferencesStore _preferencesStore;
  DesktopWorkspacePreferences _preferences =
      const DesktopWorkspacePreferences();
  Timer? _saveDebounce;
  bool _preferencesLoaded = false;
  bool _preferencesChangedBeforeLoad = false;
  bool _mediaRevealOverride = false;
  bool _inspectorRevealOverride = false;

  @override
  void initState() {
    super.initState();
    _preferencesStore =
        widget.preferencesStore ?? DesktopWorkspacePreferencesStore();
    unawaited(_loadPreferences());
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    unawaited(_persistPreferences());
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final loaded = await _preferencesStore.load();
    if (!mounted) return;
    setState(() {
      if (!_preferencesChangedBeforeLoad) {
        _preferences = loaded.normalized();
      }
      _preferencesLoaded = true;
    });
    if (_preferencesChangedBeforeLoad) _schedulePreferencesSave();
  }

  Future<void> _persistPreferences() {
    return _persistPreferencesSafely();
  }

  Future<void> _persistPreferencesSafely() async {
    try {
      await _preferencesStore.save(_preferences);
    } catch (_) {
      // Workspace chrome is optional. A read-only or disconnected profile
      // directory must never interrupt editing or surface an unhandled async
      // exception from a resize gesture.
    }
  }

  void _schedulePreferencesSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 240), () {
      unawaited(_persistPreferences());
    });
  }

  void _updatePreferences(
    DesktopWorkspacePreferences Function(DesktopWorkspacePreferences current)
    mapper,
  ) {
    if (!_preferencesLoaded) _preferencesChangedBeforeLoad = true;
    setState(() {
      _preferences = mapper(_preferences).normalized();
    });
    _schedulePreferencesSave();
  }

  void _resetWorkspace() {
    if (!_preferencesLoaded) _preferencesChangedBeforeLoad = true;
    _mediaRevealOverride = false;
    _inspectorRevealOverride = false;
    setState(() {
      _preferences = const DesktopWorkspacePreferences();
    });
    _schedulePreferencesSave();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final autoCollapseMedia = width < 1080;
        final autoCollapseInspector = width < 900;
        final mediaVisible =
            !_preferences.mediaCollapsed &&
            (!autoCollapseMedia || _mediaRevealOverride) &&
            _canShowMedia(width);
        final inspectorVisible =
            !_preferences.inspectorCollapsed &&
            (!autoCollapseInspector || _inspectorRevealOverride) &&
            _canShowInspector(width, mediaVisible);
        final topAndTimelineHeight = math.max(
          0.0,
          height - _footerHeight - _splitterExtent,
        );
        final timelineHeight = _resolvedTimelineHeight(
          topAndTimelineHeight,
          width,
          mediaVisible,
          inspectorVisible,
        );
        final topHeight = math.max(
          _minViewerHeight + _toolbarHeight,
          topAndTimelineHeight - timelineHeight,
        );

        return ColoredBox(
          key: const ValueKey('desktop_workspace'),
          color: kBackground,
          child: Column(
            children: [
              SizedBox(
                height: topHeight,
                child: Column(
                  children: [
                    _buildWorkspaceToolbar(
                      width: width,
                      mediaVisible: mediaVisible,
                      inspectorVisible: inspectorVisible,
                      autoCollapseMedia: autoCollapseMedia,
                      autoCollapseInspector: autoCollapseInspector,
                    ),
                    Expanded(
                      child: _buildTopPanels(
                        width: width,
                        mediaVisible: mediaVisible,
                        inspectorVisible: inspectorVisible,
                      ),
                    ),
                  ],
                ),
              ),
              DesktopSplitter(
                key: const ValueKey('desktop_workspace_timeline_splitter'),
                axis: DesktopSplitterAxis.horizontal,
                semanticsLabel: 'Timeline height',
                onDelta: (delta) =>
                    _resizeTimeline(-delta, topAndTimelineHeight),
                onDoubleTap: _resetTimelineHeight,
              ),
              SizedBox(
                key: const ValueKey('desktop_workspace_timeline'),
                height: timelineHeight,
                child: widget.timeline,
              ),
              SizedBox(
                height: _footerHeight,
                child: widget.statusFooter ?? _buildDefaultFooter(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWorkspaceToolbar({
    required double width,
    required bool mediaVisible,
    required bool inspectorVisible,
    required bool autoCollapseMedia,
    required bool autoCollapseInspector,
  }) {
    return Container(
      height: _toolbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          _toolbarToggle(
            key: const ValueKey('desktop_workspace_media_toggle'),
            icon: Icons.video_library_outlined,
            label: mediaVisible ? 'Media' : 'Show media',
            selected: mediaVisible,
            enabled: true,
            tooltip: autoCollapseMedia
                ? 'Media panel collapsed at this window width'
                : 'Toggle media and tools panel',
            onPressed: () =>
                _toggleMediaPanel(width: width, mediaVisible: mediaVisible),
          ),
          const SizedBox(width: 4),
          _toolbarToggle(
            key: const ValueKey('desktop_workspace_inspector_toggle'),
            icon: Icons.tune_rounded,
            label: inspectorVisible ? 'Inspector' : 'Show inspector',
            selected: inspectorVisible,
            enabled: true,
            tooltip: autoCollapseInspector
                ? 'Inspector collapsed at this window width'
                : 'Toggle contextual inspector',
            onPressed: () => _toggleInspectorPanel(
              width: width,
              inspectorVisible: inspectorVisible,
            ),
          ),
          const Spacer(),
          if (!_preferencesLoaded)
            const Padding(
              padding: EdgeInsets.only(right: 7),
              child: SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          Tooltip(
            message: 'Reset workspace layout',
            child: IconButton(
              key: const ValueKey('desktop_workspace_reset'),
              visualDensity: VisualDensity.compact,
              onPressed: _resetWorkspace,
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbarToggle({
    required Key key,
    required IconData icon,
    required String label,
    required bool selected,
    required bool enabled,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: key,
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: TextButton.styleFrom(
          visualDensity: const VisualDensity(horizontal: -3, vertical: -4),
          foregroundColor: selected ? kTextPrimary : kTextSecondary,
          backgroundColor: selected ? kAccent.withValues(alpha: 0.12) : null,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildTopPanels({
    required double width,
    required bool mediaVisible,
    required bool inspectorVisible,
  }) {
    final leftWidth = mediaVisible
        ? _resolvedLeftWidth(width, inspectorVisible)
        : 0.0;
    final rightWidth = inspectorVisible
        ? _resolvedRightWidth(width, mediaVisible)
        : 0.0;
    return Row(
      children: [
        if (mediaVisible) ...[
          SizedBox(
            key: const ValueKey('desktop_workspace_media_panel'),
            width: leftWidth,
            child: ClipRect(child: widget.mediaPanel),
          ),
          DesktopSplitter(
            key: const ValueKey('desktop_workspace_media_splitter'),
            axis: DesktopSplitterAxis.vertical,
            semanticsLabel: 'Media panel width',
            onDelta: (delta) => _resizeLeft(delta, width, inspectorVisible),
            onDoubleTap: _resetLeftWidth,
          ),
        ],
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              color: kBackground,
              border: Border.symmetric(
                vertical: BorderSide(color: kBorder, width: 0.5),
              ),
            ),
            child: ClipRect(child: widget.viewer),
          ),
        ),
        if (inspectorVisible) ...[
          DesktopSplitter(
            key: const ValueKey('desktop_workspace_inspector_splitter'),
            axis: DesktopSplitterAxis.vertical,
            semanticsLabel: 'Inspector panel width',
            onDelta: (delta) => _resizeRight(-delta, width, mediaVisible),
            onDoubleTap: _resetRightWidth,
          ),
          SizedBox(
            key: const ValueKey('desktop_workspace_inspector_panel'),
            width: rightWidth,
            child: ClipRect(child: widget.inspectorPanel),
          ),
        ],
      ],
    );
  }

  Widget _buildDefaultFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      alignment: Alignment.centerLeft,
      child: const Text(
        'Desktop workspace',
        style: TextStyle(
          color: kTextTertiary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  bool _canShowMedia(double width) =>
      width >= _minCenterWidth + _minRightWidth + _minLeftWidth + 40;

  bool _canShowInspector(double width, bool mediaVisible) {
    final reserved =
        (mediaVisible ? _minLeftWidth + _splitterExtent : 0) +
        _minCenterWidth +
        _minRightWidth +
        _splitterExtent;
    return width >= reserved;
  }

  double _resolvedLeftWidth(double width, bool inspectorVisible) {
    final max = math.max(
      _minLeftWidth,
      width -
          (inspectorVisible ? _minRightWidth + _splitterExtent : 0) -
          _minCenterWidth -
          _splitterExtent,
    );
    return _preferences.leftPanelWidth.clamp(_minLeftWidth, max).toDouble();
  }

  double _resolvedRightWidth(double width, bool mediaVisible) {
    final max = math.max(
      _minRightWidth,
      width -
          (mediaVisible ? _minLeftWidth + _splitterExtent : 0) -
          _minCenterWidth -
          _splitterExtent,
    );
    return _preferences.rightPanelWidth.clamp(_minRightWidth, max).toDouble();
  }

  double _resolvedTimelineHeight(
    double total,
    double width,
    bool mediaVisible,
    bool inspectorVisible,
  ) {
    final minimumTop = _minViewerHeight + _toolbarHeight;
    final maximumTimeline = math.max(_minTimelineHeight, total - minimumTop);
    return _preferences.timelineHeight
        .clamp(_minTimelineHeight, maximumTimeline)
        .toDouble();
  }

  void _resizeLeft(double delta, double width, bool inspectorVisible) {
    final max = math.max(
      _minLeftWidth,
      width -
          (inspectorVisible
              ? _resolvedRightWidth(width, false) + _splitterExtent
              : 0) -
          _minCenterWidth -
          _splitterExtent,
    );
    _updatePreferences(
      (current) => current.copyWith(
        leftPanelWidth: (current.leftPanelWidth + delta)
            .clamp(_minLeftWidth, max)
            .toDouble(),
      ),
    );
  }

  void _toggleMediaPanel({required double width, required bool mediaVisible}) {
    final shouldShow = !mediaVisible;
    final compact = width < 1080;
    if (compact && shouldShow) {
      _inspectorRevealOverride = false;
    }
    _mediaRevealOverride = compact && shouldShow;
    _updatePreferences(
      (current) => current.copyWith(
        mediaCollapsed: !shouldShow,
        inspectorCollapsed: compact && shouldShow
            ? true
            : current.inspectorCollapsed,
      ),
    );
  }

  void _toggleInspectorPanel({
    required double width,
    required bool inspectorVisible,
  }) {
    final shouldShow = !inspectorVisible;
    final compact = width < 1080;
    if (compact && shouldShow) {
      _mediaRevealOverride = false;
    }
    _inspectorRevealOverride = compact && shouldShow;
    _updatePreferences(
      (current) => current.copyWith(
        inspectorCollapsed: !shouldShow,
        mediaCollapsed: compact && shouldShow ? true : current.mediaCollapsed,
      ),
    );
  }

  void _resizeRight(double delta, double width, bool mediaVisible) {
    final max = math.max(
      _minRightWidth,
      width -
          (mediaVisible
              ? _resolvedLeftWidth(width, false) + _splitterExtent
              : 0) -
          _minCenterWidth -
          _splitterExtent,
    );
    _updatePreferences(
      (current) => current.copyWith(
        rightPanelWidth: (current.rightPanelWidth + delta)
            .clamp(_minRightWidth, max)
            .toDouble(),
      ),
    );
  }

  void _resizeTimeline(double delta, double totalHeight) {
    final maximum = math.max(
      _minTimelineHeight,
      totalHeight - _minViewerHeight - _toolbarHeight,
    );
    _updatePreferences(
      (current) => current.copyWith(
        timelineHeight: (current.timelineHeight + delta)
            .clamp(_minTimelineHeight, maximum)
            .toDouble(),
      ),
    );
  }

  void _resetLeftWidth() => _updatePreferences(
    (current) => current.copyWith(
      leftPanelWidth: DesktopWorkspacePreferences.defaultLeftPanelWidth,
    ),
  );

  void _resetRightWidth() => _updatePreferences(
    (current) => current.copyWith(
      rightPanelWidth: DesktopWorkspacePreferences.defaultRightPanelWidth,
    ),
  );

  void _resetTimelineHeight() => _updatePreferences(
    (current) => current.copyWith(
      timelineHeight: DesktopWorkspacePreferences.defaultTimelineHeight,
    ),
  );
}
