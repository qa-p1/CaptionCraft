import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/captioncraft_brand.dart';
import '../../../shared/widgets/snack_bar_helper.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isRegisterMode = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;

  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _confirmPasswordController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _setMode(bool register) {
    if (_isRegisterMode == register) return;
    _animationController.reverse().then((_) {
      if (!mounted) return;
      setState(() {
        _isRegisterMode = register;
        _formKey.currentState?.reset();
      });
      _animationController.forward();
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final authNotifier = ref.read(authNotifierProvider.notifier);
    if (_isRegisterMode) {
      if (_passwordController.text != _confirmPasswordController.text) {
        SnackBarHelper.showError(context, 'Passwords do not match.');
        return;
      }
      await authNotifier.register(
        _nameController.text.trim(),
        _emailController.text.trim(),
        _passwordController.text,
      );
    } else {
      await authNotifier.signIn(
        _emailController.text.trim(),
        _passwordController.text,
      );
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      SnackBarHelper.showWarning(context, 'Enter your email address first.');
      return;
    }
    await ref.read(authNotifierProvider.notifier).sendPasswordReset(email);
    if (mounted && ref.read(authNotifierProvider) is! AsyncError) {
      SnackBarHelper.showSuccess(context, 'Reset link sent to $email');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    final isLoading = authState is AsyncLoading;

    ref.listen(authNotifierProvider, (previous, next) {
      if (next is AsyncError && mounted) {
        SnackBarHelper.showError(context, next.error.toString());
      }
    });

    return Scaffold(
      backgroundColor: kBackground,
      body: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: _LoginBackdropPainter()),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                return SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 48 : 20,
                    vertical: 22,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 44,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1240),
                        child: wide
                            ? Row(
                                children: [
                                  const Expanded(
                                    flex: 11,
                                    child: _StudioIntroduction(),
                                  ),
                                  const SizedBox(width: 54),
                                  Expanded(
                                    flex: 9,
                                    child: _buildAuthCard(isLoading),
                                  ),
                                ],
                              )
                            : _buildCompactLayout(isLoading),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactLayout(bool isLoading) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: CaptionCraftLockup(),
        ),
        const SizedBox(height: 26),
        _buildAuthCard(isLoading),
        const SizedBox(height: 18),
        Text(
          'CUT  /  CAPTION  /  DELIVER',
          style: TextStyle(
            fontFamily: 'monospace',
            color: kTextSecondary,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
          ),
        ),
      ],
    );
  }

  Widget _buildAuthCard(bool isLoading) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: kBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.34),
              blurRadius: 40,
              offset: const Offset(0, 20),
            ),
          ],
        ),
        child: Form(
          key: _formKey,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: kAccentSecondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      'STUDIO ACCESS',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: kTextSecondary,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.25,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 17),
                Text(
                  _isRegisterMode
                      ? 'Build your studio.'
                      : 'Welcome back to the cut.',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 26,
                    height: 1.08,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.9,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isRegisterMode
                      ? 'Create an account to keep projects and usage in sync.'
                      : 'Sign in to pick up exactly where you left the timeline.',
                  style: TextStyle(
                    color: kTextSecondary,
                    fontSize: 13,
                    height: 1.48,
                  ),
                ),
                const SizedBox(height: 23),
                _ModeSelector(
                  registerMode: _isRegisterMode,
                  enabled: !isLoading,
                  onChanged: _setMode,
                ),
                const SizedBox(height: 22),
                AnimatedSize(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: _isRegisterMode
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: TextFormField(
                            controller: _nameController,
                            autofillHints: const [AutofillHints.name],
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Display name',
                              prefixIcon: Icon(
                                Icons.person_outline_rounded,
                                size: 19,
                              ),
                            ),
                            validator: (value) =>
                                (value?.trim().isEmpty ?? true)
                                ? 'Your name is required'
                                : null,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                TextFormField(
                  controller: _emailController,
                  autofillHints: const [
                    AutofillHints.username,
                    AutofillHints.email,
                  ],
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email address',
                    prefixIcon: Icon(Icons.alternate_email_rounded, size: 19),
                  ),
                  validator: (value) {
                    final email = value?.trim() ?? '';
                    if (email.isEmpty) return 'Email is required';
                    if (!RegExp(
                      r'^[\w-.]+@([\w-]+\.)+[\w-]{2,}$',
                    ).hasMatch(email)) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _passwordController,
                  autofillHints: [
                    _isRegisterMode
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  obscureText: !_showPassword,
                  textInputAction: _isRegisterMode
                      ? TextInputAction.next
                      : TextInputAction.done,
                  onFieldSubmitted: (_) {
                    if (!_isRegisterMode && !isLoading) {
                      unawaited(_submit());
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(
                      Icons.lock_outline_rounded,
                      size: 19,
                    ),
                    suffixIcon: IconButton(
                      tooltip: _showPassword
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 19,
                      ),
                    ),
                  ),
                  validator: (value) {
                    if (value?.isEmpty ?? true) return 'Password is required';
                    if (_isRegisterMode && value!.length < 6) {
                      return 'Use at least 6 characters';
                    }
                    return null;
                  },
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: _isRegisterMode
                      ? Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: TextFormField(
                            controller: _confirmPasswordController,
                            autofillHints: const [AutofillHints.newPassword],
                            obscureText: !_showConfirmPassword,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) {
                              if (!isLoading) unawaited(_submit());
                            },
                            decoration: InputDecoration(
                              labelText: 'Confirm password',
                              prefixIcon: const Icon(
                                Icons.lock_clock_outlined,
                                size: 19,
                              ),
                              suffixIcon: IconButton(
                                tooltip: _showConfirmPassword
                                    ? 'Hide password'
                                    : 'Show password',
                                onPressed: () => setState(
                                  () => _showConfirmPassword =
                                      !_showConfirmPassword,
                                ),
                                icon: Icon(
                                  _showConfirmPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 19,
                                ),
                              ),
                            ),
                            validator: (value) =>
                                value != _passwordController.text
                                ? 'Passwords do not match'
                                : null,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (!_isRegisterMode)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: isLoading ? null : _forgotPassword,
                      child: const Text('Forgot password?'),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: _PasswordHint(),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isLoading ? null : _submit,
                    icon: isLoading
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: kOnAccent,
                            ),
                          )
                        : Icon(
                            _isRegisterMode
                                ? Icons.arrow_forward_rounded
                                : Icons.login_rounded,
                            size: 18,
                          ),
                    label: Text(
                      isLoading
                          ? 'Working…'
                          : _isRegisterMode
                          ? 'Create account'
                          : 'Enter studio',
                    ),
                  ),
                ),
                const SizedBox(height: 17),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'OR',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: kTextSecondary,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 17),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () => ref
                              .read(authNotifierProvider.notifier)
                              .signInWithGoogle(),
                    icon: Container(
                      width: 21,
                      height: 21,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: kTextPrimary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'G',
                        style: TextStyle(
                          color: kBackground,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    label: const Text('Continue with Google'),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    'Your source media stays on your device.',
                    style: TextStyle(color: kTextSecondary, fontSize: 10.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StudioIntroduction extends StatelessWidget {
  const _StudioIntroduction();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CaptionCraftLockup(),
          const SizedBox(height: 58),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kAccent.withValues(alpha: 0.26)),
            ),
            child: Text(
              'MOBILE EDITING, WITHOUT THE TOY UI',
              style: TextStyle(
                fontFamily: 'monospace',
                color: kAccent,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.15,
              ),
            ),
          ),
          const SizedBox(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 590),
            child: Text(
              'The timeline\nis yours.',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 60,
                height: 0.93,
                fontWeight: FontWeight.w900,
                letterSpacing: -3.2,
              ),
            ),
          ),
          const SizedBox(height: 21),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              'Layer footage, shape sound, build flawless captions, and finish a publish-ready render from one focused studio.',
              style: TextStyle(
                color: kTextSecondary,
                fontSize: 16,
                height: 1.55,
              ),
            ),
          ),
          const SizedBox(height: 35),
          const _MiniTimeline(),
          const SizedBox(height: 30),
          const Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              _FeatureTag(Icons.layers_outlined, 'Multi-track'),
              _FeatureTag(Icons.closed_caption_outlined, 'Smart captions'),
              _FeatureTag(Icons.high_quality_outlined, 'Clean exports'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  final bool registerMode;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ModeSelector({
    required this.registerMode,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
              label: 'Sign in',
              selected: !registerMode,
              enabled: enabled,
              onTap: () => onChanged(false),
            ),
          ),
          Expanded(
            child: _ModeButton(
              label: 'Create account',
              selected: registerMode,
              enabled: enabled,
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? kSurfaceHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? kTextPrimary : kTextSecondary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordHint extends StatelessWidget {
  const _PasswordHint();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.shield_outlined, color: kTextSecondary, size: 15),
        const SizedBox(width: 7),
        Text(
          'Use 6 or more characters',
          style: TextStyle(color: kTextSecondary, fontSize: 10.5),
        ),
      ],
    );
  }
}

class _FeatureTag extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FeatureTag(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: kSurface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: kAccentSecondary, size: 15),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: kTextPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniTimeline extends StatelessWidget {
  const _MiniTimeline();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: kBorder),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              _TimelineRow(
                icon: Icons.movie_outlined,
                color: kAccent,
                blocks: const [0.42, 0.24, 0.3],
              ),
              const SizedBox(height: 8),
              _TimelineRow(
                icon: Icons.closed_caption_outlined,
                color: kAccentSecondary,
                blocks: const [0.2, 0.29, 0.17, 0.25],
              ),
              const SizedBox(height: 8),
              _TimelineRow(
                icon: Icons.graphic_eq_rounded,
                color: kInfo,
                blocks: const [0.63, 0.33],
              ),
            ],
          ),
          Positioned(
            left: 204,
            top: 0,
            bottom: 0,
            child: Container(width: 1.5, color: kAccent),
          ),
          Positioned(
            left: 200,
            top: 0,
            child: CustomPaint(
              size: const Size(9, 7),
              painter: _PlayheadPainter(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final List<double> blocks;

  const _TimelineRow({
    required this.icon,
    required this.color,
    required this.blocks,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: 29,
            child: Icon(icon, color: kTextSecondary, size: 14),
          ),
          ...blocks.map(
            (widthFactor) => Expanded(
              flex: (widthFactor * 100).round(),
              child: Container(
                height: 23,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color.withValues(alpha: 0.34)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayheadPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = kAccent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LoginBackdropPainter extends CustomPainter {
  const _LoginBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = kBorder.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (double y = 0; y < size.height; y += 48) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    final accentPaint = Paint()..color = kAccent.withValues(alpha: 0.035);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.06, size.height * 0.2, 220, 28),
      accentPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.16, size.height * 0.25, 310, 28),
      accentPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.09, size.height * 0.3, 160, 28),
      Paint()..color = kAccentSecondary.withValues(alpha: 0.025),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
