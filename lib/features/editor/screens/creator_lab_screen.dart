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
    return DefaultTabController(
      length: 3,
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
                      '23 creative tools',
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
                color: const Color(0xFFC84DFF).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: const Color(0xFFC84DFF).withValues(alpha: 0.3),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 14, color: Color(0xFFE0A7FF)),
                  SizedBox(width: 4),
                  Text(
                    '7 WOW',
                    style: TextStyle(
                      color: Color(0xFFE0A7FF),
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
              Tab(icon: Icon(Icons.build_circle_outlined), text: 'Repair'),
              Tab(icon: Icon(Icons.auto_awesome_rounded), text: 'Wow Lab'),
              Tab(icon: Icon(Icons.monitor_heart_outlined), text: 'Review'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildRepairTab(),
            _buildWowTab(subtitleState),
            _buildReviewTab(subtitleState),
          ],
        ),
      ),
    );
  }

  Widget _buildRepairTab() {
    final tools = <_LabFeature>[
      _LabFeature(
        number: 1,
        icon: Icons.splitscreen_rounded,
        title: 'Smart Line Balance',
        description:
            'Reflows every cue into two visually balanced, mobile-safe lines.',
        onTap: () => _applyResult(CaptionStudioService.balanceLines(_entries)),
      ),
      _LabFeature(
        number: 2,
        icon: Icons.speed_rounded,
        title: 'Reading-Speed Retimer',
        description:
            'Expands or tightens cue duration around a professional CPS target.',
        onTap: _showReadingSpeedDialog,
      ),
      _LabFeature(
        number: 3,
        icon: Icons.call_split_rounded,
        title: 'Auto Split Long Cues',
        description:
            'Breaks dense paragraphs into compact cues with proportional timing.',
        onTap: _showSplitDialog,
      ),
      _LabFeature(
        number: 4,
        icon: Icons.merge_rounded,
        title: 'Tiny Cue Merger',
        description:
            'Combines fragments across short gaps while respecting scene pauses.',
        onTap: () =>
            _applyResult(CaptionStudioService.mergeShortCues(_entries)),
      ),
      _LabFeature(
        number: 5,
        icon: Icons.cleaning_services_rounded,
        title: 'Filler Word Cleaner',
        description:
            'Safely removes “um”, “uh”, “you know”, and similar speech clutter.',
        onTap: () =>
            _applyResult(CaptionStudioService.removeFillerWords(_entries)),
      ),
      _LabFeature(
        number: 6,
        icon: Icons.repeat_one_rounded,
        title: 'Echo Cleaner',
        description:
            'Removes accidental repeated words without flattening intentional copy.',
        onTap: () =>
            _applyResult(CaptionStudioService.removeRepeatedWords(_entries)),
      ),
      _LabFeature(
        number: 7,
        icon: Icons.auto_fix_high_rounded,
        title: 'Punctuation Polish',
        description:
            'Restores sentence casing and chooses question or statement endings.',
        onTap: () =>
            _applyResult(CaptionStudioService.polishPunctuation(_entries)),
      ),
      _LabFeature(
        number: 8,
        icon: Icons.grid_4x4_rounded,
        title: 'Frame-Perfect Snap',
        description: 'Quantizes all in/out points to the delivery frame grid.',
        onTap: _showFrameRateDialog,
      ),
      _LabFeature(
        number: 9,
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
        number: 10,
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
        number: 11,
        icon: Icons.visibility_off_rounded,
        title: 'Sensitive Word Mask',
        description:
            'Masks custom terms while retaining their spacing and visual rhythm.',
        onTap: _showMaskTermsDialog,
      ),
      _LabFeature(
        number: 12,
        icon: Icons.record_voice_over_rounded,
        title: 'Speaker Labeler',
        description: 'Adds rotating speaker names in configurable cue groups.',
        onTap: _showSpeakerDialog,
      ),
      _LabFeature(
        number: 13,
        icon: Icons.person_off_outlined,
        title: 'Speaker Label Remover',
        description:
            'Strips NAME: and [Speaker] prefixes across the full track.',
        onTap: () => _applyResult(
          CaptionStudioService.stripSpeakerLabelsFromEntries(_entries),
        ),
      ),
      _LabFeature(
        number: 14,
        icon: Icons.spellcheck_rounded,
        title: 'Glossary Guard',
        description:
            'Enforces names, products, and branded spelling in one batch.',
        onTap: _showGlossaryDialog,
      ),
      _LabFeature(
        number: 15,
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
    ];
    return _FeatureGrid(
      intro: const _LabIntro(
        eyebrow: 'PRECISION TOOLKIT',
        title: 'Repair a complete caption track in seconds',
        description:
            'Every action is local, deterministic, persisted automatically, '
            'and can be undone from the editor.',
        icon: Icons.handyman_rounded,
      ),
      features: tools,
    );
  }

  Widget _buildWowTab(SubtitleState subtitleState) {
    final tools = <_LabFeature>[
      _LabFeature(
        number: 17,
        wow: true,
        icon: Icons.local_fire_department_rounded,
        title: 'Viral Moment Radar',
        description:
            'Scores hook density, curiosity, pace, energy, and specificity to find standout moments.',
        onTap: _showViralMomentRadar,
      ),
      _LabFeature(
        number: 18,
        wow: true,
        icon: Icons.view_timeline_rounded,
        title: 'Magic Chapter Director',
        description:
            'Finds topic boundaries and turns them into named chapter markers automatically.',
        onTap: _showChapterDirector,
      ),
      _LabFeature(
        number: 19,
        wow: true,
        icon: Icons.animation_rounded,
        title: 'Kinetic Caption Director',
        description:
            'Directs animation, color, and emphasis cue-by-cue from the emotional shape of the words.',
        onTap: () => _confirmAndApply(
          title: 'Direct the complete caption performance?',
          result: CaptionStudioService.directKineticCaptions(
            _entries,
            globalStyle: subtitleState.globalStyle,
          ),
          accent: const Color(0xFFC84DFF),
        ),
      ),
      _LabFeature(
        number: 20,
        wow: true,
        icon: Icons.movie_filter_rounded,
        title: 'B-roll Storyboard',
        description:
            'Builds timestamped visual prompts from concrete ideas in the transcript.',
        onTap: _showBrollStoryboard,
      ),
      _LabFeature(
        number: 21,
        wow: true,
        icon: Icons.rocket_launch_rounded,
        title: 'Social Launch Pack',
        description:
            'Generates title options, opening hooks, a description, and ready-to-copy hashtags.',
        onTap: _showSocialLaunchPack,
      ),
      _LabFeature(
        number: 22,
        wow: true,
        icon: Icons.graphic_eq_rounded,
        title: 'Karaoke Time Machine',
        description:
            'Synthesizes word-level timing for imported or manually written captions.',
        onTap: () => _applyResult(
          CaptionStudioService.synthesizeKaraokeTimings(_entries),
        ),
      ),
      _LabFeature(
        number: 23,
        wow: true,
        icon: Icons.live_tv_rounded,
        title: 'Teleprompter Stage',
        description:
            'Rehearse full-screen with auto-scroll, mirror glass mode, pace control, and large type.',
        onTap: _openTeleprompter,
      ),
    ];
    return _FeatureGrid(
      intro: const _LabIntro(
        eyebrow: 'SIGNATURE EXPERIENCES',
        title: 'Turn a transcript into a creative co-director',
        description:
            'Seven offline-first workflows that surface moments, build launch '
            'assets, and direct a more expressive cut.',
        icon: Icons.auto_awesome_rounded,
        wow: true,
      ),
      features: tools,
      wow: true,
    );
  }

  Widget _buildReviewTab(SubtitleState subtitleState) {
    final metrics = CaptionStudioService.analyzePace(subtitleState.entries);
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
                  eyebrow: 'FEATURE 16 • REVIEW QUEUE',
                  title: 'Pace Heatmap & Confidence Desk',
                  description:
                      'See exactly where viewers may struggle, then jump to or '
                      'repair the affected cue.',
                  icon: Icons.monitor_heart_rounded,
                ),
                const SizedBox(height: 18),
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
                        label: const Text('Fill word timing'),
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
        children: [24.0, 25.0, 30.0, 60.0]
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
    await _showLabResultSheet(
      title: 'Viral Moment Radar',
      subtitle: '${moments.length} non-overlapping moments ranked',
      actionLabel: 'Add radar markers',
      onAction: () {
        _addMarkers(
          moments.map(
            (moment) => TimelineMarker(
              position: moment.start,
              label: 'Viral ${moment.score} • ${_shortLabel(moment.snippet)}',
              color: kAccentSecondary,
            ),
          ),
          'viral moment',
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
            onTap: () => _requestSeek(moment.start),
          );
        },
      ),
    );
  }

  Future<void> _showChapterDirector() async {
    if (!_ensureCaptions()) return;
    final chapters = CaptionStudioService.generateChapters(_entries);
    await _showLabResultSheet(
      title: 'Magic Chapter Director',
      subtitle: '${chapters.length} topic sections detected',
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
                '${(chapter.confidence * 100).round()}% boundary confidence',
            onTap: () => _requestSeek(chapter.position),
          );
        },
      ),
    );
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
    await _showLabResultSheet(
      title: 'B-roll Storyboard',
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
            onTap: () => _requestSeek(suggestion.position),
          );
        },
      ),
    );
  }

  Future<void> _showSocialLaunchPack() async {
    if (!_ensureCaptions()) return;
    final pack = CaptionStudioService.generateSocialLaunchPack(
      _entries,
      projectName: widget.projectName,
    );
    await _showLabResultSheet(
      title: 'Social Launch Pack',
      subtitle: 'Offline copy kit generated from your transcript',
      actionLabel: 'Copy complete pack',
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

  Future<void> _showLabResultSheet({
    required String title,
    required String subtitle,
    required Widget child,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            height: MediaQuery.sizeOf(sheetContext).height * 0.86,
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
    ref.read(subtitleProvider.notifier).loadSubtitles(result.entries);
    final subtitleState = ref.read(subtitleProvider);
    final editorState = ref.read(editorProvider);
    ref
        .read(editorProvider.notifier)
        .setTimeline(
          editorState.timeline.mergeSubtitleEntries(
            subtitles: subtitleState.entries,
            globalStyle: subtitleState.globalStyle,
          ),
        );
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

class _LabFeature {
  final int number;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final bool wow;
  final bool destructive;

  const _LabFeature({
    required this.number,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.wow = false,
    this.destructive = false,
  });
}

class _FeatureGrid extends StatelessWidget {
  final Widget intro;
  final List<_LabFeature> features;
  final bool wow;

  const _FeatureGrid({
    required this.intro,
    required this.features,
    this.wow = false,
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
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.crossAxisExtent;
              final columns = width >= 1080
                  ? 3
                  : width >= 680
                  ? 2
                  : 1;
              return SliverGrid.builder(
                itemCount: features.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: wow ? 184 : 170,
                ),
                itemBuilder: (context, index) {
                  return _FeatureCard(feature: features[index]);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final _LabFeature feature;

  const _FeatureCard({required this.feature});

  @override
  Widget build(BuildContext context) {
    final accent = feature.wow ? const Color(0xFFC84DFF) : kAccent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: feature.onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            gradient: feature.wow
                ? LinearGradient(
                    colors: [const Color(0xFF1D1324), kSurface, kSurface],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: feature.wow ? null : kSurface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: feature.wow ? accent.withValues(alpha: 0.3) : kBorder,
            ),
            boxShadow: feature.wow
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.07),
                      blurRadius: 24,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.11),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(feature.icon, color: accent, size: 21),
                  ),
                  const Spacer(),
                  if (feature.destructive)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        color: kWarning,
                        size: 17,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      feature.wow
                          ? '${feature.number.toString().padLeft(2, '0')} • WOW'
                          : feature.number.toString().padLeft(2, '0'),
                      style: TextStyle(
                        color: feature.wow
                            ? const Color(0xFFE0A7FF)
                            : kTextSecondary,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                feature.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Text(
                  feature.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ),
              Row(
                children: [
                  Text(
                    feature.wow ? 'OPEN EXPERIENCE' : 'RUN TOOL',
                    style: TextStyle(
                      color: accent,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, color: accent, size: 14),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabIntro extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String description;
  final IconData icon;
  final bool wow;

  const _LabIntro({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.icon,
    this.wow = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = wow ? const Color(0xFFC84DFF) : kAccent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: wow ? 0.12 : 0.08),
            kSurface,
          ],
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
