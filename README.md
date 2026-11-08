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

Requirements: Flutter 3.22 or newer. Works on **Android**, **iOS** and
**macOS**.

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

- **HLS and DASH streams** (`.m3u8` and `.mpd` addresses) play normally but are
  **not saved** yet. Regular video files (MP4, MOV, M4V) are fully supported.
- **Flutter web is not supported.** Browsers don't allow the local address
  swipecache uses.
- **Live streams** are not cached.
- **The server must support partial downloads** ("range requests") for the best
  results. Almost every video host and CDN does. If a server doesn't, videos
  still play and are saved, but jumping to the middle of a video downloads it
  from the start.
- **iOS simulator:** the simulator reports your Mac's memory and processor, so
  automatic settings behave like a high-end phone there. Real iPhones report
  their own hardware.

---

## Example app

The [`example`](example) folder contains a complete demo app: a feed of 35
public test videos with sound, paging, mute and clear-cache buttons, and a live
panel showing cache statistics and the limits in use.

```sh
cd example
flutter run
```

## License

MIT — see [LICENSE](LICENSE).
