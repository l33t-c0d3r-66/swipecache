# swipecache

A Flutter package for building **short video feeds** — the full-screen,
swipe-up-for-the-next-video screens you know from TikTok, Instagram Reels and
YouTube Shorts.

swipecache plays videos **instantly**, **saves them on the phone while they
play** so they never download twice, and **adjusts itself to the phone and the
internet speed** so it runs smoothly on cheap and expensive phones alike.

```dart
SwipeFeed(controller: controller) // a complete, swipeable video feed
```

---

## Table of contents

- [The problem with existing solutions](#the-problem-with-existing-solutions)
- [What swipecache does](#what-swipecache-does)
- [Installation](#installation)
- [Usage](#usage)
  - [Quick start (automatic settings)](#quick-start-automatic-settings)
  - [Your own settings](#your-own-settings)
  - [Reel UI: like, comment, share, save](#reel-ui-like-comment-share-save)
  - [Common tasks](#common-tasks)
  - [Using only the cache](#using-only-the-cache)
- [Cleanup](#cleanup)
- [Limitations](#limitations)
- [Example app](#example-app)
- [License](#license)

---

## The problem with existing solutions

Most Flutter apps build a video feed with the `video_player` package plus one of
these two approaches. Both have real problems:

**1. Play straight from the internet**

- Every time a video is watched again, it is **downloaded again**. This wastes
  the user's mobile data and your server bandwidth.
- Nothing is saved, so nothing works offline.

**2. Download the whole file first, then play it**
(for example `flutter_cache_manager` + `VideoPlayerController.file`)

- The user stares at a **loading spinner** until the *entire* video has
  downloaded — seconds of waiting on every new video.
- Videos the user swipes past are still downloaded completely, which **wastes
  data**.

**Other common problems in hand-made feeds:**

- **A spinner on every swipe**, because the next video only starts loading when
  it appears on screen.
- **Two videos playing sound at the same time**, or sound continuing after the
  user left the screen.
- **Crashes** like *"A VideoPlayerController was used after being disposed"*
  when the user swipes fast.
- **Too many videos loaded at once**, which makes cheaper Android phones run out
  of video decoders or memory.
- **The cache grows forever**, filling the user's storage.
- **Fixed settings** that are fine on a new iPhone on Wi-Fi but terrible on an
  old Android phone on slow mobile data.

## What swipecache does

| Feature | What it means for your users |
|---|---|
| **Plays while it saves** | Videos start as fast as normal streaming. While a video plays, it is saved on the phone at the same time, so watching it again uses no data. |
| **Saves only what is needed** | If a user watches half a video, only that half is saved. Nothing is downloaded twice. |
| **Loads the next videos early** | The next video is ready before the user swipes, so swiping feels instant. Only the first part of upcoming videos is downloaded, not the whole file. |
| **Ready-made reel UI** | Instagram- or TikTok-style buttons (like, comment, share, save, more), author, caption, music, double-tap heart, tap to mute and hold to pause. Every part can be changed or replaced, and every action has a callback. |
| **HLS and DASH too** | Streaming playlists (`.m3u8`, `.mpd`) are saved just like normal video files: every piece of the video is kept, so watching again is instant and works offline. Live streams play normally and are never saved. |
| **Works with any server** | Even servers that can only send a whole file at once are handled: the file is downloaded once and kept, never downloaded again for each jump in the video. |
| **Smart about slow-starting files** | Some MP4 files (common for user uploads) can't start until the end of the file is loaded. swipecache detects these and loads the right part early. |
| **One sound at a time** | Exactly one video plays. Sound stops when the user swipes away, leaves the screen or puts the app in the background. |
| **No "disposed" crashes** | Video players are created and destroyed safely, no matter how fast the user swipes. |
| **Recovers by itself** | If the network drops or a video fails, it retries automatically from the same spot. |
| **Automatic settings** | By default, swipecache looks at the phone (memory and processor) and the real internet speed, and picks safe limits for that phone. |
| **Your settings are respected** | Any limit you set yourself is followed exactly. The automatic system never changes it. |
| **Cleans up after itself** | Old videos are deleted automatically, so the cache never fills the phone. |
| **Honest statistics** | See how much was played from the cache, how much was downloaded, and which limits are in use. |

---

## Installation

### 1. Add the package

```yaml
dependencies:
  swipecache: ^0.1.0
```

Then run:

```sh
flutter pub get
```

Requirements: Flutter 3.22 or newer. Works on **Android**, **iOS**, **macOS**
and **web** (on the web videos play normally but are not saved — see
[Limitations](#limitations)).

### 2. Allow local video playback (one-time setup)

swipecache gives the video player a local address on the phone
(`http://127.0.0.1`) to read saved videos from. The phone must allow this.

> If you skip this step, videos still play, but they are **not saved** — you
> lose the cache.

**Android** — create the file
`android/app/src/main/res/xml/network_security_config.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

Then point to it in `android/app/src/main/AndroidManifest.xml`, and make sure
the internet permission is there:

```xml
<manifest ...>
    <uses-permission android:name="android.permission.INTERNET"/>

    <application
        android:networkSecurityConfig="@xml/network_security_config"
        ...>
```

**iOS and macOS** — add this to `ios/Runner/Info.plist`
(and `macos/Runner/Info.plist` for macOS):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

---

## Usage

### Quick start (automatic settings)

This is all you need. swipecache chooses every limit for you, based on the
user's phone and internet speed. **This is the recommended setup.**

**Step 1 — start the cache once, in `main()`:**

```dart
import 'package:flutter/material.dart';
import 'package:swipecache/swipecache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SwipeCache.instance.init(); // automatic settings
  runApp(const MaterialApp(home: FeedPage()));
}
```

**Step 2 — show a feed:**

```dart
class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  late final SwipeFeedController controller = SwipeFeedController(
    sources: const [
      SwipeSource(id: '1', url: 'https://example.com/video1.mp4'),
      SwipeSource(id: '2', url: 'https://example.com/video2.mp4'),
      SwipeSource(id: '3', url: 'https://example.com/video3.mp4'),
    ],
  );

  @override
  void dispose() {
    controller.dispose(); // always dispose the controller
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SwipeFeed(controller: controller),
    );
  }
}
```

That's it. You now have a feed where:

- swiping up/down changes the video,
- tapping pauses and resumes,
- the next video is already loaded,
- every video is saved while it plays.

**What "automatic" picks for you:**

| Setting | Cheaper phones | Mid-range phones | High-end phones |
|---|---|---|---|
| Space used for saved videos | 200 MB | 400 MB | 800 MB |
| Number of videos kept | 60 | 120 | 250 |
| How long videos are kept | 3 days | 7 days | 14 days |
| Downloads at the same time | 1–2 | 1–3 | 1–4 |
| Videos ready ahead of the current one | 1 | 1 | 2 (1 on slow internet) |
| Videos kept ready behind the current one | 0 | 1 | 1 |

- A **cheaper phone** has less than about 3 GB of memory or 4 processor cores or
  fewer. A **high-end phone** has 6 GB or more and at least 6 cores. Everything
  else counts as **mid-range**.
- The internet speed is **measured from real downloads**, not guessed from
  "Wi-Fi" or "mobile data", and it is re-checked while the app runs. On slow
  internet, swipecache downloads less at once; on fast internet, it downloads
  more.
- If the phone's storage runs full, the automatic space limit shrinks by
  itself.

### Your own settings

Sometimes you want control — for example, your app must never use more than
300 MB, or your videos are long and you want fewer of them kept.

You can set **any** limit yourself and leave the others on automatic. **A limit
you set is always followed exactly**, on every phone and every internet speed.

#### Cache settings — set once in `main()`

```dart
await SwipeCache.instance.init(
  config: const SwipeCacheConfig(
    maxCacheBytes: 300 * 1024 * 1024, // 300 MB
    maxCachedVideos: 50,
    maxAge: Duration(days: 2),
    maxConcurrentDownloads: 2,
  ),
);
```

| Setting | What it controls | Why you might set it |
|---|---|---|
| `maxCacheBytes` | The most storage space saved videos may use. | Keep your app's storage size predictable, for example to stay under a size your users expect. |
| `maxCachedVideos` | The most videos kept on the phone. | Useful when your videos are large: fewer videos, each kept fully. Or the opposite for tiny clips. |
| `maxAge` | How long a video is kept after it was last watched. | Your content changes daily? Keep videos 1 day. Users re-watch favourites? Keep them longer. |
| `maxConcurrentDownloads` | How many videos are downloaded in the background at the same time. | Lower it to save data and battery. Raise it if your users are mostly on fast Wi-Fi. The video being watched is never slowed down by these background downloads. |

#### Feed settings — set per feed

```dart
final controller = SwipeFeedController(
  sources: mySources,
  config: const SwipeFeedConfig(
    preloadAhead: 1,
    preloadBehind: 1,
    prefetchAhead: 3,
    prefetchHeadBytes: 1024 * 1024, // 1 MB of each upcoming video
  ),
);
```

| Setting | What it controls | Why you might set it |
|---|---|---|
| `preloadAhead` | How many next videos are fully loaded and ready to play. | Higher = swiping feels even more instant, but uses more memory. Keep it at 1–2. |
| `preloadBehind` | How many previous videos stay ready. | Set to 0 to save memory if users rarely swipe back. |
| `prefetchAhead` | How many upcoming videos get their first part downloaded early. | Higher = smoother long swiping sessions, but more data used on videos the user may skip. |
| `prefetchHeadBytes` | How much of each upcoming video is downloaded early. | Larger = fewer chances of a short wait at the start; smaller = less data used. |

Other feed options you can change (these have fixed defaults):

| Setting | Default | What it does |
|---|---|---|
| `looping` | `true` | Restart the video when it ends. |
| `autoplay` | `true` | Start playing as soon as a video is on screen. |
| `restartOnLeave` | `true` | When the user comes back to a video, start it from the beginning. |
| `mixWithOthers` | `false` | `true` lets music from other apps keep playing alongside your videos. |
| `loadMoreThreshold` | `3` | How close to the end of the list the feed asks for more videos. |
| `releaseWhenHidden` | `true` | Free memory when the feed is hidden behind another screen. |

> **Tip:** to see the limits being used right now — automatic or yours — read
> `SwipeCache.instance.stats.limits` or `controller.limits`. The `autoFields`
> list tells you which ones were picked automatically.

### Reel UI: like, comment, share, save

swipecache includes the screen elements people know from Instagram Reels and
TikTok. Turn them on with `reel:` and you get:

- a **button column** on the right: like ♥, comment, share, save, more (…)
  and a spinning music disc;
- the **author** (picture, name, verified badge, Follow button), the
  **caption** (with "more", tappable `#hashtags` and `@mentions`) and the
  **song** at the bottom;
- **gestures**: tap to mute/unmute (with a speaker icon, like Instagram),
  double-tap to like (with a big heart), hold to pause (the buttons hide
  while holding);
- a **seek bar** at the bottom that you can drag (it shows the time while
  dragging);
- ready-made **sheets** for comments, sharing (with "Copy link") and the "…"
  menu.

#### 1. Add the reel details to each video

```dart
SwipeSource(
  id: reel.id,
  url: reel.videoUrl,
  reel: SwipeReelData(
    author: SwipeReelAuthor(
      id: reel.userId,
      name: reel.username,
      avatarUrl: reel.userPhoto, // initials are shown if missing
      isVerified: reel.verified,
      isFollowing: reel.following,
    ),
    caption: reel.caption,
    music: SwipeReelMusic(title: reel.songTitle, artist: reel.songArtist),
    likeCount: reel.likes,
    commentCount: reel.comments,
    shareCount: reel.shares,
    isLiked: reel.likedByMe,
    isSaved: reel.savedByMe,
    shareUrl: reel.webLink, // enables "Copy link"
  ),
)
```

#### 2. Turn on the UI and connect your server

```dart
SwipeFeed(
  controller: controller,
  header: SwipeReelTopBar(onCamera: openCamera), // "Reels" title + camera
  reel: SwipeReelOptions(
    onLike: (item, liked) => api.like(item.source.id, liked),
    onSave: (item, saved) => api.save(item.source.id, saved),
    onFollow: (item, following) => api.follow(item.reel.author!.id!, following),
    comments: (item) => SwipeCommentsDelegate(
      load: (cursor) => api.comments(item.source.id, cursor), // pages
      send: (text) => api.addComment(item.source.id, text),
      like: (comment, liked) => api.likeComment(comment.id, liked),
    ),
    onShare: (item) => Share.share(item.reel.shareUrl!), // e.g. share_plus
    moreOptions: (item) => [
      SwipeReelOption(icon: Icons.flag_outlined, label: 'Report',
          isDestructive: true, onTap: () => report(item.source.id)),
    ],
  ),
)
```

**Like, save and follow change on screen immediately.** Your callback then
talks to the server. If it returns `false` or throws an error, the change is
undone automatically, so the screen always matches the server.

#### All callbacks

| Callback | When it runs |
|---|---|
| `onLike(item, liked)` | Heart tapped or video double-tapped. |
| `onSave(item, saved)` | Bookmark tapped. |
| `onFollow(item, following)` | Follow button (TikTok: the "+" on the avatar). |
| `onComment(item)` | Comment button, if you have your own comments screen. |
| `comments: (item) => SwipeCommentsDelegate(...)` | Comment button, using the built-in comments sheet. |
| `onShare(item)` | Share button, if you have your own share action. |
| `shareOptions: (item) => [...]` | Extra entries in the built-in share sheet. |
| `onMore(item)` / `moreOptions: (item) => [...]` | "…" button: your own action or the built-in menu. |
| `onAuthorTap(item)` | Author picture or name. |
| `onMusicTap(item)` | Song name or music disc. |
| `onHashtagTap(item, tag)` / `onMentionTap(item, user)` | A `#tag` or `@user` in the caption. |
| `onEvent(event)` | **Every** action above, plus mute, unmute, pause, resume, hold-to-speed-up, seek and double-tap. One place for analytics. |

A button only appears when it can do something: the comment button needs
`onComment` or `comments`, share needs `onShare`, `shareOptions` or a
`shareUrl`, and "…" needs `onMore` or `moreOptions`. Like and save always
show.

#### Instagram or TikTok look

```dart
reel: SwipeReelOptions(theme: SwipeReelTheme.instagram()) // default
reel: SwipeReelOptions(theme: SwipeReelTheme.tiktok())     // solid icons, "+" on avatar
header: SwipeReelTopBar(style: SwipeReelStyle.tiktok, onSearch: openSearch)
```

#### Pausing, holding and seeking

Instagram and TikTok handle pausing differently, so you choose:

| | Instagram (default) | TikTok |
|---|---|---|
| Tap the video | Mute / unmute | Pause / play (a big ▶ appears) |
| Hold the video | Pause while holding, buttons hide | Hold the sides: play at 2×. Hold the middle: open the "…" menu |
| Settings | (nothing to set) | `tapAction: SwipeTapAction.pause`, `holdEdgesToSpeedUp: true`, `holdAction: SwipeHoldAction.menu` |

Other options:

- `holdAction`: `pause`, `speedUp` (2× while holding), `menu` or `none`.
- `holdSpeed`: the speed while holding, e.g. `1.5`.
- `showSeekBar: false` hides the progress bar. It is thin while playing,
  thicker while paused, and can be dragged in both styles.
- Pausing in code: `controller.pause()`, `controller.play()`,
  `controller.togglePlay()`. A paused video starts again when the user swipes
  to the next one, like in both apps.
- Speed for all videos: `controller.setPlaybackSpeed(1.5)`. For a "Playback
  speed" menu entry, call `showSwipeSpeedSheet(context, current:
  controller.playbackSpeed, onSelected: controller.setPlaybackSpeed)`.
- The pieces work on their own too: `SwipeSeekBar`,
  `SwipePausedIndicator` and `SwipeSpeedBadge`.

#### Change or replace anything

| You want to… | Use |
|---|---|
| Change colours or sizes | `theme: SwipeReelTheme.instagram(likeColor: Colors.pink, iconSize: 30)` |
| Use other icons | `theme: SwipeReelTheme(icons: SwipeReelIcons.material)`, or `SwipeReelIcons.instagram.copyWith(share: ...)` |
| Reorder buttons or remove some | `actions: [SwipeReelAction.like, SwipeReelAction.share]` |
| Add your own button | `SwipeReelAction.custom(icon: Icons.card_giftcard, label: 'Gift', onTap: (item) => ...)` |
| Put any widget in the button column | `SwipeReelAction.widget((context, item) => MyWidget())` |
| Replace or wrap one button | `actionBuilder: (context, item, type, button, actions) => type == SwipeReelActionType.save ? MySaveButton(onTap: actions.toggleSave) : button` |
| Replace the author, caption or music line | `authorBuilder`, `captionBuilder`, `musicBuilder` |
| Replace the whole button column | `actionsBuilder` |
| Add something under the caption (product card, tags) | `bottomBuilder` |
| Add your own widgets on top of everything | `overlayBuilder` (works together with `reel:`) |

Every builder gets `actions`. It runs the built-in behaviour from your own
widgets, including the instant update and automatic undo: `actions.toggleLike()`,
`actions.toggleSave()`, `actions.toggleFollow()`, `actions.openComments(context)`,
`actions.share(context)`, `actions.openMore(context)`.

To build a completely different screen, leave `reel:` out and use the pieces
in your own `overlayBuilder`: `SwipeActionButton`, `SwipeReelIcon`,
`SwipeAvatar`, `SwipeAuthorRow`, `SwipeFollowAvatar`, `SwipeCaption`,
`SwipeMusicRow`, `SwipeMusicDisc`, `SwipeHeartBurst`, `SwipeReelTopBar`,
`showSwipeCommentsSheet`, `showSwipeShareSheet` and `showSwipeOptionsSheet`.

> **Tip:** for your own buttons on top of the video, wrap them in
> `SwipeTapTarget` (or use normal Flutter buttons). They react immediately,
> even though the video also listens for double taps.

To change a reel's numbers from elsewhere, for example after a comment
was posted on another screen:

```dart
controller.updateReel(reelId, (r) => r.copyWith(commentCount: r.commentCount + 1));
```

### Common tasks

#### Load more videos when the user reaches the end

```dart
late final SwipeFeedController controller = SwipeFeedController(
  sources: firstPage,
  onLoadMore: () async {
    final nextPage = await api.fetchNextPage();
    controller.hasMore = nextPage.isNotEmpty; // false = stop asking
    controller.appendSources(nextPage);
  },
);
```

#### Show your own buttons and text on top of each video

Use `SwipeSource.data` to attach your own object (for example your `Reel`
model), then read it back in `overlayBuilder`:

```dart
SwipeSource(
  id: reel.id,
  url: reel.videoUrl,
  thumbnailUrl: reel.thumbnailUrl, // shown until the video is ready
  data: reel,
);

SwipeFeed(
  controller: controller,
  overlayBuilder: (context, item) {
    final reel = item.source.data as Reel;
    return Positioned(
      left: 16,
      bottom: 32,
      child: Text(reel.caption, style: const TextStyle(color: Colors.white)),
    );
  },
  onDoubleTap: (item, details) => likeReel(item.source.data as Reel),
);
```

#### Pause the feed when it's not on screen

When the user switches to another tab or opens another page, tell the
controller, so no sound plays in the background:

```dart
controller.setVisible(false); // feed hidden
controller.setVisible(true);  // feed visible again
```

App background/foreground is handled for you automatically.

#### Other useful controls

```dart
controller.setMuted(true);   // mute / unmute all videos
controller.togglePlay();     // pause / resume the current video
controller.jumpTo(5);        // go to a video
controller.setSources(list); // replace the whole list (e.g. pull-to-refresh)
```

`SwipeFeed` also accepts `placeholderBuilder`, `errorBuilder`,
`bufferingBuilder`, `emptyBuilder`, `onRefresh` (pull-to-refresh) and
`showProgress` (a thin progress bar) to customise the look.

#### Streaming videos (HLS and DASH)

Nothing to do: addresses ending in `.m3u8` (HLS) or `.mpd` (DASH) are
recognised and saved automatically. If your stream address has no such ending,
tell swipecache what it is:

```dart
SwipeSource(
  id: 'live-42',
  url: 'https://example.com/play?id=42', // an HLS playlist
  formatHint: VideoFormat.hls, // from package:video_player
)
```

What happens behind the scenes:

- Normal (on-demand) streams are saved piece by piece while they play. All
  pieces of one stream count as **one video** for your limits and are deleted
  together.
- Before a stream is shown, its playlist and first pieces are loaded early,
  for the same quality the player will start with.
- Live streams always load the newest playlist and are never saved.
- Encryption keys of protected streams are never saved on the phone.

### Using only the cache

Already have your own video player screen? You can use just the caching part
with any `video_player` code:

```dart
final controller = VideoPlayerController.networkUrl(
  SwipeCache.instance.playableUri(videoUrl),
);

// Download the start of the next videos early:
SwipeCache.instance.prefetch([nextUrl, secondNextUrl]);
```

If the cache is not ready or fails for any reason, `playableUri` simply returns
the normal internet address, so **playback never breaks because of the
cache**.

---

## Cleanup

swipecache keeps the phone's storage and memory under control by itself. You
don't need to do anything, but here is what happens:

- **Old videos are deleted.** Videos older than the time limit (`maxAge`) are
  removed. This check runs every 30 seconds while the app is open — not just
  when the app starts.
- **The cache never goes over its limits.** When the space limit
  (`maxCacheBytes`) or the video limit (`maxCachedVideos`) is reached, the
  videos watched longest ago are deleted first.
- **Videos on screen are protected.** The video being watched and the ones
  around it are never deleted while in use.
- **Memory stays low.** Only a few videos are loaded into players at any time.
  Unused files are closed, so long scrolling sessions don't slow the app down
  or crash it. Thumbnails are loaded at screen size, not full size.
- **Background and low memory.** When the app goes to the background or the
  phone runs low on memory, background downloads stop and resources are
  released.
- **Full storage.** If the phone's storage is full, swipecache deletes some
  saved videos instead of failing.

You can also clean up manually:

```dart
await SwipeCache.instance.clear();   // delete all saved videos (except the one playing)
await SwipeCache.instance.trimNow(); // apply the limits right now

print(SwipeCache.instance.stats);    // hit ratio, storage used, downloads, limits
```

---

## Limitations

- **DASH does not play on iOS.** Apple's video player only supports HLS, so
  this is true for every Flutter video package. Serve HLS to iPhones (most
  video platforms provide both).
- **On the web, videos are not saved.** Browsers don't allow the trick
  swipecache uses to save videos, so they play directly from the internet (the
  browser's own cache still helps). Browsers also block sound until the user
  taps the page; swipecache then starts the video muted instead of failing.
- **Live streams are not saved**, on purpose: a live video is watched once.
- **Protected streams need the internet to replay.** The video pieces are
  saved, but the decryption key is fetched again each time, for safety. DRM
  systems (FairPlay, Widevine) are not supported by Flutter's video player.
- **Smooth Streaming** (`VideoFormat.ss`) plays normally but is not saved.
- **HLS early loading makes a guess.** swipecache loads the start of the
  quality the player is expected to pick. On Android the player may choose a
  different quality on a very fast or slow connection; then the first second
  of that quality is downloaded during playback instead. For DASH, only the
  manifest is loaded early; the video itself is saved while it plays.
- **Servers without partial downloads** ("range requests"): videos play and
  are downloaded only once, but jumping far ahead in a video that is not
  saved yet waits until the download reaches that point.

---

## Example app

The [`example`](example) folder contains a complete demo app: a feed of
public test videos with sound (HLS, live HLS, DASH and MP4), paging, mute and clear-cache buttons, and a live
panel showing cache statistics and the limits in use.

```sh
cd example
flutter run
```

It also has a device test that plays every stream type (HLS, live HLS, DASH,
MP4) on the real phone player and checks that videos are saved and replayed
from the cache:

```sh
cd example
flutter test integration_test/streams_test.dart
```

## License

MIT — see [LICENSE](LICENSE).
