import 'package:pocketbase/pocketbase.dart';

import '../models/chat_room_message.dart';

enum ChatRoomConnectionState { connecting, connected, disconnected, error }

typedef ChatRoomStatusCallback =
    void Function(ChatRoomConnectionState state, [Object? error]);

/// PocketBase record API plus its official SSE realtime subscription.
class PocketBaseChatService {
  PocketBaseChatService({required String serverUrl, required this._collection})
    : _client = PocketBase(serverUrl);

  final PocketBase _client;
  final String _collection;
  UnsubscribeFunc? _unsubscribeRecords;
  UnsubscribeFunc? _unsubscribeConnect;
  bool _closed = false;

  Future<List<ChatRoomMessage>> fetchHistory() async {
    final records = await _client
        .collection(_collection)
        .getFullList(sort: 'created');
    return sortMessages(
      records.map((record) => ChatRoomMessage.fromRecord(record.toJson())),
    );
  }

  Future<ChatRoomMessage> sendText(String content) async {
    if (content.trim().isEmpty) {
      throw ArgumentError.value(content, 'content', 'Message cannot be empty');
    }
    final record = await _client
        .collection(_collection)
        .create(
          body: {'senderId': 'user', 'senderName': '用户', 'content': content},
        );
    return ChatRoomMessage.fromRecord(record.toJson());
  }

  Future<List<ChatRoomMessage>> subscribe({
    required ChatRoomStatusCallback onStatus,
    required void Function(ChatRoomMessage message) onMessage,
  }) async {
    onStatus(ChatRoomConnectionState.connecting);
    _client.realtime.onDisconnect = (subscriptions) {
      if (!_closed && subscriptions.isNotEmpty) {
        onStatus(ChatRoomConnectionState.disconnected);
      }
    };
    try {
      final unsubscribeConnect = await _client.realtime.subscribe(
        'PB_CONNECT',
        (_) {
          if (!_closed) onStatus(ChatRoomConnectionState.connected);
        },
      );
      if (_closed) {
        await unsubscribeConnect();
        return const [];
      }
      _unsubscribeConnect = unsubscribeConnect;
      final unsubscribeRecords = await _client
          .collection(_collection)
          .subscribe('*', (event) {
            if (event.action != 'create' || event.record == null || _closed) {
              return;
            }
            try {
              onMessage(ChatRoomMessage.fromRecord(event.record!.toJson()));
            } catch (error) {
              onStatus(ChatRoomConnectionState.error, error);
            }
          });
      if (_closed) {
        await unsubscribeRecords();
        return const [];
      }
      _unsubscribeRecords = unsubscribeRecords;
      onStatus(ChatRoomConnectionState.connected);
      return await fetchHistory();
    } catch (error) {
      final wasClosed = _closed;
      if (!wasClosed) onStatus(ChatRoomConnectionState.error, error);
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _unsubscribeRecords?.call();
    } catch (_) {
      // The connection may already have been dropped by the server.
    }
    try {
      await _unsubscribeConnect?.call();
    } catch (_) {
      // The connection may already have been dropped by the server.
    }
    _client.close();
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

  /// Returns a created-time ordered list containing only the first copy of
  /// every PocketBase record ID.
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
