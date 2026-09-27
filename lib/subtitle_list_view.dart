import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

const double _kBottomThreshold = 48.0;
const double _kSettleEpsilon = 0.5;
const Curve _kScrollCurve = Curves.easeOut;

class SubtitleListView extends StatefulWidget {
  const SubtitleListView({
    super.key,
    required this.texts,
    required this.speakingIndex,
    required this.onTapItem,
  });

  /// Subtitle source. Callers may mutate the same List instance in place.
  final List<String> texts;

  /// Index of the item currently being spoken. Null when nothing is playing.
  final int? speakingIndex;

  /// Item tap callback. Receives the tapped index as-is.
  final ValueChanged<int> onTapItem;

  /// Duration of the auto-scroll animation.
  static const Duration scrollAnimationDuration = Duration(milliseconds: 300);

  @override
  State<SubtitleListView> createState() => _SubtitleListViewState();
}

class _SubtitleListViewState extends State<SubtitleListView> {
  late final ScrollController _controller;
  bool _autoScroll = true;
  bool _userDriven = false;
  bool _pending = false;
  late int _lastItemCount;
  int _generation = 0;
  // Target of the auto-scroll animation in flight, null when none is running.
  double? _animTarget;

  bool _isAtBottom(ScrollMetrics m) => m.extentAfter <= _kBottomThreshold;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _lastItemCount = widget.texts.length;
    if (_lastItemCount > 0) _scheduleAutoScroll();
  }

  @override
  void didUpdateWidget(SubtitleListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.texts.length;
    // Callers mutate the same List in place, so oldWidget.texts.length would
    // always equal the new length. _lastItemCount is stored by value instead.
    if (count < _lastItemCount) {
      _autoScroll = true;
      _userDriven = false;
    }
    final grew = count > _lastItemCount;
    _lastItemCount = count;
    if (grew) _scheduleAutoScroll();
  }

  void _scheduleAutoScroll() {
    if (!_autoScroll) return;
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!mounted) return;
      if (!_controller.hasClients) return;
      if (!_autoScroll) return;
      final target = _controller.position.maxScrollExtent;
      if (_controller.position.extentAfter <= _kSettleEpsilon) return;
      _userDriven = false;
      _generation++;
      final myGeneration = _generation;
      _animTarget = target;
      _controller
          .animateTo(
            target,
            duration: SubtitleListView.scrollAnimationDuration,
            curve: _kScrollCurve,
          )
          .whenComplete(() {
            if (!mounted) return;
            if (myGeneration != _generation) return;
            _animTarget = null;
            if (!_controller.hasClients) return;
            // Stopped short of the target: a touch interrupted it. Don't
            // restart from here. A new subtitle still schedules a fresh
            // animation even while a finger rests near the bottom.
            if (_controller.position.pixels < target - _kSettleEpsilon) return;
            // Only re-correct if maxScrollExtent grew after landing — that is
            // the stale-target case, not merely "not perfectly at the bottom".
            if (_controller.position.maxScrollExtent >
                target + _kSettleEpsilon) {
              _scheduleAutoScroll();
            }
          });
    });
  }

  bool _onNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      // Idle is ignored: animateTo's completion also fires idle.
      if (notification.direction != ScrollDirection.idle) {
        _userDriven = true;
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        _userDriven = true;
      }
      if (_userDriven && _autoScroll && !_isAtBottom(notification.metrics)) {
        _autoScroll = false;
      }
    } else if (notification is ScrollEndNotification) {
      if (_userDriven) {
        _autoScroll = _isAtBottom(notification.metrics);
        _userDriven = false;
      } else if (_animTarget != null &&
          notification.metrics.pixels < _animTarget! - _kSettleEpsilon) {
        // Our animation ended short of its target with no drag: a touch
        // stopped it (hold). A normal landing ends at the target, and one
        // animation replacing another emits no ScrollEnd, so neither gets here.
        _autoScroll = _isAtBottom(notification.metrics);
      }
    }
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      // The list scrolls itself instead of being laid out whole inside
      // a SingleChildScrollView. shrinkWrap forced every subtitle to be
      // measured on every frame, so the cost grew with the transcript;
      // this builds only what is on screen. Same box, same scrolling.
      child: ListView.builder(
        controller: _controller,
        itemCount: widget.texts.length,
        itemBuilder:
            (context, index) => ListTile(
              title: Text('‣ ${widget.texts[index]}'),
              trailing: Icon(
                widget.speakingIndex == index ? Icons.stop : Icons.play_arrow,
              ),
              onTap: () => widget.onTapItem(index),
            ),
      ),
    );
  }
}
