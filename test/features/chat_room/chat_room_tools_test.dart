import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat_room/services/chat_room_tools.dart';

void main() {
  test('chat room tools expose only model-owned arguments', () {
    expect(ChatRoomTools.names, {
      ChatRoomTools.readName,
      ChatRoomTools.sendName,
    });

    final byName = {
      for (final definition in ChatRoomTools.definitions)
        (definition['function'] as Map<String, dynamic>)['name'] as String:
            definition['function'] as Map<String, dynamic>,
    };
    expect(byName.keys, unorderedEquals(ChatRoomTools.names));

    final readParameters =
        byName[ChatRoomTools.readName]!['parameters'] as Map<String, dynamic>;
    expect(
      (readParameters['properties'] as Map<String, dynamic>).keys,
      ['limit'],
    );

    final sendParameters =
        byName[ChatRoomTools.sendName]!['parameters'] as Map<String, dynamic>;
    expect(
      (sendParameters['properties'] as Map<String, dynamic>).keys,
      ['content'],
    );
    expect(sendParameters['required'], ['content']);
  });
}
