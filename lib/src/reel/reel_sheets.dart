import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reel_data.dart';
import 'reel_widgets.dart';

/// Connects the built-in comments sheet to your backend.
class SwipeCommentsDelegate {
  const SwipeCommentsDelegate({
    required this.load,
    this.send,
    this.like,
    this.viewer,
    this.hintText = 'Add a comment…',
    this.title = 'Comments',
  });

  /// Loads a page of comments. `cursor` is `null` for the first page, then
  /// the `nextCursor` of the previous page.
  final Future<SwipeCommentPage> Function(String? cursor) load;

  /// Posts a comment and returns it as stored. `null` hides the input.
  final Future<SwipeComment> Function(String text)? send;

  /// Likes/unlikes a comment. Return `false` (or throw) to undo the change.
  final FutureOr<bool?> Function(SwipeComment comment, bool liked)? like;

  /// The signed-in user, shown next to the input.
  final SwipeReelAuthor? viewer;
  final String hintText;
  final String title;
}

/// Opens the comments sheet. [onSent] runs after a comment was posted (the
/// reel UI uses it to raise the comment count).
Future<void> showSwipeCommentsSheet(
  BuildContext context, {
  required SwipeCommentsDelegate delegate,
  int? commentCount,
  ValueChanged<SwipeComment>? onSent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SwipeCommentsSheet(
      delegate: delegate,
      commentCount: commentCount,
      onSent: onSent,
    ),
  );
}

/// The comments list with paging, likes and an input bar. Usually opened
/// with [showSwipeCommentsSheet]; can be embedded anywhere.
class SwipeCommentsSheet extends StatefulWidget {
  const SwipeCommentsSheet({
    super.key,
    required this.delegate,
    this.commentCount,
    this.onSent,
  });

  final SwipeCommentsDelegate delegate;
  final int? commentCount;
  final ValueChanged<SwipeComment>? onSent;

  @override
  State<SwipeCommentsSheet> createState() => _SwipeCommentsSheetState();
}

class _SwipeCommentsSheetState extends State<SwipeCommentsSheet> {
  final List<SwipeComment> _comments = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String? _cursor;
  bool _hasMore = true;
  bool _loading = false;
  bool _sending = false;
  Object? _error;
  int _sent = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300) unawaited(_loadMore());
    });
    _input.addListener(() => setState(() {}));
    unawaited(_loadMore());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.delegate.load(_cursor);
      if (!mounted) return;
      setState(() {
        final known = _comments.map((c) => c.id).toSet();
        _comments.addAll(page.comments.where((c) => known.add(c.id)));
        _cursor = page.nextCursor;
        _hasMore = page.nextCursor != null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final send = widget.delegate.send;
    final text = _input.text.trim();
    if (send == null || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final comment = await send(text);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _comments.insert(0, comment);
        _sent++;
      });
      widget.onSent?.call(comment);
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(0,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text("Couldn't post your comment")));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleLike(int index) async {
    final like = widget.delegate.like;
    if (like == null) return;
    final before = _comments[index];
    final liked = !before.isLiked;
    setState(() => _comments[index] = before.copyWith(
        isLiked: liked,
        likeCount: (before.likeCount + (liked ? 1 : -1)).clamp(0, 1 << 62)));
    var ok = true;
    try {
      ok = await like(before, liked) != false;
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      final at = _comments.indexWhere((c) => c.id == before.id);
      if (at >= 0) setState(() => _comments[at] = before);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.commentCount;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Text(
              count == null
                  ? widget.delegate.title
                  : '${widget.delegate.title} · ${formatSwipeCount(count + _sent)}',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(child: _buildList(theme, muted)),
            if (widget.delegate.send != null) ...[
              const Divider(height: 1),
              _buildInput(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme, Color muted) {
    if (_comments.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) {
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text("Couldn't load comments", style: TextStyle(color: muted)),
            TextButton(onPressed: _loadMore, child: const Text('Retry')),
          ]),
        );
      }
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('No comments yet',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Start the conversation.', style: TextStyle(color: muted)),
        ]),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _comments.length + (_hasMore || _error != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _comments.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: _error != null
                  ? TextButton(onPressed: _loadMore, child: const Text('Retry'))
                  : const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        final c = _comments[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwipeAvatar(author: c.author, size: 34, borderColor: null),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(c.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                      if (c.author.isVerified) ...[
                        const SizedBox(width: 3),
                        const Icon(Icons.verified,
                            size: 13, color: Color(0xFF3897F0)),
                      ],
                      if (c.createdAt != null) ...[
                        const SizedBox(width: 8),
                        Text(formatSwipeAge(c.createdAt!),
                            style: TextStyle(color: muted, fontSize: 12)),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Text(c.text, style: const TextStyle(fontSize: 14)),
                    if (c.replyCount > 0) ...[
                      const SizedBox(height: 6),
                      Text('View ${c.replyCount} more replies',
                          style: TextStyle(
                              color: muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
              if (widget.delegate.like != null)
                GestureDetector(
                  onTap: () => _toggleLike(index),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(children: [
                      Icon(c.isLiked ? Icons.favorite : Icons.favorite_border,
                          size: 16,
                          color: c.isLiked ? const Color(0xFFFF3040) : muted),
                      if (c.likeCount > 0)
                        Text(formatSwipeCount(c.likeCount),
                            style: TextStyle(color: muted, fontSize: 11)),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInput(ThemeData theme) {
    final canSend = _input.text.trim().isNotEmpty && !_sending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            SwipeAvatar(author: widget.delegate.viewer, size: 32, borderColor: null),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: widget.delegate.hintText,
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            _sending
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : TextButton(
                    onPressed: canSend ? _send : null,
                    child: const Text('Post',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
          ],
        ),
      ),
    );
  }
}

/// An entry of the share or "more" sheet.
class SwipeReelOption {
  const SwipeReelOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;

  /// Runs after the sheet has closed.
  final VoidCallback onTap;

  /// Shown in red (Report, Delete...).
  final bool isDestructive;
}

/// Share sheet: "Copy link" when [link] is given, then your [options]
/// (e.g. one that opens the system share dialog via `share_plus`).
Future<void> showSwipeShareSheet(
  BuildContext context, {
  String? link,
  List<SwipeReelOption> options = const [],
  String title = 'Share',
  String copiedMessage = 'Link copied',
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final all = [
    if (link != null)
      SwipeReelOption(
        icon: Icons.link_rounded,
        label: 'Copy link',
        onTap: () {
          unawaited(Clipboard.setData(ClipboardData(text: link)));
          messenger?.showSnackBar(SnackBar(
              content: Text(copiedMessage),
              duration: const Duration(seconds: 1)));
        },
      ),
    ...options,
  ];
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 18),
              Wrap(
                spacing: 18,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  for (final option in all)
                    SizedBox(
                      width: 72,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.of(context).pop();
                          option.onTap();
                        },
                        child: Column(children: [
                          CircleAvatar(
                            radius: 26,
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            child: Icon(option.icon,
                                color: option.isDestructive
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurface),
                          ),
                          const SizedBox(height: 6),
                          Text(option.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: const TextStyle(fontSize: 12)),
                        ]),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A list of options ("…" button): Report, Not interested, Save...
Future<void> showSwipeOptionsSheet(
  BuildContext context, {
  required List<SwipeReelOption> options,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              ListTile(
                leading: Icon(option.icon,
                    color: option.isDestructive ? theme.colorScheme.error : null),
                title: Text(option.label,
                    style: TextStyle(
                        color:
                            option.isDestructive ? theme.colorScheme.error : null)),
                onTap: () {
                  Navigator.of(context).pop();
                  option.onTap();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
