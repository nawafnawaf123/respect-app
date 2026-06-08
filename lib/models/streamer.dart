class Streamer {
  final String name;
  final String platform;
  final String url;
  final String avatarImage;
  final bool isLive;
  final int viewers;
  final String game;

  const Streamer({
    required this.name,
    required this.platform,
    required this.url,
    this.avatarImage = '',
    required this.isLive,
    required this.viewers,
    this.game = 'RP Server',
  });
}
