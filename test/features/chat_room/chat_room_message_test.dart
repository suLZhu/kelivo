import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/features/chat_room/models/chat_room_message.dart';
import 'package:Kelivo/features/chat_room/services/pocketbase_chat_service.dart';

void main() {
  group('ChatRoomMessage', () {
    test('parses PocketBase record fields', () {
      final message = ChatRoomMessage.fromJson({
        'id': 'record-1',
        'senderId': 'user',
        'senderName': '用户',
        'content': '你好',
        'created': '2026-10-07 10:20:30.000Z',
      });

      expect(message.id, 'record-1');
      expect(message.senderId, 'user');
      expect(message.senderName, '用户');
      expect(message.content, '你好');
      expect(message.created, DateTime.utc(2026, 10, 7, 10, 20, 30));
    });
  });

  group('PocketBaseChatService', () {
    final earlier = ChatRoomMessage(
      id: 'b',
      senderId: 'user',
      senderName: '用户',
      content: 'earlier',
      created: DateTime.utc(2026, 10, 7, 10),
    );
    final later = ChatRoomMessage(
      id: 'a',
      senderId: 'yan',
      senderName: '小晏',
      content: 'later',
      created: DateTime.utc(2026, 10, 7, 11),
    );

    test('sorts history in created ascending order', () {
      expect(PocketBaseChatService.sortMessages([later, earlier]), [
        earlier,
        later,
      ]);
    });

    test('merges history and realtime events without duplicate IDs', () {
      final duplicate = ChatRoomMessage(
        id: earlier.id,
        senderId: earlier.senderId,
        senderName: earlier.senderName,
        content: 'duplicate event',
        created: earlier.created,
      );

      final merged = PocketBaseChatService.mergeUniqueMessages(
        [later, earlier],
        [duplicate, later],
      );

      expect(merged, [earlier, later]);
      expect(merged.map((message) => message.id).toSet(), {'a', 'b'});
    });
  });
}
