class Post {
  final String user;
  final String tag;
  final String avatarUrl;
  final String text;
  final int likes;
  final int comments;
  final String time;

  const Post({
    required this.user,
    required this.tag,
    this.avatarUrl = '',
    required this.text,
    required this.likes,
    required this.comments,
    required this.time,
  });
}
