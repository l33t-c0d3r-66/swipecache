// A pretend server for the demo: reel details, likes, comments and follows
// with realistic delays. Replace these calls with your real API.
import 'dart:math';

import 'package:swipecache/swipecache.dart';

const viewer = SwipeReelAuthor(id: 'me', name: 'you');

const _authors = [
  SwipeReelAuthor(id: 'a1', name: 'nature.daily', isVerified: true),
  SwipeReelAuthor(id: 'a2', name: 'blender_studio', isVerified: true),
  SwipeReelAuthor(id: 'a3', name: 'maria.travels'),
  SwipeReelAuthor(id: 'a4', name: 'urban_shots'),
  SwipeReelAuthor(id: 'a5', name: 'cine.lab', isVerified: true),
];

const _music = [
  SwipeReelMusic(title: 'Original audio', artist: 'nature.daily'),
  SwipeReelMusic(title: 'Sunset Drive (Extended Mix)', artist: 'Neon Waves'),
  SwipeReelMusic(title: 'Lo-fi Morning', artist: 'Chillhop Collective'),
  SwipeReelMusic(title: 'Epic Trailer Theme', artist: 'Studio Orchestra'),
];

const _captions = [
  'Golden hour hits different 🌅 #nature #reels',
  'Made entirely in Blender. Took 3 weeks to render every single frame, '
      'but it was worth it. Full breakdown on the channel! #3d #animation',
  'Which one is your favourite? 👇',
  'POV: you finally found the perfect spot 📍',
  'Testing streams, caching and sound on a real device.',
];

/// Reel details for the demo item [index] titled [title].
SwipeReelData reelFor(int index, String title) {
  final random = Random(index);
  return SwipeReelData(
    author: _authors[index % _authors.length],
    caption: '$title\n${_captions[index % _captions.length]}',
    music: _music[index % _music.length],
    likeCount: random.nextInt(250000),
    commentCount: random.nextInt(4000),
    shareCount: random.nextInt(900),
    isLiked: index % 7 == 3,
    shareUrl: 'https://example.com/reels/$index',
  );
}

Future<bool> _network() async {
  await Future<void>.delayed(const Duration(milliseconds: 350));
  return true;
}

Future<bool> like(String id, bool liked) => _network();
Future<bool> save(String id, bool saved) => _network();
Future<bool> follow(String authorId, bool following) => _network();

/// Comment pages of 15, three pages per reel.
Future<SwipeCommentPage> loadComments(String reelId, String? cursor) async {
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final page = cursor == null ? 0 : int.parse(cursor);
  final random = Random(reelId.hashCode + page);
  const texts = [
    'This is amazing 😍',
    'How did you film this?',
    'Saved for later!',
    'The music fits perfectly 🎶',
    'Underrated creator',
    'I watched it 10 times',
    'Where is this place?',
    '🔥🔥🔥',
  ];
  return SwipeCommentPage(
    [
      for (var i = 0; i < 15; i++)
        SwipeComment(
          id: '$reelId-$page-$i',
          author: _authors[random.nextInt(_authors.length)],
          text: texts[random.nextInt(texts.length)],
          createdAt: DateTime.now()
              .subtract(Duration(minutes: random.nextInt(60 * 24 * 20))),
          likeCount: random.nextInt(500),
          replyCount: random.nextInt(4) == 0 ? random.nextInt(12) + 1 : 0,
        ),
    ],
    nextCursor: page < 2 ? '${page + 1}' : null,
  );
}

Future<SwipeComment> postComment(String reelId, String text) async {
  await Future<void>.delayed(const Duration(milliseconds: 400));
  return SwipeComment(
    id: '$reelId-${DateTime.now().microsecondsSinceEpoch}',
    author: viewer,
    text: text,
    createdAt: DateTime.now(),
  );
}
