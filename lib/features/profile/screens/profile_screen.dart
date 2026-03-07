import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../../auth/providers/auth_provider.dart';
import '../../quota/providers/quota_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final quota = ref.watch(quotaProvider);
    final authState = ref.watch(authNotifierProvider);
    final isBusy = authState is AsyncLoading;

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
    final avatarLabel = displayName.isNotEmpty ? displayName : email;
    final canResetPassword =
        email != 'No email available' &&
        user.providerData.any((provider) => provider.providerId == 'password');

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildAccountCard(
            displayName: displayName,
            email: email,
            avatarLabel: avatarLabel,
          ),
          const SizedBox(height: 16),
          _buildUsageCard(quota),
          const SizedBox(height: 16),
          _buildActionCard(
            user: user,
            canResetPassword: canResetPassword,
            isBusy: isBusy,
          ),
        ],
      ),
    );
  }

  String _displayNameFor(User user) {
    final rawDisplayName = user.displayName?.trim();
    if (rawDisplayName != null && rawDisplayName.isNotEmpty) {
      return rawDisplayName;
    }

    final email = user.email?.trim();
    if (email != null && email.contains('@')) {
      return email.split('@').first;
    }

    return 'User';
  }

  Widget _buildAccountCard({
    required String displayName,
    required String email,
    required String avatarLabel,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: kSurfaceElevated,
            child: Text(
              avatarLabel[0].toUpperCase(),
              style: GoogleFonts.inter(
                color: kTextPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 28,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: GoogleFonts.inter(
                    color: kTextPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  email,
                  style: GoogleFonts.inter(color: kTextSecondary, fontSize: 14),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: kAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: kAccent.withValues(alpha: 0.28)),
                  ),
                  child: Text(
                    'Signed in',
                    style: GoogleFonts.inter(
                      color: kAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsageCard(QuotaState quota) {
    final progress = quota.maxRuns == 0
        ? 0.0
        : (quota.runsUsed / quota.maxRuns).clamp(0, 1).toDouble();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Usage',
            style: GoogleFonts.inter(
              color: kTextPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            quota.isLoading
                ? 'Loading your free-run usage...'
                : '${quota.remaining} free runs remaining',
            style: GoogleFonts.inter(
              color: kTextPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            quota.isLoading
                ? 'Usage is tied to this device.'
                : '${quota.runsUsed} of ${quota.maxRuns} free transcriptions used on this device.',
            style: GoogleFonts.inter(
              color: kTextSecondary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: quota.isLoading ? null : progress,
              backgroundColor: kSurfaceElevated,
              valueColor: AlwaysStoppedAnimation<Color>(
                quota.canRun ? kAccent : kWarning,
              ),
            ),
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
    return Container(
      decoration: _cardDecoration(),
      child: Column(
        children: [
          _buildSectionHeader('Account tools'),
          if (canResetPassword)
            _ActionTile(
              icon: Icons.lock_reset_rounded,
              title: 'Reset password',
              subtitle: 'Send a password reset link to ${user.email!}',
              enabled: !isBusy,
              onTap: () => _handlePasswordReset(user.email!),
            ),
          _ActionTile(
            icon: Icons.logout_rounded,
            title: 'Sign out',
            subtitle: 'Log out of this account on this device',
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
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: GoogleFonts.inter(
            color: kTextPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: kSurface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: kBorder),
    );
  }

  Future<void> _handlePasswordReset(String email) async {
    await ref.read(authNotifierProvider.notifier).sendPasswordReset(email);
    if (!mounted) return;

    final state = ref.read(authNotifierProvider);
    if (state is AsyncError) return;

    SnackBarHelper.showSuccess(context, 'Password reset email sent to $email');
  }

  Future<void> _handleSignOut() async {
    await ref.read(authNotifierProvider.notifier).signOut();
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor),
      ),
      title: Text(
        title,
        style: GoogleFonts.inter(
          color: enabled ? titleColor : kTextSecondary,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: GoogleFonts.inter(color: kTextSecondary, fontSize: 13),
      ),
      trailing:
          trailing ??
          const Icon(Icons.chevron_right_rounded, color: kTextSecondary),
      onTap: enabled ? onTap : null,
    );
  }
}
