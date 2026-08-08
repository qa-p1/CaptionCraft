import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/caption_studio_service.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../models/subtitle_entry.dart';
import '../models/timeline_models.dart';
import '../providers/editor_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/subtitle_provider.dart';
import 'teleprompter_screen.dart';

class CreatorLabScreen extends ConsumerStatefulWidget {
  final String projectName;

  const CreatorLabScreen({super.key, required this.projectName});

  @override
  ConsumerState<CreatorLabScreen> createState() => _CreatorLabScreenState();
}

class _CreatorLabScreenState extends ConsumerState<CreatorLabScreen> {
  CaptionPaceBand? _paceFilter;

  List<SubtitleEntry> get _entries => ref.read(subtitleProvider).entries;

  @override
  Widget build(BuildContext context) {
    final subtitleState = ref.watch(subtitleProvider);
    final catalog = _buildToolCatalog(subtitleState);
    return DefaultTabController(
      length: 3,
      initialIndex: 0,
      child: Scaffold(
        backgroundColor: kBackground,
        appBar: AppBar(
          toolbarHeight: 66,
          titleSpacing: 4,
          title: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                margin: const EdgeInsets.only(right: 11),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [kAccent, Color(0xFFC84DFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: kAccent.withValues(alpha: 0.2),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Creator Lab'),
                    Text(
                      '${subtitleState.entries.length} captions • '
                      'Offline workflow tools',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: kSuccess.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: kSuccess.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.offline_bolt_rounded, size: 14, color: kSuccess),
                  SizedBox(width: 4),
                  Text(
                    'ON DEVICE',
                    style: TextStyle(
                      color: kSuccess,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.7,
                    ),
                  ),
                ],
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.monitor_heart_outlined), text: 'Review'),
              Tab(icon: Icon(Icons.build_circle_outlined), text: 'Fix'),
              Tab(icon: Icon(Icons.auto_awesome_rounded), text: 'Create'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildReviewTab(subtitleState, catalog),
            _buildCatalogTab(
              subtitleState: subtitleState,
              catalog: catalog,
              area: _LabCatalogArea.fix,
            ),
            _buildCatalogTab(
              subtitleState: subtitleState,
              catalog: catalog,
              area: _LabCatalogArea.create,
            ),
          ],
        ),
      ),
    );
  }

  List<_LabFeature> _buildToolCatalog(SubtitleState subtitleState) {
    return <_LabFeature>[
      _LabFeature(
        id: 'balance_lines',
        group: _LabToolGroup.layoutTiming,
        effectLabel: 'Edits captions',
        icon: Icons.splitscreen_rounded,
        title: 'Smart Line Balance',
        description:
            'Reflows every cue into two visually balanced, mobile-safe lines.',
        onTap: () => _applyResult(CaptionStudioService.balanceLines(_entries)),
      ),
      _LabFeature(
        id: 'reading_speed',
        group: _LabToolGroup.layoutTiming,
        effectLabel: 'Edits captions',
        icon: Icons.speed_rounded,
        title: 'Reading-Speed Retimer',
        description:
            'Expands or tightens cue duration around a professional CPS target.',
        onTap: _showReadingSpeedDialog,
      ),
      _LabFeature(
        id: 'split_long',
        group: _LabToolGroup.layoutTiming,
        effectLabel: 'Edits captions',
        icon: Icons.call_split_rounded,
        title: 'Auto Split Long Cues',
        description:
            'Breaks dense paragraphs into compact cues with proportional timing.',
        onTap: _showSplitDialog,
      ),
      _LabFeature(
        id: 'merge_short',
        group: _LabToolGroup.layoutTiming,
        effectLabel: 'Edits captions',
        icon: Icons.merge_rounded,
        title: 'Tiny Cue Merger',
        description:
            'Combines fragments across short gaps while respecting scene pauses.',
        onTap: () =>
            _applyResult(CaptionStudioService.mergeShortCues(_entries)),
      ),
      _LabFeature(
        id: 'filler_cleaner',
        group: _LabToolGroup.textCleanup,
        effectLabel: 'Edits captions',
        icon: Icons.cleaning_services_rounded,
        title: 'Filler Word Cleaner',
        description:
            'Safely removes “um”, “uh”, “you know”, and similar speech clutter.',
        onTap: () =>
            _applyResult(CaptionStudioService.removeFillerWords(_entries)),
      ),
      _LabFeature(
        id: 'echo_cleaner',
        group: _LabToolGroup.textCleanup,
        effectLabel: 'Edits captions',
        icon: Icons.repeat_one_rounded,
        title: 'Echo Cleaner',
        description:
            'Removes accidental repeated words without flattening intentional copy.',
        onTap: () =>
            _applyResult(CaptionStudioService.removeRepeatedWords(_entries)),
      ),
      _LabFeature(
        id: 'punctuation',
        group: _LabToolGroup.textCleanup,
        effectLabel: 'Edits captions',
        icon: Icons.auto_fix_high_rounded,
        title: 'Punctuation Polish',
        description:
            'Restores sentence casing and chooses question or statement endings.',
        onTap: () =>
            _applyResult(CaptionStudioService.polishPunctuation(_entries)),
      ),
      _LabFeature(
        id: 'frame_snap',
        group: _LabToolGroup.layoutTiming,
        effectLabel: 'Edits captions',
        icon: Icons.grid_4x4_rounded,
        title: 'Frame-Perfect Snap',
        description: 'Quantizes all in/out points to the delivery frame grid.',
        onTap: _showFrameRateDialog,
      ),
      _LabFeature(
        id: 'empty_cues',
        group: _LabToolGroup.textCleanup,
        effectLabel: 'Edits captions',
        icon: Icons.comments_disabled_outlined,
        title: 'Empty Cue Sweeper',
        description:
            'Finds and removes blank caption blocks left behind by imports.',
        destructive: true,
        onTap: () => _confirmAndApply(
          title: 'Remove empty captions?',
          result: CaptionStudioService.removeEmptyCues(_entries),
        ),
      ),
      _LabFeature(
        id: 'sound_cues',
        group: _LabToolGroup.textCleanup,
        effectLabel: 'Edits captions',
        icon: Icons.music_off_rounded,
        title: 'Sound Cue Cleaner',
        description:
            'Removes standalone [Music], [Applause], and ambient annotations.',
        destructive: true,
        onTap: () => _confirmAndApply(
          title: 'Remove sound-only captions?',
          result: CaptionStudioService.removeSoundCues(_entries),
        ),
      ),
      _LabFeature(
        id: 'mask_terms',
        group: _LabToolGroup.namesSafety,
        effectLabel: 'Edits captions',
        icon: Icons.visibility_off_rounded,
        title: 'Sensitive Word Mask',
        description:
            'Masks custom terms while retaining their spacing and visual rhythm.',
        onTap: _showMaskTermsDialog,
      ),
      _LabFeature(
        id: 'speaker_labels',
        group: _LabToolGroup.namesSafety,
        effectLabel: 'Edits captions',
        icon: Icons.record_voice_over_rounded,
        title: 'Speaker Labeler',
        description: 'Adds rotating speaker names in configurable cue groups.',
        onTap: _showSpeakerDialog,
      ),
      _LabFeature(
        id: 'remove_speaker_labels',
        group: _LabToolGroup.namesSafety,
        effectLabel: 'Edits captions',
        icon: Icons.person_off_outlined,
        title: 'Speaker Label Remover',
        description:
            'Strips NAME: and [Speaker] prefixes across the full track.',
        onTap: () => _applyResult(
          CaptionStudioService.stripSpeakerLabelsFromEntries(_entries),
        ),
      ),
      _LabFeature(
        id: 'glossary',
        group: _LabToolGroup.namesSafety,
        effectLabel: 'Edits captions',
        icon: Icons.spellcheck_rounded,
        title: 'Glossary Guard',
        description:
            'Enforces names, products, and branded spelling in one batch.',
        onTap: _showGlossaryDialog,
      ),
      _LabFeature(
        id: 'timing_air',
        group: _LabToolGroup.layoutTiming,
        effectLabel: 'Edits captions',
        icon: Icons.air_rounded,
        title: 'Timing Air',
        description:
            'Adds natural lead-in and tail room without creating collisions.',
        onTap: () => _applyResult(
          CaptionStudioService.addTimingPadding(
            _entries,
            projectDuration: ref.read(editorProvider).timeline.duration,
          ),
        ),
      ),
      _LabFeature(
        id: 'moment_suggestions',
        group: _LabToolGroup.planningMarkers,
        effectLabel: 'Adds markers',
        icon: Icons.local_fire_department_rounded,
        title: 'Moment Suggestions',
        description:
            'Ranks transcript windows with offline hook, pace, and clarity signals.',
        onTap: _showViralMomentRadar,
      ),
      _LabFeature(
        id: 'chapter_markers',
        group: _LabToolGroup.planningMarkers,
        effectLabel: 'Adds markers',
        icon: Icons.view_timeline_rounded,
        title: 'Automatic Chapter Markers',
        description:
            'Uses long pauses and section length to draft named chapter markers.',
        onTap: _showChapterDirector,
      ),
      _LabFeature(
        id: 'caption_motion',
        group: _LabToolGroup.captionMotion,
        effectLabel: 'Edits captions',
        icon: Icons.animation_rounded,
        title: 'Auto Caption Motion',
        description:
            'Assigns animation, color, and emphasis from punctuation and word timing.',
        onTap: () => _confirmAndApply(
          title: 'Apply automatic motion to every caption?',
          result: CaptionStudioService.directKineticCaptions(
            _entries,
            globalStyle: subtitleState.globalStyle,
          ),
          accent: const Color(0xFFC84DFF),
        ),
      ),
      _LabFeature(
        id: 'broll_prompts',
        group: _LabToolGroup.planningMarkers,
        effectLabel: 'Adds markers',
        icon: Icons.movie_filter_rounded,
        title: 'B-roll Prompt Markers',
        description:
            'Drafts keyword-based visual prompts and places them as timeline markers.',
        onTap: _showBrollStoryboard,
      ),
      _LabFeature(
        id: 'social_copy',
        group: _LabToolGroup.publish,
        effectLabel: 'Copies text',
        icon: Icons.rocket_launch_rounded,
        title: 'Draft Social Copy',
        description:
            'Drafts template-based titles, hooks, a description, and hashtags.',
        onTap: _showSocialLaunchPack,
      ),
      _LabFeature(
        id: 'estimated_word_timing',
        group: _LabToolGroup.captionMotion,
        effectLabel: 'Edits captions',
        icon: Icons.graphic_eq_rounded,
        title: 'Estimated Word Timing',
        description:
            'Estimates word timing by text length for karaoke-style animation.',
        onTap: () => _applyResult(
          CaptionStudioService.synthesizeKaraokeTimings(_entries),
        ),
      ),
      _LabFeature(
        id: 'teleprompter',
        group: _LabToolGroup.rehearsal,
        effectLabel: 'Rehearsal',
        icon: Icons.live_tv_rounded,
        title: 'Teleprompter Stage',
        description:
            'Rehearse with auto-scroll, mirror glass mode, pace control, and large type.',
        onTap: _openTeleprompter,
      ),
    ];
  }

  Widget _buildCatalogTab({
    required SubtitleState subtitleState,
    required List<_LabFeature> catalog,
    required _LabCatalogArea area,
  }) {
    final groups = _LabToolGroup.values
        .where((group) => group.area == area)
        .toList();
    return _GroupedFeatureCatalog(
      intro: _LabIntro(
        eyebrow: area == _LabCatalogArea.fix
            ? 'CAPTION WORKSHOP'
            : 'CREATE & PUBLISH',
        title: area == _LabCatalogArea.fix
            ? 'Focused fixes, grouped by the job'
            : 'Offline drafts, markers, motion, and rehearsal',
        description: area == _LabCatalogArea.fix
            ? 'Open only the section you need. Every action states exactly '
                  'what it changes.'
            : 'These tools use deterministic transcript rules. They never '
                  'upload media or pretend to replace editorial judgment.',
        icon: area == _LabCatalogArea.fix
            ? Icons.handyman_rounded
            : Icons.auto_awesome_rounded,
      ),
      groups: groups,
      features: catalog,
      captionsAvailable: subtitleState.entries.isNotEmpty,
    );
  }

  List<_LabRecommendation> _buildRecommendations(
    SubtitleState subtitleState,
    List<_LabFeature> catalog,
  ) {
    if (subtitleState.entries.isEmpty) return const [];
    final byId = {for (final feature in catalog) feature.id: feature};
    final recommendations = <_LabRecommendation>[];

    void add(String id, String reason) {
      final feature = byId[id];
      if (feature == null ||
          recommendations.any((item) => item.feature.id == id)) {
        return;
      }
      recommendations.add(_LabRecommendation(feature, reason));
    }

    final entries = subtitleState.entries;
    final pace = CaptionStudioService.analyzePace(entries);
    final emptyCount = entries
        .where((entry) => entry.text.trim().isEmpty)
        .length;
    final longCount = entries
        .where(
          (entry) =>
              entry.text.replaceAll(RegExp(r'\s+'), ' ').trim().length > 72,
        )
        .length;
    final fastCount = pace
        .where(
          (metric) =>
              metric.band == CaptionPaceBand.fast ||
              metric.band == CaptionPaceBand.extreme,
        )
        .length;
    final missingTiming = entries
        .where((entry) => entry.words?.isNotEmpty != true)
        .length;

    if (emptyCount > 0) {
      add(
        'empty_cues',
        '$emptyCount empty cue${emptyCount == 1 ? '' : 's'} found',
      );
    }
    if (fastCount > 0) {
      add(
        'reading_speed',
        '$fastCount fast cue${fastCount == 1 ? '' : 's'} need breathing room',
      );
    }
    if (longCount > 0) {
      add(
        'split_long',
        '$longCount long cue${longCount == 1 ? '' : 's'} may be hard to scan',
      );
    }
    if (missingTiming > 0) {
      add(
        'estimated_word_timing',
        '$missingTiming cue${missingTiming == 1 ? '' : 's'} lack word timing',
      );
    }

    if (recommendations.length < 3) {
      add('balance_lines', 'A reliable first pass for mobile readability');
    }
    if (recommendations.length < 3) {
      add('punctuation', 'Clean casing and sentence endings in one pass');
    }
    if (recommendations.length < 3) {
      add('timing_air', 'Add small, collision-aware timing margins');
    }
    return recommendations.take(4).toList();
  }

  Widget _buildReviewTab(
    SubtitleState subtitleState,
    List<_LabFeature> catalog,
  ) {
    final metrics = CaptionStudioService.analyzePace(subtitleState.entries);
    final recommendations = _buildRecommendations(subtitleState, catalog);
    final filtered = _paceFilter == null
        ? metrics
        : metrics.where((metric) => metric.band == _paceFilter).toList();
    final averageCps = metrics.isEmpty
        ? 0.0
        : metrics.fold<double>(
                0,
                (sum, metric) => sum + metric.charactersPerSecond,
              ) /
              metrics.length;
    final missingKaraoke = subtitleState.entries
        .where((entry) => entry.words?.isNotEmpty != true)
        .length;
    final lowConfidence = subtitleState.entries
        .where((entry) => entry.isLowConfidence)
        .length;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _LabIntro(
                  eyebrow: 'REVIEW & RECOMMENDED',
                  title: 'Pace Heatmap & Confidence Desk',
                  description:
                      'Start with the few actions this project needs, then '
                      'inspect pace, confidence, and word timing cue by cue.',
                  icon: Icons.monitor_heart_rounded,
                ),
                const SizedBox(height: 18),
                const _SectionHeading(
                  title: 'RECOMMENDED NOW',
                  subtitle: 'Based on the current caption track',
                ),
                const SizedBox(height: 10),
                if (subtitleState.entries.isEmpty)
                  const _CaptionRequirementNotice()
                else
                  _RecommendationGrid(recommendations: recommendations),
                const SizedBox(height: 20),
                const _SectionHeading(
                  title: 'TRACK HEALTH',
                  subtitle: 'Live readability and timing signals',
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final itemWidth = width >= 760
                        ? (width - 30) / 4
                        : (width - 10) / 2;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _ReviewMetric(
                          width: itemWidth,
                          value: averageCps.toStringAsFixed(1),
                          label: 'Average CPS',
                          color: kInfo,
                        ),
                        _ReviewMetric(
                          width: itemWidth,
                          value:
                              '${metrics.where((m) => m.band == CaptionPaceBand.extreme).length}',
                          label: 'Extreme pace',
                          color: kError,
                        ),
                        _ReviewMetric(
                          width: itemWidth,
                          value: '$missingKaraoke',
                          label: 'Missing word timing',
                          color: kWarning,
                        ),
                        _ReviewMetric(
                          width: itemWidth,
                          value: '$lowConfidence',
                          label: 'Low confidence',
                          color: const Color(0xFFC84DFF),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                if (metrics.isNotEmpty) _buildHeatmap(metrics),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      selected: _paceFilter == null,
                      label: const Text('All'),
                      onSelected: (_) => setState(() => _paceFilter = null),
                    ),
                    ...CaptionPaceBand.values.map(
                      (band) => FilterChip(
                        selected: _paceFilter == band,
                        avatar: CircleAvatar(
                          radius: 4,
                          backgroundColor: _paceColor(band),
                        ),
                        label: Text(_paceLabel(band)),
                        onSelected: (_) => setState(() => _paceFilter = band),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: metrics.isEmpty
                            ? null
                            : _showReadingSpeedDialog,
                        icon: const Icon(Icons.speed_rounded),
                        label: const Text('Fix track pace'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: missingKaraoke == 0
                            ? null
                            : () => _applyResult(
                                CaptionStudioService.synthesizeKaraokeTimings(
                                  _entries,
                                ),
                              ),
                        icon: const Icon(Icons.graphic_eq_rounded),
                        label: const Text('Estimate word timing'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '${filtered.length} CUES',
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'No captions match this review filter.',
                style: TextStyle(color: kTextSecondary),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            sliver: SliverList.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final metric = filtered[index];
                return _PaceReviewTile(
                  metric: metric,
                  onOpen: () => _openCueInEditor(metric.entry),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildHeatmap(List<CaptionPaceMetric> metrics) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.gradient_rounded, size: 17, color: kTextSecondary),
              SizedBox(width: 7),
              Text(
                'PACE HEATMAP',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.9,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          SizedBox(
            height: 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: metrics.map((metric) {
                return Expanded(
                  child: Tooltip(
                    message:
                        '${metric.charactersPerSecond.toStringAsFixed(1)} CPS • '
                        '${metric.entry.text}',
                    child: InkWell(
                      onTap: () => _openCueInEditor(metric.entry),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: _paceColor(metric.band),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showReadingSpeedDialog() async {
    var cps = 17.0;
    final selected = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reading-speed target'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${cps.round()} characters per second',
                style: const TextStyle(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Slider(
                value: cps,
                min: 12,
                max: 22,
                divisions: 10,
                label: '${cps.round()} CPS',
                onChanged: (value) => setDialogState(() => cps = value),
              ),
              const Text(
                '15–18 CPS is comfortable for most social and documentary work.',
                style: TextStyle(color: kTextSecondary, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, cps),
              child: const Text('Retime'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _applyResult(
      CaptionStudioService.retimeForReadingSpeed(
        _entries,
        targetCharactersPerSecond: selected,
        projectDuration: ref.read(editorProvider).timeline.duration,
      ),
    );
  }

  Future<void> _showSplitDialog() async {
    var maximum = 72.0;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Maximum cue length'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${maximum.round()} characters',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Slider(
                value: maximum,
                min: 42,
                max: 100,
                divisions: 29,
                label: '${maximum.round()}',
                onChanged: (value) => setDialogState(() => maximum = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, maximum.round()),
              child: const Text('Split'),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    _applyResult(
      CaptionStudioService.splitLongCues(_entries, maximumCharacters: selected),
    );
  }

  Future<void> _showFrameRateDialog() async {
    final selected = await showDialog<double>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Snap to frame rate'),
        children: [24.0, 25.0, 30.0, 50.0, 60.0]
            .map(
              (fps) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, fps),
                child: Row(
                  children: [
                    const Icon(Icons.grid_4x4_rounded, color: kAccent),
                    const SizedBox(width: 12),
                    Text(
                      '${fps.round()} fps',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
    if (selected == null) return;
    _applyResult(
      CaptionStudioService.snapToFrameGrid(_entries, framesPerSecond: selected),
    );
  }

  Future<void> _showMaskTermsDialog() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sensitive word mask'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Terms to mask',
            hintText: 'term one, term two',
            helperText: 'Separate terms with commas or new lines.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Mask terms'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final terms = value
        .split(RegExp(r'[,\n]'))
        .map((term) => term.trim())
        .where((term) => term.isNotEmpty);
    _applyResult(CaptionStudioService.maskTerms(_entries, terms));
  }

  Future<void> _showSpeakerDialog() async {
    final controller = TextEditingController(text: 'Host, Guest');
    var groupSize = 1.0;
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Speaker labeler'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Speaker names',
                  helperText: 'Comma-separated, in speaking order.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Switch every ${groupSize.round()} cue'
                '${groupSize.round() == 1 ? '' : 's'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Slider(
                value: groupSize,
                min: 1,
                max: 6,
                divisions: 5,
                label: '${groupSize.round()}',
                onChanged: (value) => setDialogState(() => groupSize = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (
                controller.text,
                groupSize.round(),
              )),
              child: const Text('Add labels'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null) return;
    final speakers = result.$1
        .split(',')
        .map((speaker) => speaker.trim())
        .where((speaker) => speaker.isNotEmpty)
        .toList();
    _applyResult(
      CaptionStudioService.addSpeakerLabels(
        _entries,
        speakers,
        cuesPerSpeaker: result.$2,
      ),
    );
  }

  Future<void> _showGlossaryDialog() async {
    final controller = TextEditingController(
      text: 'fire base = Firebase\ncaption craft = CaptionCraft',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Glossary Guard'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 5,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'One correction per line',
              helperText: 'Use: incorrect = Correct spelling',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Apply glossary'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final glossary = <String, String>{};
    for (final line in value.split('\n')) {
      final separator = line.indexOf('=');
      if (separator <= 0 || separator >= line.length - 1) continue;
      final from = line.substring(0, separator).trim();
      final to = line.substring(separator + 1).trim();
      if (from.isNotEmpty && to.isNotEmpty) glossary[from] = to;
    }
    _applyResult(CaptionStudioService.applyGlossary(_entries, glossary));
  }

  Future<void> _showViralMomentRadar() async {
    if (!_ensureCaptions()) return;
    final moments = CaptionStudioService.findViralMoments(_entries);
    if (moments.isEmpty) {
      SnackBarHelper.showInfo(context, 'No complete moments found yet.');
      return;
    }
    final selectedPosition = await _showLabResultSheet(
      title: 'Moment Suggestions',
      subtitle:
          '${moments.length} non-overlapping transcript windows ranked locally',
      actionLabel: 'Add moment markers',
      onAction: () {
        _addMarkers(
          moments.map(
            (moment) => TimelineMarker(
              position: moment.start,
              label: 'Moment ${moment.score} • ${_shortLabel(moment.snippet)}',
              color: kAccentSecondary,
            ),
          ),
          'moment',
        );
        Navigator.pop(context);
      },
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: moments.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final moment = moments[index];
          return _InsightCard(
            leading: _ScoreRing(score: moment.score),
            title: _formatRange(moment.start, moment.end),
            body: moment.snippet,
            tags: moment.reasons,
            onTap: () => Navigator.pop(context, moment.start),
          );
        },
      ),
    );
    if (selectedPosition != null && mounted) {
      _returnToEditorAt(selectedPosition);
    }
  }

  Future<void> _showChapterDirector() async {
    if (!_ensureCaptions()) return;
    final chapters = CaptionStudioService.generateChapters(_entries);
    final selectedPosition = await _showLabResultSheet(
      title: 'Automatic Chapter Markers',
      subtitle: '${chapters.length} pause- and length-based sections drafted',
      actionLabel: 'Add chapter markers',
      onAction: () {
        _addMarkers(
          chapters.map(
            (chapter) => TimelineMarker(
              position: chapter.position,
              label: chapter.title,
              type: TimelineMarkerType.chapter,
              color: kInfo,
            ),
          ),
          'chapter',
        );
        Navigator.pop(context);
      },
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: chapters.length,
        separatorBuilder: (_, _) => const SizedBox(height: 9),
        itemBuilder: (context, index) {
          final chapter = chapters[index];
          return _InsightCard(
            leading: CircleAvatar(
              backgroundColor: kInfo.withValues(alpha: 0.12),
              foregroundColor: kInfo,
              child: Text('${index + 1}'),
            ),
            title: chapter.title,
            body:
                '${_formatTime(chapter.position)} • '
                '${(chapter.confidence * 100).round()}% structure score',
            onTap: () => Navigator.pop(context, chapter.position),
          );
        },
      ),
    );
    if (selectedPosition != null && mounted) {
      _returnToEditorAt(selectedPosition);
    }
  }

  Future<void> _showBrollStoryboard() async {
    if (!_ensureCaptions()) return;
    final suggestions = CaptionStudioService.generateBrollStoryboard(_entries);
    if (suggestions.isEmpty) {
      SnackBarHelper.showInfo(
        context,
        'Add more descriptive captions to generate B-roll prompts.',
      );
      return;
    }
    final selectedPosition = await _showLabResultSheet(
      title: 'B-roll Prompt Markers',
      subtitle: '${suggestions.length} timestamped visual directions',
      actionLabel: 'Add B-roll markers',
      onAction: () {
        _addMarkers(
          suggestions.map(
            (suggestion) => TimelineMarker(
              position: suggestion.position,
              label: 'B-roll • ${_shortLabel(suggestion.prompt)}',
              color: const Color(0xFFC84DFF),
            ),
          ),
          'B-roll',
        );
        Navigator.pop(context);
      },
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: suggestions.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final suggestion = suggestions[index];
          return _InsightCard(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFFC84DFF).withValues(alpha: 0.12),
              foregroundColor: const Color(0xFFE0A7FF),
              child: const Icon(Icons.movie_filter_rounded),
            ),
            title: _formatTime(suggestion.position),
            body: suggestion.prompt,
            footnote: 'FROM: ${suggestion.sourceText}',
            trailing: IconButton(
              tooltip: 'Copy prompt',
              onPressed: () =>
                  _copyText(suggestion.prompt, message: 'B-roll prompt copied'),
              icon: const Icon(Icons.copy_rounded),
            ),
            onTap: () => Navigator.pop(context, suggestion.position),
          );
        },
      ),
    );
    if (selectedPosition != null && mounted) {
      _returnToEditorAt(selectedPosition);
    }
  }

  Future<void> _showSocialLaunchPack() async {
    if (!_ensureCaptions()) return;
    final pack = CaptionStudioService.generateSocialLaunchPack(
      _entries,
      projectName: widget.projectName,
    );
    await _showLabResultSheet(
      title: 'Draft Social Copy',
      subtitle: 'Template-based copy drafted locally from transcript keywords',
      actionLabel: 'Copy all drafts',
      onAction: () =>
          _copyText(pack.asPlainText, message: 'Complete launch pack copied'),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CopySection(
            title: 'TITLE IDEAS',
            values: pack.titles,
            onCopy: (value) => _copyText(value),
          ),
          const SizedBox(height: 14),
          _CopySection(
            title: 'OPENING HOOKS',
            values: pack.hooks,
            onCopy: (value) => _copyText(value),
          ),
          const SizedBox(height: 14),
          _CopySection(
            title: 'DESCRIPTION',
            values: [pack.description],
            onCopy: (value) => _copyText(value),
          ),
          const SizedBox(height: 14),
          _CopySection(
            title: 'HASHTAGS',
            values: [pack.hashtags.join(' ')],
            onCopy: (value) => _copyText(value),
          ),
        ],
      ),
    );
  }

  Future<void> _openTeleprompter() async {
    if (!_ensureCaptions()) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TeleprompterScreen(
          projectName: widget.projectName,
          entries: List<SubtitleEntry>.from(_entries),
        ),
      ),
    );
  }

  Future<Duration?> _showLabResultSheet({
    required String title,
    required String subtitle,
    required Widget child,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.4;
    return showModalBottomSheet<Duration>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            key: const Key('creator_lab_result_sheet'),
            height: sheetHeight,
            decoration: const BoxDecoration(
              color: kBackground,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFC84DFF,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.auto_awesome_rounded,
                          color: Color(0xFFE0A7FF),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: kTextPrimary,
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              subtitle,
                              style: const TextStyle(
                                color: kTextSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: child),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                    color: kSurface,
                    border: Border(top: BorderSide(color: kBorder)),
                  ),
                  child: FilledButton.icon(
                    onPressed: onAction,
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text(actionLabel),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmAndApply({
    required String title,
    required CaptionTransformResult result,
    Color accent = kAccent,
  }) async {
    if (!result.changed) {
      SnackBarHelper.showInfo(context, 'No matching captions needed changes.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.auto_awesome_rounded, color: accent),
        title: Text(title),
        content: Text(
          '${result.changedCount} caption item'
          '${result.changedCount == 1 ? '' : 's'} will change.\n\n'
          '${result.summary}\n\nYou can undo this from the editor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed == true) _applyResult(result);
  }

  void _applyResult(CaptionTransformResult result) {
    if (!result.changed) {
      SnackBarHelper.showInfo(context, 'Everything already looks good.');
      return;
    }
    final applied = ref
        .read(editorProvider.notifier)
        .replaceSubtitleEntries(result.entries);
    if (!applied) {
      SnackBarHelper.showInfo(
        context,
        'Unlock the subtitle track before changing captions.',
      );
      return;
    }
    SnackBarHelper.showSuccess(
      context,
      '${result.changedCount} item'
      '${result.changedCount == 1 ? '' : 's'} updated • Undo available',
    );
  }

  void _addMarkers(Iterable<TimelineMarker> markers, String kind) {
    final editorState = ref.read(editorProvider);
    final existing = editorState.timeline.markers;
    final additions = markers.where((marker) {
      return !existing.any(
        (candidate) =>
            (candidate.position - marker.position).inMilliseconds.abs() < 80 &&
            candidate.label == marker.label,
      );
    }).toList();
    if (additions.isEmpty) {
      SnackBarHelper.showInfo(context, 'Those $kind markers already exist.');
      return;
    }
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.copyWith(markers: [...existing, ...additions]),
        );
    SnackBarHelper.showSuccess(
      context,
      '${additions.length} $kind marker'
      '${additions.length == 1 ? '' : 's'} added',
    );
  }

  bool _ensureCaptions() {
    if (_entries.isNotEmpty) return true;
    SnackBarHelper.showWarning(
      context,
      'Add or generate captions before using this tool.',
    );
    return false;
  }

  void _openCueInEditor(SubtitleEntry entry) {
    ref.read(subtitleProvider.notifier).selectEntry(entry.id);
    _requestSeek(entry.startTime);
    Navigator.pop(context);
  }

  void _requestSeek(Duration position) {
    ref.read(playbackProvider.notifier).requestSeek(position);
  }

  void _returnToEditorAt(Duration position) {
    _requestSeek(position);
    Navigator.pop(context);
  }

  Future<void> _copyText(
    String value, {
    String message = 'Copied to clipboard',
  }) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) SnackBarHelper.showSuccess(context, message);
  }

  String _shortLabel(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 46
        ? normalized
        : '${normalized.substring(0, 45)}…';
  }

  String _formatRange(Duration start, Duration end) {
    return '${_formatTime(start)} — ${_formatTime(end)}';
  }

  String _formatTime(Duration value) {
    final minutes = value.inMinutes.toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Color _paceColor(CaptionPaceBand band) {
    return switch (band) {
      CaptionPaceBand.slow => kInfo,
      CaptionPaceBand.balanced => kSuccess,
      CaptionPaceBand.fast => kWarning,
      CaptionPaceBand.extreme => kError,
    };
  }

  String _paceLabel(CaptionPaceBand band) {
    return switch (band) {
      CaptionPaceBand.slow => 'Slow',
      CaptionPaceBand.balanced => 'Balanced',
      CaptionPaceBand.fast => 'Fast',
      CaptionPaceBand.extreme => 'Extreme',
    };
  }
}

enum _LabCatalogArea { fix, create }

enum _LabToolGroup {
  layoutTiming(
    area: _LabCatalogArea.fix,
    title: 'Layout & timing',
    description: 'Line shape, cue length, frame boundaries, and breathing room',
    icon: Icons.schedule_rounded,
  ),
  textCleanup(
    area: _LabCatalogArea.fix,
    title: 'Text cleanup',
    description: 'Speech clutter, punctuation, blank cues, and sound labels',
    icon: Icons.cleaning_services_rounded,
  ),
  namesSafety(
    area: _LabCatalogArea.fix,
    title: 'Names & safety',
    description: 'Sensitive terms, speakers, and consistent brand spelling',
    icon: Icons.shield_outlined,
  ),
  planningMarkers(
    area: _LabCatalogArea.create,
    title: 'Planning markers',
    description: 'Transcript-based moment, chapter, and B-roll prompt markers',
    icon: Icons.bookmarks_outlined,
  ),
  captionMotion(
    area: _LabCatalogArea.create,
    title: 'Caption motion',
    description: 'Rule-based animation direction and estimated word timing',
    icon: Icons.animation_rounded,
  ),
  publish(
    area: _LabCatalogArea.create,
    title: 'Publish drafts',
    description: 'Ready-to-copy titles, hooks, descriptions, and hashtags',
    icon: Icons.outbox_outlined,
  ),
  rehearsal(
    area: _LabCatalogArea.create,
    title: 'Rehearsal',
    description: 'Practice the current script without changing the edit',
    icon: Icons.live_tv_outlined,
  );

  final _LabCatalogArea area;
  final String title;
  final String description;
  final IconData icon;

  const _LabToolGroup({
    required this.area,
    required this.title,
    required this.description,
    required this.icon,
  });
}

class _LabFeature {
  final String id;
  final _LabToolGroup group;
  final String effectLabel;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final bool destructive;

  const _LabFeature({
    required this.id,
    required this.group,
    required this.effectLabel,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.destructive = false,
  });
}

class _LabRecommendation {
  final _LabFeature feature;
  final String reason;

  const _LabRecommendation(this.feature, this.reason);
}

class _GroupedFeatureCatalog extends StatelessWidget {
  final Widget intro;
  final List<_LabToolGroup> groups;
  final List<_LabFeature> features;
  final bool captionsAvailable;

  const _GroupedFeatureCatalog({
    required this.intro,
    required this.groups,
    required this.features,
    required this.captionsAvailable,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 14),
            child: intro,
          ),
        ),
        if (!captionsAvailable)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: _CaptionRequirementNotice(),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
          sliver: SliverList.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final group = groups[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ToolGroupSection(
                  group: group,
                  features: features
                      .where((feature) => feature.group == group)
                      .toList(),
                  captionsAvailable: captionsAvailable,
                  initiallyExpanded: index == 0,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ToolGroupSection extends StatelessWidget {
  final _LabToolGroup group;
  final List<_LabFeature> features;
  final bool captionsAvailable;
  final bool initiallyExpanded;

  const _ToolGroupSection({
    required this.group,
    required this.features,
    required this.captionsAvailable,
    required this.initiallyExpanded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('creator_lab_group_${group.name}'),
        initiallyExpanded: initiallyExpanded,
        maintainState: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: kAccent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(group.icon, color: kAccent, size: 20),
        ),
        title: Text(
          group.title,
          style: const TextStyle(
            color: kTextPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w900,
          ),
        ),
        subtitle: Text(
          '${group.description} • ${features.length} tool'
          '${features.length == 1 ? '' : 's'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kTextSecondary,
            fontSize: 10.5,
            height: 1.35,
          ),
        ),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1000
                  ? 3
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              const spacing = 10.0;
              final itemWidth =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final feature in features)
                    SizedBox(
                      width: itemWidth,
                      height: 178,
                      child: _FeatureCard(
                        feature: feature,
                        captionsAvailable: captionsAvailable,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RecommendationGrid extends StatelessWidget {
  final List<_LabRecommendation> recommendations;

  const _RecommendationGrid({required this.recommendations});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 920
            ? 3
            : constraints.maxWidth >= 620
            ? 2
            : 1;
        const spacing = 10.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final recommendation in recommendations)
              SizedBox(
                width: itemWidth,
                height: 192,
                child: _FeatureCard(
                  feature: recommendation.feature,
                  captionsAvailable: true,
                  contextLabel: recommendation.reason,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final _LabFeature feature;
  final bool captionsAvailable;
  final String? contextLabel;

  const _FeatureCard({
    required this.feature,
    required this.captionsAvailable,
    this.contextLabel,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = captionsAvailable;
    final accent = feature.group.area == _LabCatalogArea.create
        ? const Color(0xFFC84DFF)
        : kAccent;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '${feature.title}. ${feature.effectLabel}.',
      child: Opacity(
        opacity: enabled ? 1 : 0.48,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? feature.onTap : null,
            borderRadius: BorderRadius.circular(15),
            child: Ink(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: kSurfaceHigh,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: enabled ? accent.withValues(alpha: 0.2) : kBorder,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(feature.icon, color: accent, size: 19),
                      ),
                      const Spacer(),
                      if (feature.destructive)
                        const Padding(
                          padding: EdgeInsets.only(right: 7),
                          child: Icon(
                            Icons.warning_amber_rounded,
                            color: kWarning,
                            size: 16,
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: enabled
                              ? accent.withValues(alpha: 0.08)
                              : kBorder.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          enabled ? feature.effectLabel : 'Needs captions',
                          style: TextStyle(
                            color: enabled ? accent : kTextSecondary,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    feature.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Expanded(
                    child: Text(
                      feature.description,
                      maxLines: contextLabel == null ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 10.8,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (contextLabel != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.insights_rounded,
                          color: kInfo,
                          size: 13,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            contextLabel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kInfo,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Text(
                        enabled ? 'OPEN' : 'ADD CAPTIONS TO USE',
                        style: TextStyle(
                          color: enabled ? accent : kTextSecondary,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.75,
                        ),
                      ),
                      if (enabled) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: accent,
                          size: 14,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeading({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: kTextSecondary, fontSize: 10.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CaptionRequirementNotice extends StatelessWidget {
  const _CaptionRequirementNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kWarning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kWarning.withValues(alpha: 0.25)),
      ),
      child: const Row(
        children: [
          Icon(Icons.subtitles_off_rounded, color: kWarning, size: 21),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Add or generate captions in the editor first. Caption-dependent '
              'tools are shown below but stay disabled until then.',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabIntro extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String description;
  final IconData icon;

  const _LabIntro({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    const accent = kAccent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withValues(alpha: 0.08), kSurface],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: TextStyle(
                    color: accent,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.15,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  title,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewMetric extends StatelessWidget {
  final double width;
  final String value;
  final String label;
  final Color color;

  const _ReviewMetric({
    required this.width,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 21,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(color: kTextSecondary, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

class _PaceReviewTile extends StatelessWidget {
  final CaptionPaceMetric metric;
  final VoidCallback onOpen;

  const _PaceReviewTile({required this.metric, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final color = switch (metric.band) {
      CaptionPaceBand.slow => kInfo,
      CaptionPaceBand.balanced => kSuccess,
      CaptionPaceBand.fast => kWarning,
      CaptionPaceBand.extreme => kError,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metric.entry.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 10,
                  children: [
                    Text(
                      '${metric.charactersPerSecond.toStringAsFixed(1)} CPS',
                      style: TextStyle(
                        color: color,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${metric.wordsPerMinute.round()} WPM',
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 9.5,
                      ),
                    ),
                    Text(
                      '${(metric.entry.confidenceScore * 100).round()}% confidence',
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open cue in editor',
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final Widget leading;
  final String title;
  final String body;
  final List<String> tags;
  final String? footnote;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _InsightCard({
    required this.leading,
    required this.title,
    required this.body,
    this.tags = const [],
    this.footnote,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSurface,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: kBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      body,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: tags
                            .map(
                              (tag) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: kSurfaceHigh,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  tag,
                                  style: const TextStyle(
                                    color: kTextSecondary,
                                    fontSize: 8.5,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    if (footnote != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        footnote!,
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _ScoreRing extends StatelessWidget {
  final int score;

  const _ScoreRing({required this.score});

  @override
  Widget build(BuildContext context) {
    final color = score >= 75
        ? kAccentSecondary
        : score >= 55
        ? kWarning
        : kInfo;
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: score / 100,
            strokeWidth: 4,
            backgroundColor: kSurfaceHigh,
            color: color,
          ),
          Text(
            '$score',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _CopySection extends StatelessWidget {
  final String title;
  final List<String> values;
  final ValueChanged<String> onCopy;

  const _CopySection({
    required this.title,
    required this.values,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFE0A7FF),
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 9),
          ...values.map(
            (value) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SelectableText(
                      value,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onCopy(value),
                    icon: const Icon(Icons.copy_rounded, size: 17),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
