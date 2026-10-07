import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../models/chat_room_message.dart';

enum ChatRoomConnectionState { connecting, connected, disconnected, error }

enum ChatRoomFailure {
  invalidConfiguration,
  credentialsRequired,
  invalidCredentials,
  unauthorized,
  forbidden,
  network,
  serverUnavailable,
  secureStorage,
  unexpected,
}

class ChatRoomServiceException implements Exception {
  const ChatRoomServiceException(this.failure);

  final ChatRoomFailure failure;

  @override
  String toString() => 'ChatRoomServiceException(${failure.name})';
}

typedef ChatRoomStatusCallback =
    void Function(ChatRoomConnectionState state, [Object? error]);
typedef PocketBaseChatClientFactory =
    PocketBase Function(String baseUrl, AuthStore authStore);

abstract interface class ChatRoomSecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformChatRoomSecureStorage implements ChatRoomSecureStorage {
  const PlatformChatRoomSecureStorage()
    : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// PocketBase records API and official SSE realtime subscription.
///
/// The same [AuthStore] is supplied to the SDK client and its HTTP client
/// wrapper. PocketBase's current Dart SSE transport does not attach the auth
/// header itself, so the wrapper adds it to the SSE GET as well as SDK calls.
class PocketBaseChatService {
  PocketBaseChatService({
    required String serverUrl,
    required String messageCollection,
    required String authCollection,
    ChatRoomSecureStorage? secureStorage,
    this._clientFactory,
    this._httpClientFactory,
  }) : _serverUrl = normalizeBaseAddress(serverUrl),
       _messageCollection = messageCollection.trim(),
       _authCollection = authCollection.trim(),
       _secureStorage = secureStorage ?? const PlatformChatRoomSecureStorage();

  final String _serverUrl;
  final String _messageCollection;
  final String _authCollection;
  final ChatRoomSecureStorage _secureStorage;
  final PocketBaseChatClientFactory? _clientFactory;
  final http.Client Function()? _httpClientFactory;
  PocketBase? _client;
  AuthStore? _authStore;
  UnsubscribeFunc? _unsubscribeRecords;
  UnsubscribeFunc? _unsubscribeConnect;
  String? _authStorageKey;
  String? _passwordStorageKey;
  bool _authenticated = false;
  bool _closed = false;

  bool get isAuthenticated => _authenticated;

  static String normalizeBaseAddress(String address) =>
      address.trim().replaceFirst(RegExp(r'/+$'), '');

  Future<List<ChatRoomMessage>> connect({
    required String email,
    String password = '',
    bool forcePasswordLogin = false,
    required ChatRoomStatusCallback onStatus,
    required void Function(ChatRoomMessage message) onMessage,
  }) async {
    onStatus(ChatRoomConnectionState.connecting);
    final normalizedEmail = email.trim();
    final uri = Uri.tryParse(_serverUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        _messageCollection.isEmpty ||
        _authCollection.isEmpty) {
      throw const ChatRoomServiceException(
        ChatRoomFailure.invalidConfiguration,
      );
    }
    if (normalizedEmail.isEmpty) {
      throw const ChatRoomServiceException(ChatRoomFailure.credentialsRequired);
    }
    if (_client != null) {
      throw StateError('Chat room service is already connected.');
    }

    final identity = '$_serverUrl|$_authCollection|$normalizedEmail';
    final identityHash = sha256.convert(utf8.encode(identity)).toString();
    _authStorageKey = 'kelivo.chat.pocketbase.auth.$identityHash';
    _passwordStorageKey = 'kelivo.chat.pocketbase.password.$identityHash';

    try {
      final authStore = await _restoreAuthStore(_authStorageKey!);
      if (_closed) return const [];
      _authStore = authStore;
      final client =
          _clientFactory?.call(_serverUrl, authStore) ??
          PocketBase(
            _serverUrl,
            authStore: authStore,
            httpClientFactory: () => _AuthenticatedPocketBaseHttpClient(
              authStore,
              _httpClientFactory?.call() ?? http.Client(),
            ),
          );
      _client = client;

      var loggedIn = false;
      if (authStore.token.isNotEmpty && !forcePasswordLogin) {
        try {
          await client
              .collection(_authCollection)
              .authRefresh()
              .timeout(const Duration(seconds: 15));
          if (_closed) return const [];
          await _persistAuthStore();
          loggedIn = authStore.isValid;
        } catch (error) {
          if (!_isAuthRejected(error)) rethrow;
          await _clearAuthToken();
        }
      }

      if (!loggedIn) {
        final passwordToUse = password.isNotEmpty
            ? password
            : (await _readSecret(_passwordStorageKey!) ?? '');
        if (passwordToUse.isEmpty) {
          throw const ChatRoomServiceException(
            ChatRoomFailure.credentialsRequired,
          );
        }
        try {
          await client
              .collection(_authCollection)
              .authWithPassword(normalizedEmail, passwordToUse);
          if (_closed) return const [];
        } catch (error) {
          await _clearAuthToken();
          await _deleteSecret(_passwordStorageKey!);
          throw _safeException(error, duringLogin: true);
        }
        if (!authStore.isValid) {
          await _clearAuthToken();
          throw const ChatRoomServiceException(
            ChatRoomFailure.invalidCredentials,
          );
        }
        await _persistAuthStore();
        await _writeSecret(_passwordStorageKey!, passwordToUse);
        loggedIn = true;
      }

      if (!loggedIn || !authStore.isValid) {
        throw const ChatRoomServiceException(ChatRoomFailure.unauthorized);
      }
      _authenticated = true;
      await _subscribe(onStatus: onStatus, onMessage: onMessage);
      final history = await fetchHistory();
      if (_closed) return const [];
      onStatus(ChatRoomConnectionState.connected);
      return history;
    } catch (error) {
      final safeError = _safeException(error);
      _authenticated = false;
      if (!_closed) onStatus(ChatRoomConnectionState.error, safeError);
      await close();
      throw safeError;
    }
  }

  Future<AuthStore> _restoreAuthStore(String storageKey) async {
    final store = AuthStore();
    final encoded = await _readSecret(storageKey);
    if (encoded == null || encoded.isEmpty) return store;
    try {
      final json = jsonDecode(encoded);
      if (json is! Map) throw const FormatException();
      final token = json['token'];
      final model = json['model'];
      if (token is! String || !_isJwt(token) || model is! Map) {
        throw const FormatException();
      }
      store.save(token, RecordModel.fromJson(model.cast<String, dynamic>()));
      return store;
    } catch (_) {
      await _deleteSecret(storageKey);
      return store;
    }
  }

  static bool _isJwt(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map && payload['exp'] != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistAuthStore() async {
    final store = _authStore;
    final key = _authStorageKey;
    if (store == null || key == null || store.token.isEmpty) return;
    await _writeSecret(
      key,
      jsonEncode({'token': store.token, 'model': store.record?.toJson()}),
    );
  }

  Future<void> _clearAuthToken() async {
    _authStore?.clear();
    _authenticated = false;
    final key = _authStorageKey;
    if (key != null) await _deleteSecret(key);
  }

  Future<String?> _readSecret(String key) async {
    try {
      return await _secureStorage.read(key);
    } catch (_) {
      throw const ChatRoomServiceException(ChatRoomFailure.secureStorage);
    }
  }

  Future<void> _writeSecret(String key, String value) async {
    try {
      await _secureStorage.write(key, value);
    } catch (_) {
      throw const ChatRoomServiceException(ChatRoomFailure.secureStorage);
    }
  }

  Future<void> _deleteSecret(String key) async {
    try {
      await _secureStorage.delete(key);
    } catch (_) {
      throw const ChatRoomServiceException(ChatRoomFailure.secureStorage);
    }
  }

  Future<void> _subscribe({
    required ChatRoomStatusCallback onStatus,
    required void Function(ChatRoomMessage message) onMessage,
  }) async {
    final client = _requireAuthenticatedClient();
    client.realtime.onDisconnect = (subscriptions) {
      if (!_closed && subscriptions.isNotEmpty) {
        onStatus(ChatRoomConnectionState.disconnected);
      }
    };
    final unsubscribeConnect = await client.realtime
        .subscribe('PB_CONNECT', (_) {
          if (_closed) return;
          _authenticated = _authStore?.isValid ?? false;
          onStatus(ChatRoomConnectionState.connected);
        })
        .timeout(const Duration(seconds: 15));
    if (_closed) {
      await unsubscribeConnect();
      return;
    }
    _unsubscribeConnect = unsubscribeConnect;
    final unsubscribeRecords = await client
        .collection(_messageCollection)
        .subscribe('*', (event) {
          if (event.action != 'create' || event.record == null || _closed) {
            return;
          }
          try {
            onMessage(ChatRoomMessage.fromRecord(event.record!.toJson()));
          } catch (_) {
            onStatus(
              ChatRoomConnectionState.error,
              const ChatRoomServiceException(ChatRoomFailure.unexpected),
            );
          }
        });
    if (_closed) {
      await unsubscribeRecords();
      return;
    }
    _unsubscribeRecords = unsubscribeRecords;
  }

  Future<List<ChatRoomMessage>> fetchHistory() async {
    final client = _requireAuthenticatedClient();
    try {
      final records = await client
          .collection(_messageCollection)
          .getFullList(sort: 'created');
      return sortMessages(
        records.map((record) => ChatRoomMessage.fromRecord(record.toJson())),
      );
    } catch (error) {
      throw _safeException(error);
    }
  }

  Future<ChatRoomMessage> sendText(String content) async {
    if (content.trim().isEmpty) {
      throw const ChatRoomServiceException(ChatRoomFailure.unexpected);
    }
    final client = _requireAuthenticatedClient();
    try {
      final record = await client
          .collection(_messageCollection)
          .create(
            body: {'senderId': 'user', 'senderName': '用户', 'content': content},
          );
      return ChatRoomMessage.fromRecord(record.toJson());
    } catch (error) {
      throw _safeException(error);
    }
  }

  PocketBase _requireAuthenticatedClient() {
    final client = _client;
    final store = _authStore;
    if (_closed || client == null || store == null || !_authenticated) {
      throw const ChatRoomServiceException(ChatRoomFailure.unauthorized);
    }
    if (!store.isValid) {
      throw const ChatRoomServiceException(ChatRoomFailure.unauthorized);
    }
    return client;
  }

  static bool _isAuthRejected(Object error) =>
      error is ClientException &&
      (error.statusCode == 401 || error.statusCode == 403);

  static ChatRoomServiceException _safeException(
    Object error, {
    bool duringLogin = false,
  }) {
    if (error is ChatRoomServiceException) return error;
    if (error is http.ClientException || error is TimeoutException) {
      return const ChatRoomServiceException(ChatRoomFailure.network);
    }
    if (error is ClientException) {
      final code = error.statusCode;
      if (duringLogin && (code == 400 || code == 401 || code == 422)) {
        return const ChatRoomServiceException(
          ChatRoomFailure.invalidCredentials,
        );
      }
      if (code == 401) {
        return const ChatRoomServiceException(ChatRoomFailure.unauthorized);
      }
      if (code == 403) {
        return const ChatRoomServiceException(ChatRoomFailure.forbidden);
      }
      if (code == 0) {
        return const ChatRoomServiceException(ChatRoomFailure.network);
      }
      if (code >= 500) {
        return const ChatRoomServiceException(
          ChatRoomFailure.serverUnavailable,
        );
      }
      if (code == 404) {
        return const ChatRoomServiceException(
          ChatRoomFailure.invalidConfiguration,
        );
      }
    }
    return const ChatRoomServiceException(ChatRoomFailure.unexpected);
  }

  Future<void> close({bool clearPersistedCredentials = false}) async {
    if (!_closed) {
      _closed = true;
      _authenticated = false;
      try {
        await _unsubscribeRecords?.call();
      } catch (_) {
        // The SDK can already have closed the SSE stream after a disconnect.
      }
      try {
        await _unsubscribeConnect?.call();
      } catch (_) {
        // The SDK can already have closed the SSE stream after a disconnect.
      }
      try {
        await _client?.realtime.unsubscribe();
      } catch (_) {
        // The SDK may already have dropped the realtime connection.
      }
      _client?.close();
    }
    if (clearPersistedCredentials) {
      _authStore?.clear();
      final authKey = _authStorageKey;
      final passwordKey = _passwordStorageKey;
      if (authKey != null) await _deleteSecret(authKey);
      if (passwordKey != null) await _deleteSecret(passwordKey);
    }
  }

  static List<ChatRoomMessage> sortMessages(
    Iterable<ChatRoomMessage> messages,
  ) {
    final result = messages.toList()
      ..sort((a, b) {
        final byDate = a.created.compareTo(b.created);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    return result;
  }

  static List<ChatRoomMessage> mergeUniqueMessages(
    Iterable<ChatRoomMessage> current,
    Iterable<ChatRoomMessage> incoming,
  ) {
    final byId = <String, ChatRoomMessage>{};
    for (final message in current) {
      byId[message.id] = message;
    }
    for (final message in incoming) {
      byId.putIfAbsent(message.id, () => message);
    }
    return sortMessages(byId.values);
  }
}

class _AuthenticatedPocketBaseHttpClient extends http.BaseClient {
  _AuthenticatedPocketBaseHttpClient(this._authStore, this._delegate);

  final AuthStore _authStore;
  final http.Client _delegate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!request.headers.containsKey('Authorization') &&
        _authStore.token.isNotEmpty) {
      var tokenValid = false;
      try {
        tokenValid = _authStore.isValid;
      } catch (_) {
        tokenValid = false;
      }
      if (tokenValid) request.headers['Authorization'] = _authStore.token;
    }
    return _delegate.send(request);
  }

  @override
  void close() => _delegate.close();
}
