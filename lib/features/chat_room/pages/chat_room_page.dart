import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../models/chat_room_message.dart';
import '../services/pocketbase_chat_service.dart';

const _defaultChatRoomAuthCollection = 'chat_users';

class ChatRoomPage extends StatefulWidget {
  const ChatRoomPage({super.key});

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage> {
  static const _defaultCollection = 'chat_messages';

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  PocketBaseChatService? _service;
  List<ChatRoomMessage> _messages = const [];
  ChatRoomConnectionState _connection = ChatRoomConnectionState.disconnected;
  String _serverUrl = '';
  String _collection = _defaultCollection;
  String _authCollection = _defaultChatRoomAuthCollection;
  String _email = '';
  ChatRoomFailure? _error;
  bool _loading = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadConfiguration());
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    unawaited(_service?.close());
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    final settings = context.read<SettingsProvider>();
    await settings.loaded;
    if (!mounted) return;
    setState(() {
      _serverUrl = settings.chatRoomPocketBaseServerUrl;
      _collection = settings.chatRoomPocketBaseCollection;
      _authCollection = settings.chatRoomPocketBaseAuthCollection;
      _email = settings.chatRoomPocketBaseEmail;
    });
    if (_serverUrl.isNotEmpty && _email.isNotEmpty) {
      await _connect();
    } else if (_serverUrl.isNotEmpty) {
      setState(() => _error = ChatRoomFailure.credentialsRequired);
    }
  }

  Future<void> _connect({
    String password = '',
    bool forcePasswordLogin = false,
  }) async {
    final url = _serverUrl.trim();
    final uri = Uri.tryParse(url);
    if (url.isEmpty ||
        uri == null ||
        uri.host.isEmpty ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        _collection.trim().isEmpty ||
        _authCollection.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _connection = ChatRoomConnectionState.error;
        _error = ChatRoomFailure.invalidConfiguration;
      });
      return;
    }
    final previous = _service;
    _service = null;
    await previous?.close();
    if (!mounted) return;
    final service = PocketBaseChatService(
      serverUrl: url,
      messageCollection: _collection.trim(),
      authCollection: _authCollection.trim(),
    );
    _service = service;
    setState(() {
      _loading = true;
      _error = null;
      _connection = ChatRoomConnectionState.connecting;
      _messages = const [];
    });
    try {
      final history = await service.connect(
        email: _email,
        password: password,
        forcePasswordLogin: forcePasswordLogin,
        onStatus: (state, [error]) {
          if (!mounted || !identical(_service, service)) return;
          setState(() {
            _connection = state;
            _error = error is ChatRoomServiceException ? error.failure : null;
          });
        },
        onMessage: (message) {
          if (!mounted || !identical(_service, service)) return;
          setState(() {
            _messages = PocketBaseChatService.mergeUniqueMessages(_messages, [
              message,
            ]);
          });
          _scrollToBottom();
        },
      );
      if (!mounted || !identical(_service, service)) return;
      setState(() {
        _messages = PocketBaseChatService.mergeUniqueMessages(
          _messages,
          history,
        );
        _loading = false;
      });
      _scrollToBottom();
    } catch (error) {
      if (!mounted || !identical(_service, service)) return;
      setState(() {
        _error = error is ChatRoomServiceException
            ? error.failure
            : ChatRoomFailure.unexpected;
        _connection = ChatRoomConnectionState.error;
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _configure() async {
    final config =
        await showDialog<
          ({
            String serverUrl,
            String collection,
            String authCollection,
            String email,
            String password,
          })
        >(
          context: context,
          builder: (_) => _ChatRoomConfigDialog(
            serverUrl: _serverUrl,
            collection: _collection,
            authCollection: _authCollection,
            email: _email,
            defaultCollection: _defaultCollection,
          ),
        );
    if (config == null || !mounted) return;
    final normalizedUrl = config.serverUrl.trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final normalizedCollection = config.collection.trim();
    final normalizedAuthCollection = config.authCollection.trim();
    final normalizedEmail = config.email.trim();
    if (normalizedUrl.isEmpty ||
        normalizedCollection.isEmpty ||
        normalizedAuthCollection.isEmpty) {
      return;
    }
    final identityChanged =
        normalizedUrl != _serverUrl ||
        normalizedAuthCollection != _authCollection ||
        normalizedEmail != _email;
    final oldService = _service;
    _service = null;
    await oldService?.close(clearPersistedCredentials: identityChanged);
    if (!mounted) return;
    await context.read<SettingsProvider>().setChatRoomPocketBaseConfig(
      serverUrl: normalizedUrl,
      collection: normalizedCollection,
      authCollection: normalizedAuthCollection,
      email: normalizedEmail,
    );
    if (!mounted) return;
    setState(() {
      _serverUrl = normalizedUrl;
      _collection = normalizedCollection;
      _authCollection = normalizedAuthCollection;
      _email = normalizedEmail;
    });
    await _connect(
      password: config.password,
      forcePasswordLogin: config.password.isNotEmpty,
    );
  }

  Future<void> _send() async {
    final content = _inputController.text.trim();
    final service = _service;
    if (content.isEmpty || service == null || _sending) return;
    setState(() => _sending = true);
    try {
      final message = await service.sendText(content);
      if (!mounted || !identical(_service, service)) return;
      setState(() {
        _messages = PocketBaseChatService.mergeUniqueMessages(_messages, [
          message,
        ]);
        _inputController.clear();
        _error = null;
      });
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is ChatRoomServiceException
            ? error.failure
            : ChatRoomFailure.unexpected;
        _connection = ChatRoomConnectionState.error;
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _statusText(AppLocalizations l10n) => switch (_connection) {
    ChatRoomConnectionState.connecting => l10n.chatRoomStatusConnecting,
    ChatRoomConnectionState.connected => l10n.chatRoomStatusConnected,
    ChatRoomConnectionState.disconnected => l10n.chatRoomStatusDisconnected,
    ChatRoomConnectionState.error => l10n.chatRoomStatusError,
  };

  String? _errorText(AppLocalizations l10n) => switch (_error) {
    ChatRoomFailure.invalidConfiguration =>
      l10n.chatRoomErrorInvalidConfiguration,
    ChatRoomFailure.credentialsRequired =>
      l10n.chatRoomErrorCredentialsRequired,
    ChatRoomFailure.invalidCredentials => l10n.chatRoomErrorInvalidCredentials,
    ChatRoomFailure.unauthorized => l10n.chatRoomErrorUnauthorized,
    ChatRoomFailure.forbidden => l10n.chatRoomErrorForbidden,
    ChatRoomFailure.network => l10n.chatRoomErrorNetwork,
    ChatRoomFailure.serverUnavailable => l10n.chatRoomErrorServerUnavailable,
    ChatRoomFailure.secureStorage ||
    ChatRoomFailure.unexpected => l10n.chatRoomErrorUnexpected,
    null => null,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final enabled =
        _service != null && _connection == ChatRoomConnectionState.connected;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.chatRoomTitle),
        actions: [
          IconButton(
            tooltip: l10n.chatRoomConfigure,
            icon: const Icon(LucideIcons.settings2),
            onPressed: _configure,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                _ConnectionBanner(
                  text: _statusText(l10n),
                  isConnected: _connection == ChatRoomConnectionState.connected,
                  showReconnect:
                      _serverUrl.isNotEmpty &&
                      _email.isNotEmpty &&
                      (_connection == ChatRoomConnectionState.disconnected ||
                          _connection == ChatRoomConnectionState.error),
                  onReconnect: _connect,
                ),
                if (_errorText(l10n) case final errorText?)
                  Container(
                    width: double.infinity,
                    color: colors.errorContainer.withValues(alpha: 0.55),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      '${l10n.chatRoomErrorDetails}: $errorText',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                  ),
                Expanded(
                  child: _serverUrl.isEmpty || _email.isEmpty
                      ? _EmptyHint(
                          icon: LucideIcons.settings2,
                          text: l10n.chatRoomConfigurePrompt,
                        )
                      : _loading && _messages.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _messages.isEmpty
                      ? _EmptyHint(
                          icon: LucideIcons.messagesSquare,
                          text: l10n.chatRoomEmpty,
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) => _MessageBubble(
                            message: _messages[index],
                            isUser: _messages[index].senderId == 'user',
                          ),
                        ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border(
                      top: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: enabled
                                ? l10n.chatRoomInputHint
                                : l10n.chatRoomInputDisabled,
                            filled: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: l10n.chatRoomSend,
                        onPressed: enabled && !_sending ? _send : null,
                        icon: _sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.send),
                      ),
                    ],
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

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.text,
    required this.isConnected,
    required this.showReconnect,
    required this.onReconnect,
  });

  final String text;
  final bool isConnected;
  final bool showReconnect;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = isConnected ? colors.primary : colors.onSurfaceVariant;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colors.surfaceContainerLow,
      child: Row(
        children: [
          Icon(
            isConnected ? LucideIcons.wifi : LucideIcons.wifiOff,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontWeight: AppFontWeights.medium),
            ),
          ),
          if (showReconnect)
            TextButton.icon(
              onPressed: onReconnect,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: Text(l10n.chatRoomReconnect),
            ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 38,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isUser});
  final ChatRoomMessage message;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final time = DateFormat(
      'yyyy-MM-dd HH:mm',
    ).format(message.created.toLocal());
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: isUser ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    message.senderName,
                    style: TextStyle(
                      fontWeight: AppFontWeights.emphasis,
                      color: isUser
                          ? colors.onPrimaryContainer
                          : colors.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              message.content,
              style: TextStyle(
                color: isUser ? colors.onPrimaryContainer : colors.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatRoomConfigDialog extends StatefulWidget {
  const _ChatRoomConfigDialog({
    required this.serverUrl,
    required this.collection,
    required this.authCollection,
    required this.email,
    required this.defaultCollection,
  });
  final String serverUrl;
  final String collection;
  final String authCollection;
  final String email;
  final String defaultCollection;

  @override
  State<_ChatRoomConfigDialog> createState() => _ChatRoomConfigDialogState();
}

class _ChatRoomConfigDialogState extends State<_ChatRoomConfigDialog> {
  late final TextEditingController _urlController;
  late final TextEditingController _collectionController;
  late final TextEditingController _authCollectionController;
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.serverUrl);
    _collectionController = TextEditingController(
      text: widget.collection.isEmpty
          ? widget.defaultCollection
          : widget.collection,
    );
    _authCollectionController = TextEditingController(
      text: widget.authCollection.isEmpty
          ? _defaultChatRoomAuthCollection
          : widget.authCollection,
    );
    _emailController = TextEditingController(text: widget.email);
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _collectionController.dispose();
    _authCollectionController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.chatRoomConfigure),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 600),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.chatRoomServerUrl,
                  hintText: 'https://pocketbase.example.com',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _collectionController,
                decoration: InputDecoration(
                  labelText: l10n.chatRoomCollection,
                  hintText: widget.defaultCollection,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _authCollectionController,
                decoration: InputDecoration(
                  labelText: l10n.chatRoomAuthCollection,
                  hintText: _defaultChatRoomAuthCollection,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: l10n.chatRoomEmail),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(labelText: l10n.chatRoomPassword),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.chatRoomCancel),
        ),
        FilledButton(
          onPressed: () {
            final url = _urlController.text.trim();
            final uri = Uri.tryParse(url);
            if (uri == null ||
                !uri.hasAuthority ||
                uri.host.isEmpty ||
                !(uri.scheme == 'http' || uri.scheme == 'https') ||
                _collectionController.text.trim().isEmpty ||
                _authCollectionController.text.trim().isEmpty) {
              return;
            }
            Navigator.of(context).pop((
              serverUrl: url,
              collection: _collectionController.text.trim(),
              authCollection: _authCollectionController.text.trim(),
              email: _emailController.text.trim(),
              password: _passwordController.text,
            ));
          },
          child: Text(l10n.chatRoomSaveAndConnect),
        ),
      ],
    );
  }
}
