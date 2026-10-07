import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
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
        final server = await _FakePocketBaseServer.start();
        final storage = _MemorySecureStorage();
        final service = _service(server.baseUrl, secureStorage: storage);
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
        final realtimeUpdatesBeforeClose = server.requests
            .where(
              (request) =>
                  request.method == 'POST' &&
                  request.path.endsWith('/realtime'),
            )
            .length;

        await service.close(clearPersistedCredentials: true);
        expect(storage.values.isEmpty, isTrue);
        expect(
          server.requests
              .where(
                (request) =>
                    request.method == 'POST' &&
                    request.path.endsWith('/realtime'),
              )
              .length,
          greaterThan(realtimeUpdatesBeforeClose),
        );
      },
    );

    test(
      'does not persist invalid tokens or expose password in errors',
      () async {
        final server = await _FakePocketBaseServer.start(rejectLogin: true);
        final storage = _MemorySecureStorage();
        final service = _service(server.baseUrl, secureStorage: storage);
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
      final server = await _FakePocketBaseServer.start();
      final storage = _MemorySecureStorage();
      final service = _service(server.baseUrl, secureStorage: storage);
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
}) => PocketBaseChatService(
  serverUrl: url,
  messageCollection: 'chat_messages',
  authCollection: 'chat_users',
  secureStorage: secureStorage ?? _MemorySecureStorage(),
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
  _FakePocketBaseServer(this._server, {required this.rejectLogin});

  final HttpServer _server;
  final bool rejectLogin;
  final requests = <_FakeRequest>[];
  String? sseAuthorization;
  String? recordsAuthorization;
  Map<String, dynamic>? createdMessage;
  StreamSubscription<HttpRequest>? _subscription;

  String get baseUrl =>
      'http://${_server.address.address}:${_server.port}/kelivo-pb';

  static Future<_FakePocketBaseServer> start({bool rejectLogin = false}) async {
    final server = _FakePocketBaseServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      rejectLogin: rejectLogin,
    );
    server._subscription = server._server.listen(server._handle);
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add(
      _FakeRequest(
        path,
        request.method,
        request.headers.value(HttpHeaders.authorizationHeader),
      ),
    );
    if (path.endsWith('/auth-with-password')) {
      await request.drain<void>();
      if (rejectLogin) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'message': 'Invalid credentials.'}));
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'token': _token, 'record': _record}),
        );
      }
      await request.response.close();
      return;
    }
    if (path.endsWith('/auth-refresh')) {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'token': _token, 'record': _record}));
      await request.response.close();
      return;
    }
    if (path.endsWith('/realtime') && request.method == 'GET') {
      sseAuthorization = request.headers.value(HttpHeaders.authorizationHeader);
      request.response.headers
        ..contentType = ContentType('text', 'event-stream')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(
        'id: fake-client\nevent: PB_CONNECT\ndata: {}\n\n',
      );
      await request.response.flush();
      return;
    }
    if (path.endsWith('/realtime') && request.method == 'POST') {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (path.endsWith('/chat_messages/records') && request.method == 'POST') {
      createdMessage =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'id': 'message-1',
          'senderId': createdMessage!['senderId'],
          'senderName': createdMessage!['senderName'],
          'content': createdMessage!['content'],
          'created': '2026-10-07 11:00:00.000Z',
        }),
      );
      await request.response.close();
      return;
    }
    if (path.endsWith('/chat_messages/records')) {
      recordsAuthorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'page': 1,
          'perPage': 30,
          'totalItems': 0,
          'totalPages': 0,
          'items': [],
        }),
      );
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server.close(force: true);
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
