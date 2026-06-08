class ChatMessage {
  final String sender;
  final String text;
  final bool isMe;
  final String time;

  const ChatMessage({required this.sender, required this.text, this.isMe = false, required this.time});
}
