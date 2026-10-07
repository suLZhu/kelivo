/// A text message stored in the configured PocketBase collection.
class ChatRoomMessage {
  const ChatRoomMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.created,
  });

  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime created;

  factory ChatRoomMessage.fromJson(Map<String, dynamic> json) {
    final rawCreated = json['created'];
    final created = rawCreated is DateTime
        ? rawCreated
        : DateTime.parse(rawCreated as String);
    return ChatRoomMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      content: json['content'] as String,
      created: created,
    );
  }

  factory ChatRoomMessage.fromRecord(Map<String, dynamic> record) =>
      ChatRoomMessage.fromJson(record);

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderName': senderName,
    'content': content,
    'created': created.toIso8601String(),
  };
}
