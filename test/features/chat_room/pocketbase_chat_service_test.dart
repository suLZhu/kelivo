import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:Kelivo/features/chat_room/models/chat_room_message.dart';
import 'package:Kelivo/features/chat_room/services/pocketbase_chat_service.dart';

void main() {
  group('PocketBaseChatService authentication', () {
    test('cannot load history or send before login', () async {
      final service = _service('http://127.0.0.1:8090');

      await expectLater(
        service.fetchHistory(),
        throwsA(
          isA<ChatRoomServiceException>().having(
            (error) => error.failure,
            'failure',
            ChatRoomFailure.unauthorized,
          ),
        ),
      );
      await expectLater(
        service.sendText('hello'),
        throwsA(isA<ChatRoomServiceException>()),
      );
      await service.close();
    });

    test(
      'logs in before history and realtime, preserving the base path',
      () async {
        final server = _FakePocketBaseServer.start();
        final storage = _MemorySecureStorage();
        final service = _service(
          server.baseUrl,
          secureStorage: storage,
          httpClientFactory: server.newClient,
        );
        addTearDown(() async {
          await service.close();
          await server.close();
        });

        late final List<ChatRoomMessage> history;
        try {
          history = await service.connect(
            email: 'user@example.test',
            password: 'sensitive-password',
            forcePasswordLogin: true,
            onStatus: (_, [__]) {},
            onMessage: (_) {},
          );
        } catch (error) {
          fail(
            'Connection failed ($error); PocketBase paths: '
            '${server.requests.map((request) => request.path).join(', ')}',
          );
        }

        expect(history, isEmpty);
        expect(service.isAuthenticated, isTrue);
        final paths = server.requests.map((request) => request.path).toList();
        expect(
          paths.first,
          '/kelivo-pb/api/collections/chat_users/auth-with-password',
        );
        expect(paths, contains('/kelivo-pb/api/realtime'));
        expect(
          paths,
          contains('/kelivo-pb/api/collections/chat_messages/records'),
        );
        expect(
          paths.indexOf(
            '/kelivo-pb/api/collections/chat_users/auth-with-password',
          ),
          lessThan(
            paths.indexOf('/kelivo-pb/api/collections/chat_messages/records'),
          ),
        );
        expect(server.requests.first.authorization, isNull);
        expect(server.sseAuthorization, isNotEmpty);
        expect(server.recordsAuthorization, isNotEmpty);
        final sent = await service.sendText('Hi');
        expect(sent.id, 'message-1');
        expect(server.createdMessage?['senderId'], 'user');
        expect(server.createdMessage?['senderName'], '用户');
        expect(server.createdMessage?['content'], 'Hi');
        expect(!service.toString().contains('sensitive-password'), isTrue);
        await service.close(clearPersistedCredentials: true);
        expect(storage.values.isEmpty, isTrue);
        expect(server.realtimeStreamClosed, isTrue);
      },
    );

    test(
      'does not persist invalid tokens or expose password in errors',
      () async {
        final server = _FakePocketBaseServer.start(rejectLogin: true);
        final storage = _MemorySecureStorage();
        final service = _service(
          server.baseUrl,
          secureStorage: storage,
          httpClientFactory: server.newClient,
        );
        addTearDown(() async {
          await service.close(clearPersistedCredentials: true);
          await server.close();
        });

        Object? caught;
        try {
          await service.connect(
            email: 'user@example.test',
            password: 'sensitive-password',
            forcePasswordLogin: true,
            onStatus: (_, [__]) {},
            onMessage: (_) {},
          );
        } catch (error) {
          caught = error;
        }

        expect(caught, isA<ChatRoomServiceException>());
        expect(!caught.toString().contains('sensitive-password'), isTrue);
        expect(storage.values.isEmpty, isTrue);
        expect(service.isAuthenticated, isFalse);
        expect(
          server.requests.map((request) => request.path),
          isNot(contains('/kelivo-pb/api/realtime')),
        );
      },
    );

    test('refreshes a restored token before loading history', () async {
      final server = _FakePocketBaseServer.start();
      final storage = _MemorySecureStorage();
      final service = _service(
        server.baseUrl,
        secureStorage: storage,
        httpClientFactory: server.newClient,
      );
      final identity = '${server.baseUrl}|chat_users|user@example.test';
      final hash = sha256.convert(utf8.encode(identity));
      storage.values['kelivo.chat.pocketbase.auth.$hash'] = jsonEncode({
        'token': _token,
        'model': _record,
      });
      addTearDown(() async {
        await service.close(clearPersistedCredentials: true);
        await server.close();
      });

      try {
        await service.connect(
          email: 'user@example.test',
          onStatus: (_, [__]) {},
          onMessage: (_) {},
        );
      } catch (error) {
        fail(
          'Connection failed ($error); PocketBase paths: '
          '${server.requests.map((request) => request.path).join(', ')}',
        );
      }

      expect(
        server.requests.first.path,
        '/kelivo-pb/api/collections/chat_users/auth-refresh',
      );
      expect(
        server.requests.any(
          (request) => request.path.endsWith('/auth-with-password'),
        ),
        isFalse,
      );
      expect(server.requests.first.authorization, _token);
    });

    test('normalizes trailing slash without dropping base path', () {
      expect(
        PocketBaseChatService.normalizeBaseAddress(
          'https://example.test/kelivo-pb///',
        ),
        'https://example.test/kelivo-pb',
      );
    });
  });
}

PocketBaseChatService _service(
  String url, {
  ChatRoomSecureStorage? secureStorage,
  http.Client Function()? httpClientFactory,
}) => PocketBaseChatService(
  serverUrl: url,
  messageCollection: 'chat_messages',
  authCollection: 'chat_users',
  secureStorage: secureStorage ?? _MemorySecureStorage(),
  httpClientFactory: httpClientFactory,
);

class _MemorySecureStorage implements ChatRoomSecureStorage {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FakeRequest {
  const _FakeRequest(this.path, this.method, this.authorization);
  final String path;
  final String method;
  final String? authorization;
}

class _FakePocketBaseServer {
  _FakePocketBaseServer({required this.rejectLogin});

  final bool rejectLogin;
  final requests = <_FakeRequest>[];
  final _sseControllers = <StreamController<List<int>>>[];
  String? sseAuthorization;
  String? recordsAuthorization;
  Map<String, dynamic>? createdMessage;

  bool get realtimeStreamClosed =>
      _sseControllers.isNotEmpty &&
      _sseControllers.every((stream) => stream.isClosed);

  String get baseUrl => 'https://pocketbase.example.test/kelivo-pb';

  static _FakePocketBaseServer start({bool rejectLogin = false}) =>
      _FakePocketBaseServer(rejectLogin: rejectLogin);

  http.Client newClient() => _FakePocketBaseHttpClient(this);

  Future<http.StreamedResponse> handle(
    http.BaseRequest request,
    _FakePocketBaseHttpClient client,
  ) async {
    final path = request.url.path;
    final authorization = request.headers['Authorization'];
    requests.add(_FakeRequest(path, request.method, authorization));

    if (path.endsWith('/auth-with-password')) {
      if (rejectLogin) {
        return _jsonResponse(request, {'message': 'Invalid credentials.'}, 400);
      }
      return _jsonResponse(request, {'token': _token, 'record': _record});
    }
    if (path.endsWith('/auth-refresh')) {
      return _jsonResponse(request, {'token': _token, 'record': _record});
    }
    if (path.endsWith('/realtime') && request.method == 'GET') {
      sseAuthorization = authorization;
      final controller = StreamController<List<int>>();
      _sseControllers.add(controller);
      client._sseController = controller;
      controller.add(
        utf8.encode(
          'id: fake-client\nevent: PB_CONNECT\n'
          'data: {"clientId":"fake-client"}\n\n',
        ),
      );
      return http.StreamedResponse(
        controller.stream,
        200,
        request: request,
        headers: const {'content-type': 'text/event-stream'},
      );
    }
    if (path.endsWith('/realtime') && request.method == 'POST') {
      return _jsonResponse(request, null, 204);
    }
    if (path.endsWith('/chat_messages/records') && request.method == 'POST') {
      createdMessage = request is http.Request
          ? jsonDecode(request.body) as Map<String, dynamic>
          : <String, dynamic>{};
      return _jsonResponse(request, {
        'id': 'message-1',
        'senderId': createdMessage!['senderId'],
        'senderName': createdMessage!['senderName'],
        'content': createdMessage!['content'],
        'created': '2026-10-07 11:00:00.000Z',
      });
    }
    if (path.endsWith('/chat_messages/records')) {
      recordsAuthorization = authorization;
      return _jsonResponse(request, {
        'page': 1,
        'perPage': 30,
        'totalItems': 0,
        'totalPages': 0,
        'items': [],
      });
    }
    return _jsonResponse(request, {'message': 'Not found'}, 404);
  }

  http.StreamedResponse _jsonResponse(
    http.BaseRequest request,
    Object? body, [
    int statusCode = 200,
  ]) => http.StreamedResponse(
    body == null
        ? const Stream<List<int>>.empty()
        : Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    statusCode,
    request: request,
    headers: const {'content-type': 'application/json'},
  );

  Future<void> close() async {
    for (final controller in _sseControllers) {
      if (!controller.isClosed) await controller.close();
    }
  }
}

class _FakePocketBaseHttpClient extends http.BaseClient {
  _FakePocketBaseHttpClient(this._server);

  final _FakePocketBaseServer _server;
  StreamController<List<int>>? _sseController;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _server.handle(request, this);

  @override
  void close() {
    final controller = _sseController;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }
}

const _token = 'header.eyJleHAiOjQ3MDAwMDAwMDB9.signature';
const _record = {
  'id': 'user-1',
  'collectionId': '_pb_users_auth_',
  'collectionName': 'chat_users',
  'email': 'user@example.test',
  'created': '2026-10-07 10:00:00.000Z',
  'updated': '2026-10-07 10:00:00.000Z',
};
