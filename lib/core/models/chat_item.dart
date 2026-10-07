class ChatItem {
  final String id;
  final String title;
  final DateTime created;
  final bool isPinned;
  final String? assistantId;
  final String? assistantName;

  ChatItem({
    required this.id,
    required this.title,
    required this.created,
    this.isPinned = false,
    this.assistantId,
    this.assistantName,
  });

  ChatItem copyWith({
    String? id,
    String? title,
    DateTime? created,
    bool? isPinned,
    String? assistantId,
    String? assistantName,
  }) => ChatItem(
    id: id ?? this.id,
    title: title ?? this.title,
    created: created ?? this.created,
    isPinned: isPinned ?? this.isPinned,
    assistantId: assistantId ?? this.assistantId,
    assistantName: assistantName ?? this.assistantName,
  );
}
