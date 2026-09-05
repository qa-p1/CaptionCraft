import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/api_key_vault.dart';

class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key, required this.vault});
  final ApiKeyVault vault;

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<ApiService, TextEditingController> _controllers;
  final _visible = <ApiService>{};
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final service in ApiService.values) service: TextEditingController(),
    };
    widget.vault.addListener(_changed);
    widget.vault.initialize().then((_) {
      if (mounted) _changed();
    });
    _fill();
  }

  void _fill() {
    if (!widget.vault.ready ||
        widget.vault.locked ||
        _dirty ||
        widget.vault.isRetired) {
      return;
    }
    for (final service in ApiService.values) {
      _controllers[service]!.text = widget.vault.key(service);
    }
  }

  void _changed() {
    if (!mounted) return;
    if (widget.vault.isRetired) {
      _dirty = false;
      for (final controller in _controllers.values) {
        controller.clear();
      }
    }
    setState(_fill);
  }

  @override
  void dispose() {
    widget.vault.removeListener(_changed);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openProvider(ApiService service) async {
    try {
      final opened = await launchUrl(
        Uri.parse(service.signupUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        _message('Could not open your browser. Visit ${service.signupUrl}');
      }
    } catch (_) {
      _message('Could not open your browser. Visit ${service.signupUrl}');
    }
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final firstSave = widget.vault.recoveryCode.isEmpty;
    try {
      await widget.vault.save({
        for (final s in ApiService.values) s: _controllers[s]!.text,
      });
      if (!mounted || widget.vault.isRetired) return;
      setState(() {
        _dirty = false;
        _fill();
      });
      _message(
        widget.vault.error ??
            (widget.vault.cloud
                ? 'Keys saved securely on this device and encrypted in your cloud backup.'
                : 'Keys saved securely on this PC.'),
      );
      if (firstSave && widget.vault.cloud) await _showRecoveryCode();
    } catch (_) {
      _message(
        widget.vault.error ??
            'Unable to save keys. Reopen Settings and try again.',
      );
    }
  }

  Future<void> _showRecoveryCode() async {
    if (widget.vault.recoveryCode.isEmpty || widget.vault.isRetired) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: widget.vault,
        builder: (_, _) => AlertDialog(
          title: const Text('Keep your recovery code'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Save this in your password manager. It unlocks your encrypted API keys on another device or after reinstalling. We cannot recover it for you. Your account password is different.',
                ),
                const SizedBox(height: 16),
                SelectableText(
                  widget.vault.isRetired
                      ? 'Account changed.'
                      : widget.vault.recoveryCode,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: widget.vault.isRetired
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: widget.vault.recoveryCode),
                      );
                      _message('Recovery code copied. Keep it private.');
                    },
              child: const Text('Copy code'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restore() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _RestoreDialog(),
    );
    if (code == null || code.isEmpty || !mounted || widget.vault.isRetired) {
      return;
    }
    try {
      await widget.vault.restore(code);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _fill();
      });
      _message('Backup unlocked. Your saved services are ready.');
    } catch (_) {
      _message(widget.vault.error ?? 'Could not restore the backup.');
    }
  }

  Future<void> _replaceBackup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Replace locked backup?'),
        content: const Text(
          'If you lost your recovery code, start with an empty backup and enter your API keys again. This replaces the encrypted keys in your account, but does not revoke them at the providers. Your projects are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Replace backup'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || widget.vault.isRetired) return;
    try {
      await widget.vault.replaceLockedBackup();
      if (!mounted || widget.vault.isRetired) return;
      setState(() {
        _dirty = false;
        _fill();
      });
      _message(
        widget.vault.error ??
            'Empty backup saved. You can now add your keys again.',
      );
      await _showRecoveryCode();
    } catch (_) {
      _message('Could not replace the backup. Your saved keys are unchanged.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = widget.vault;
    final editable =
        vault.ready && !vault.loading && !vault.busy && !vault.locked;
    return PopScope(
      canPop: !_dirty && !vault.busy,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || vault.busy) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Discard unsaved keys?'),
            content: const Text(
              'Your previously saved keys will remain unchanged.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) {
          setState(() => _dirty = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.pop(context);
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings · Connected services')),
        body: vault.isRetired
            ? const Center(child: Text('Account changed. Reopen Settings.'))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Form(
                    key: _form,
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text(
                          'Set up in about 2 minutes',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Connect only the services you want. Editing, importing, manual captions and exporting work without API keys. Provider signup or approval can take longer.',
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '1. Open a provider and create your own API key.\n2. Paste it below and save.\n3. Start creating. Your provider’s quotas and charges apply. Audio is sent to Groq only when you generate captions.',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          vault.cloud
                              ? 'Keys are encrypted before cloud backup. This device remembers the recovery code securely; a new device needs it once.'
                              : 'Local desktop mode: keys are protected by Windows secure storage on this PC. Cloud backup requires a supported cloud account.',
                        ),
                        if (vault.error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              vault.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (vault.busy || vault.loading)
                          const LinearProgressIndicator(),
                        if (vault.locked)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Your cloud backup is locked. Restore it below. You can keep editing without unlocking.',
                            ),
                          ),
                        for (final service in ApiService.values)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    service.label,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  Text(service.description),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: () => _openProvider(service),
                                      icon: const Icon(Icons.open_in_new),
                                      label: Text(
                                        'Get ${service.label} API key',
                                      ),
                                    ),
                                  ),
                                  TextFormField(
                                    key: ValueKey('api-key-${service.name}'),
                                    controller: _controllers[service],
                                    enabled: editable,
                                    obscureText: !_visible.contains(service),
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    maxLength: 512,
                                    onChanged: (_) =>
                                        setState(() => _dirty = true),
                                    validator: (value) {
                                      try {
                                        ApiKeyVault.normalize(value ?? '');
                                        return null;
                                      } catch (_) {
                                        return 'Paste only the API key, without spaces or line breaks.';
                                      }
                                    },
                                    decoration: InputDecoration(
                                      labelText:
                                          '${service.label} API key (optional)',
                                      counterText: '',
                                      suffixIcon: IconButton(
                                        tooltip: _visible.contains(service)
                                            ? 'Hide key'
                                            : 'Show key',
                                        onPressed: () => setState(() {
                                          if (!_visible.remove(service)) {
                                            _visible.add(service);
                                          }
                                        }),
                                        icon: Icon(
                                          _visible.contains(service)
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                        ),
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: editable
                                        ? () {
                                            _controllers[service]!.clear();
                                            setState(() => _dirty = true);
                                          }
                                        : null,
                                    child: const Text('Remove key'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: editable ? _save : null,
                          icon: const Icon(Icons.lock_outline),
                          label: const Text('Save keys securely'),
                        ),
                        const SizedBox(height: 10),
                        if (vault.cloud && vault.pendingSync)
                          OutlinedButton(
                            onPressed: vault.busy ? null : vault.retrySync,
                            child: const Text('Retry cloud backup'),
                          ),
                        if (vault.cloud)
                          TextButton(
                            onPressed: vault.busy ? null : _restore,
                            child: const Text('Restore encrypted cloud backup'),
                          ),
                        if (vault.cloud && vault.recoveryCode.isNotEmpty)
                          TextButton(
                            onPressed: _showRecoveryCode,
                            child: const Text('Show recovery code'),
                          ),
                        if (vault.cloud && vault.locked)
                          TextButton(
                            onPressed: vault.busy ? null : _replaceBackup,
                            child: const Text('Lost recovery code? Start over'),
                          ),
                        const Padding(
                          padding: EdgeInsets.only(top: 14),
                          child: Text(
                            'Blank keys disable only their own service. Removing a key here does not revoke it at the provider; use the provider dashboard to revoke it.',
                          ),
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

class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog();

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Unlock cloud backup'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter the recovery code saved from your previous device. Restoring replaces API keys saved on this device with your cloud backup.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Recovery code'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('Restore'),
      ),
    ],
  );
}

Future<void> showApiSetupPrompt(BuildContext context, ApiKeyVault vault) async {
  await vault.initialize();
  if (!context.mounted || vault.isRetired || !vault.ready || vault.seenSetup) {
    return;
  }
  // Persist before displaying so Skip and route dismissal are both remembered.
  try {
    await vault.dismissSetup();
  } catch (_) {
    return;
  }
  if (!context.mounted || vault.isRetired) return;
  final setup = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Make CaptionCraft yours in 2 minutes'),
      content: const Text(
        'Add your own API keys for automatic captions, GIFs and stock media. We’ll show you where to get each one and remember them securely.\n\nYou can skip this and use the editor now. Find it anytime in Settings → Connected services.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Skip for now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Set up services'),
        ),
      ],
    ),
  );
  if (setup == true && context.mounted && !vault.isRetired) {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => ApiSettingsScreen(vault: vault)),
    );
  }
}
