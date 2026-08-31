import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/firebase_service.dart';
import '../../../shared/widgets/captioncraft_brand.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../auth/providers/auth_provider.dart';
import '../../quota/providers/quota_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _isUpdatingProfile = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final quota = ref.watch(quotaProvider);
    final authState = ref.watch(authNotifierProvider);
    final isBusy = authState is AsyncLoading || _isUpdatingProfile;

    ref.listen<AsyncValue<void>>(authNotifierProvider, (previous, next) {
      if (!mounted || next is! AsyncError) return;
      SnackBarHelper.showError(context, next.error.toString());
    });
    ref.listen<AsyncValue<User?>>(authStateProvider, (previous, next) {
      final wasSignedIn = previous?.asData?.value != null;
      final isSignedOut = next.asData?.value == null;
      if (!mounted || !wasSignedIn || !isSignedOut) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    if (user == null) {
      return const Scaffold(
        backgroundColor: kBackground,
        body: Center(
          child: CircularProgressIndicator(color: kAccent, strokeWidth: 2),
        ),
      );
    }

    final displayName = _displayNameFor(user);
    final email = user.email?.trim().isNotEmpty == true
        ? user.email!.trim()
        : 'No email available';
    final canResetPassword =
        user.email?.isNotEmpty == true &&
        user.providerData.any((provider) => provider.providerId == 'password');

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        titleSpacing: 4,
        title: const Row(
          children: [
            CaptionCraftMark(size: 32, radius: 8),
            SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Workspace',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                Text(
                  'ACCOUNT & USAGE',
                  style: TextStyle(
                    color: kTextSecondary,
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.25,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _ProfileBackdropPainter()),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 780;
              final identity = _buildIdentityCard(
                user: user,
                displayName: displayName,
                email: email,
                enabled: !isBusy,
              );
              final usage = _buildUsageCard(quota);
              final workspace = _buildWorkspaceCard();
              final account = _buildActionCard(
                user: user,
                canResetPassword: canResetPassword,
                isBusy: isBusy,
              );

              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  wide ? 30 : 16,
                  16,
                  wide ? 30 : 16,
                  32,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildPageHeader(displayName),
                        const SizedBox(height: 18),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 6,
                                child: Column(
                                  children: [
                                    identity,
                                    const SizedBox(height: 16),
                                    usage,
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  children: [
                                    workspace,
                                    const SizedBox(height: 16),
                                    account,
                                  ],
                                ),
                              ),
                            ],
                          )
                        else ...[
                          identity,
                          const SizedBox(height: 14),
                          usage,
                          const SizedBox(height: 14),
                          workspace,
                          const SizedBox(height: 14),
                          account,
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPageHeader(String displayName) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Good to see you, $displayName.',
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.75,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Your editing workspace is local-first and ready to cut.',
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: kSuccess.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: kSuccess.withValues(alpha: 0.25)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded, color: kSuccess, size: 14),
              SizedBox(width: 6),
              Text(
                'SIGNED IN',
                style: TextStyle(
                  color: kSuccess,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIdentityCard({
    required User user,
    required String displayName,
    required String email,
    required bool enabled,
  }) {
    final providerLabel = _providerLabel(user);
    return _StudioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 76,
            child: CustomPaint(
              size: const Size(double.infinity, 76),
              painter: _MiniTimelinePainter(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProfileAvatar(
                photoUrl: user.photoURL,
                label: displayName.isNotEmpty ? displayName : email,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kTextPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.45,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Edit display name',
                          onPressed: enabled
                              ? () => _renameDisplayName(user, displayName)
                              : null,
                          icon: const Icon(Icons.edit_rounded, size: 18),
                        ),
                      ],
                    ),
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MetaBadge(
                          icon: Icons.verified_user_outlined,
                          label: providerLabel,
                          color: kAccent,
                        ),
                        if (user.emailVerified)
                          const _MetaBadge(
                            icon: Icons.mark_email_read_outlined,
                            label: 'Verified',
                            color: kSuccess,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _AccountMetric(
                  label: 'MEMBER SINCE',
                  value: _dateLabel(user.metadata.creationTime),
                ),
              ),
              Container(width: 1, height: 34, color: kBorder),
              const SizedBox(width: 16),
              Expanded(
                child: _AccountMetric(
                  label: 'LAST SIGN-IN',
                  value: _dateLabel(user.metadata.lastSignInTime),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUsageCard(QuotaState quota) {
    final used = quota.runsUsed.clamp(0, quota.maxRuns);
    final remaining = quota.remaining;
    return _StudioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              _SectionIcon(icon: Icons.closed_caption_rounded),
              SizedBox(width: 11),
              Expanded(
                child: Text(
                  'Automatic captions',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                'DEVICE PLAN',
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            quota.isLoading ? 'Checking usage…' : '$remaining runs available',
            style: const TextStyle(
              color: kTextPrimary,
              fontSize: 25,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.65,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            quota.isLoading
                ? 'Usage is securely tied to this device.'
                : '$used of ${quota.maxRuns} successful transcription runs used. '
                      'Failed and cancelled attempts are not charged.',
            style: const TextStyle(
              color: kTextSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 19),
          Row(
            children: List.generate(quota.maxRuns, (index) {
              final consumed = index < used;
              return Expanded(
                child: Container(
                  height: 8,
                  margin: EdgeInsets.only(
                    right: index == quota.maxRuns - 1 ? 0 : 7,
                  ),
                  decoration: BoxDecoration(
                    color: consumed ? kAccent : kSurfaceHigh,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: consumed
                          ? kAccent.withValues(alpha: 0.7)
                          : kBorder,
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkspaceCard() {
    return const _StudioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionIcon(icon: Icons.storage_rounded),
              SizedBox(width: 11),
              Text(
                'Workspace behavior',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: 20),
          _WorkspaceLine(
            icon: Icons.offline_bolt_outlined,
            title: 'Local-first editing',
            subtitle: 'Timeline edits remain available without cloud access.',
          ),
          SizedBox(height: 16),
          _WorkspaceLine(
            icon: Icons.cloud_sync_outlined,
            title: 'Background project sync',
            subtitle: 'Signed-in projects sync when a connection is available.',
          ),
          SizedBox(height: 16),
          _WorkspaceLine(
            icon: Icons.video_file_outlined,
            title: 'Source media stays yours',
            subtitle:
                'Deleting a project never deletes original or exported files.',
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required User user,
    required bool canResetPassword,
    required bool isBusy,
  }) {
    return _StudioCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 9),
            child: Text(
              'ACCOUNT TOOLS',
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.25,
              ),
            ),
          ),
          if (canResetPassword)
            _ActionTile(
              icon: Icons.lock_reset_rounded,
              title: 'Reset password',
              subtitle: 'Send a secure link to ${user.email!}',
              enabled: !isBusy,
              onTap: () => _handlePasswordReset(user.email!),
            ),
          _ActionTile(
            icon: Icons.description_outlined,
            title: 'Open-source licenses',
            subtitle: 'Review licenses for bundled software',
            enabled: !isBusy,
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'CaptionCraft',
            ),
          ),
          _ActionTile(
            icon: Icons.logout_rounded,
            title: 'Sign out',
            subtitle: 'Local projects remain on this device',
            iconColor: kError,
            titleColor: kError,
            enabled: !isBusy,
            onTap: _handleSignOut,
            trailing: isBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kAccent,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _displayNameFor(User user) {
    final name = user.displayName?.trim();
    if (name?.isNotEmpty == true) return name!;
    final email = user.email?.trim();
    if (email != null && email.contains('@')) return email.split('@').first;
    return 'Editor';
  }

  String _providerLabel(User user) {
    final providers = user.providerData.map((item) => item.providerId).toSet();
    if (providers.contains('google.com')) return 'Google account';
    if (providers.contains('password')) return 'Email account';
    return 'Signed-in account';
  }

  String _dateLabel(DateTime? date) {
    if (date == null) return '—';
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  Future<void> _renameDisplayName(User user, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Display name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nextName == null || nextName == currentName) return;

    setState(() => _isUpdatingProfile = true);
    try {
      await FirebaseService.updateDisplayName(nextName);
      await user.reload();
      if (!mounted) return;
      setState(() => _isUpdatingProfile = false);
      SnackBarHelper.showSuccess(context, 'Display name updated');
    } catch (error) {
      if (!mounted) return;
      setState(() => _isUpdatingProfile = false);
      SnackBarHelper.showError(context, 'Could not update name: $error');
    }
  }

  Future<void> _handlePasswordReset(String email) async {
    await ref.read(authNotifierProvider.notifier).sendPasswordReset(email);
    if (!mounted || ref.read(authNotifierProvider) is AsyncError) return;
    SnackBarHelper.showSuccess(context, 'Password reset email sent to $email');
  }

  Future<void> _handleSignOut() async {
    await ref.read(authNotifierProvider.notifier).signOut();
  }
}

class _StudioCard extends StatelessWidget {
  const _StudioCard({
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: kSurface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.photoUrl, required this.label});

  final String? photoUrl;
  final String label;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: kSurfaceHigh,
      alignment: Alignment.center,
      child: Text(
        label.isEmpty ? 'E' : label[0].toUpperCase(),
        style: const TextStyle(
          color: kAccentSecondary,
          fontSize: 26,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
    return Container(
      width: 66,
      height: 66,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: kBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: photoUrl?.isNotEmpty == true
          ? Image.network(
              photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            )
          : fallback,
    );
  }
}

class _MetaBadge extends StatelessWidget {
  const _MetaBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountMetric extends StatelessWidget {
  const _AccountMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kTextSecondary,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            color: kTextPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 37,
      height: 37,
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: kAccent.withValues(alpha: 0.2)),
      ),
      child: Icon(icon, color: kAccent, size: 19),
    );
  }
}

class _WorkspaceLine extends StatelessWidget {
  const _WorkspaceLine({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: kSurfaceElevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kBorder),
          ),
          child: Icon(icon, color: kAccentSecondary, size: 17),
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
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
    this.iconColor = kAccent,
    this.titleColor = kTextPrimary,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;
  final Color iconColor;
  final Color titleColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      leading: Container(
        width: 39,
        height: 39,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: iconColor, size: 19),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? titleColor : kTextSecondary,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: kTextSecondary, fontSize: 10),
      ),
      trailing:
          trailing ??
          const Icon(
            Icons.arrow_forward_rounded,
            color: kTextSecondary,
            size: 17,
          ),
      onTap: enabled ? onTap : null,
    );
  }
}

class _MiniTimelinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = kBorder
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width; x += 34) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    canvas.drawLine(
      Offset(0, size.height * 0.38),
      Offset(size.width, size.height * 0.38),
      line,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.72),
      Offset(size.width, size.height * 0.72),
      line,
    );

    final clips = Paint()
      ..color = kAccent.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(12, 8, size.width * 0.46, 17),
        const Radius.circular(4),
      ),
      clips,
    );
    clips.color = kAccentSecondary.withValues(alpha: 0.24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.38, 34, size.width * 0.5, 14),
        const Radius.circular(4),
      ),
      clips,
    );
    clips.color = kInfo.withValues(alpha: 0.22);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.16, 58, size.width * 0.38, 11),
        const Radius.circular(3),
      ),
      clips,
    );

    final playhead = Paint()
      ..color = kAccent
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width * 0.62, 0),
      Offset(size.width * 0.62, size.height),
      playhead,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ProfileBackdropPainter extends CustomPainter {
  const _ProfileBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = kBorder.withValues(alpha: 0.14)
      ..strokeWidth = 1;
    for (var x = 20.0; x < size.width; x += 64) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final ember = Paint()..color = kAccent.withValues(alpha: 0.035);
    canvas.drawCircle(
      Offset(size.width * 0.08, size.height * 0.28),
      size.shortestSide * 0.28,
      ember,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
