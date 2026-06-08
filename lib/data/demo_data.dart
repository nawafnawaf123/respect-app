import '../models/post.dart';
import '../models/streamer.dart';
import '../models/message.dart';

const demoPosts = <Post>[
  Post(
    user: 'Hawk City',
    tag: '@hawkcity',
    avatarUrl: 'assets/avatars/hawk.png',
    text: 'افتتاح موسم جديد الليلة 🔥 جهزوا شخصياتكم وادخلوا الرول بلاي بقوة.',
    likes: 340, comments: 41, time: '2m',
  ),
  Post(
    user: 'Police RP',
    tag: '@police',
    avatarUrl: 'assets/avatars/police.png',
    text: 'تم فتح التقديم على الشرطة. الالتزام بالقوانين شرط أساسي.',
    likes: 122, comments: 18, time: '15m',
  ),
  Post(
    user: 'EMS Team',
    tag: '@ems',
    avatarUrl: 'assets/avatars/ems.png',
    text: 'نحتاج مسعفين جدد للمدينة. الي مهتم يتواصل مع الإدارة.',
    likes: 89, comments: 7, time: '1h',
  ),
  Post(
    user: 'RPGirl',
    tag: '@rpqueen',
    avatarUrl: 'assets/avatars/girl.png',
    text: 'اليوم سويت أروع مشهد تحقيق في المخفر، متحمسة للبارت القادم!',
    likes: 215, comments: 32, time: '45m',
  ),
];

const demoStreamers = <Streamer>[
  Streamer(
    name: 'Nawaf RP',
    platform: 'Kick',
    url: 'https://kick.com/',
    avatarImage: 'assets/streamers/nawaf.png',
    isLive: true,
    viewers: 524,
    game: 'FiveM City RP',
  ),
  Streamer(
    name: 'HawkLive',
    platform: 'Twitch',
    url: 'https://twitch.tv/',
    avatarImage: 'assets/streamers/hawk.png',
    isLive: true,
    viewers: 231,
    game: 'GTA V Roleplay',
  ),
  Streamer(
    name: 'City Stories',
    platform: 'Kick',
    url: 'https://kick.com/',
    avatarImage: 'assets/streamers/city.png',
    isLive: false,
    viewers: 0,
  ),
  Streamer(
    name: 'Roleplay Pro',
    platform: 'Twitch',
    url: 'https://twitch.tv/',
    avatarImage: 'assets/streamers/pro.png',
    isLive: false,
    viewers: 0,
  ),
];

List<ChatMessage> demoMessages = [
  ChatMessage(sender: 'أبو فيصل', text: 'يا شباب متى الأجتماع القادم؟', time: '10:15'),
  ChatMessage(sender: 'أنت', text: 'بعد صلاة العشاء إن شاء الله', isMe: true, time: '10:16'),
  ChatMessage(sender: 'Nawaf', text: 'أنا جاهز 👍', time: '10:17'),
  ChatMessage(sender: 'أنت', text: 'خلونا نعدل على لائحة الشرطة', isMe: true, time: '10:18'),
];
