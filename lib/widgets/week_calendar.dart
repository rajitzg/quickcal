import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../logic/calendar_layout.dart';
import '../logic/task_views.dart';
import '../models/task.dart';

/// Pointer devices that drag calendar items. Trackpads are excluded so
/// two-finger scrolling over an item still scrolls the calendar.
const _dragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// Fingers: items are picked up with a long press instead (a plain drag
/// scrolls), and sideways swipes change pages.
const _touch = {PointerDeviceKind.touch};

enum _Mode { move, resizeTop, resizeBottom, create, drop }

class _DragOp {
  _DragOp(this.mode, {this.item, this.anchorDay = 0, this.anchorMin = 0});

  final _Mode mode;
  final CalItem? item;
  final int anchorDay;
  final double anchorMin;

  /// Current preview.
  int day = 0;
  DateTime? start;
  DateTime? end;
  Task? task; // for drops from the task list

  /// A moved block is being dragged out of the calendar (to unschedule it).
  bool outside = false;

  /// Shortest block drawn on empty space, in minutes. A long press with a
  /// finger (no drag) makes an hour-long block.
  double minCreate = 15;
}

/// A scrollable day/week time grid in the style of Notion Calendar.
///
/// - Drag an editable item to move it (across days too); drag its top or
///   bottom edge to change its length. Everything snaps to 15 minutes.
/// - Drag on empty space to create a new block ([onCreate]).
/// - Drop a [Task] from a `Draggable<Task>` to schedule it ([onDropTask]).
/// - Drag a block out past the left edge (onto the task list) to remove
///   it: [onDragOutside] reports where it is, [onDropOutside] the drop.
/// - Swipe sideways (trackpad, or a horizontal scroll wheel) to page to the
///   previous/next range: the grid follows the fingers and snaps to a page,
///   then [onSwipe] reports the direction. Needs [prevDays] and [nextDays]
///   (pages of the same length as [days]) so the neighbours can be drawn.
class WeekCalendar extends StatefulWidget {
  const WeekCalendar({
    super.key,
    required this.days,
    this.prevDays = const [],
    this.nextDays = const [],
    required this.items,
    required this.allDayItems,
    required this.onChanged,
    required this.onCreate,
    required this.onDropTask,
    required this.colorForTask,
    this.selectedId,
    this.onSelect,
    this.onOpen,
    this.onContextMenu,
    this.onSwipe,
    this.snapToDays = false,
    this.onScrollDays,
    this.onDragOutside,
    this.onDropOutside,
    this.hourHeight = 48,
    this.dropDuration = const Duration(hours: 1),
    this.now,
  });

  /// The visible days.
  final List<DateTime> days;

  /// The pages before and after [days], shown while swiping.
  final List<DateTime> prevDays;
  final List<DateTime> nextDays;

  /// Items for [prevDays], [days] and [nextDays].
  final List<CalItem> items;
  final List<CalItem> allDayItems;
  final String? selectedId;

  final void Function(CalItem item, DateTime start, DateTime end) onChanged;
  final void Function(DateTime start, DateTime end) onCreate;
  final void Function(Task task, DateTime start, DateTime end) onDropTask;
  final int Function(Task task) colorForTask;

  /// Called with null when empty space is clicked.
  final void Function(CalItem? item)? onSelect;

  /// Double-click.
  final void Function(CalItem item)? onOpen;

  /// Right-click.
  final void Function(CalItem item, Offset globalPosition)? onContextMenu;

  /// -1 for previous, +1 for next.
  final void Function(int direction)? onSwipe;

  /// Swipes and wheel scrolling snap to whole days (up to a page at a
  /// time) instead of whole pages; [onScrollDays] reports how many days
  /// (negative: earlier). The previous/next pages must then be the days
  /// right before and after [days].
  final bool snapToDays;
  final void Function(int days)? onScrollDays;

  /// While a block is dragged outside the calendar: the pointer position,
  /// then null when it comes back or the drag ends.
  final void Function(CalItem item, Offset? globalPosition)? onDragOutside;

  /// A block was dropped outside the calendar.
  final void Function(CalItem item, Offset globalPosition)? onDropOutside;

  final double hourHeight;
  final Duration dropDuration;

  /// Overrides the clock (tests).
  final DateTime? now;

  @override
  State<WeekCalendar> createState() => WeekCalendarState();
}

class WeekCalendarState extends State<WeekCalendar>
    with SingleTickerProviderStateMixin {
  static const gutterWidth = 56.0;

  final _scroll = ScrollController();
  final _gridKey = GlobalKey();
  final _viewportKey = GlobalKey();

  _DragOp? _op;
  Offset? _lastPointer;
  Timer? _autoScroll;
  Timer? _clock;

  /// Ranges committed by a drag, shown until [widget.items] catches up so
  /// the item doesn't flicker back to its old spot.
  final _pending = <String, (DateTime, DateTime)>{};

  // ---- Horizontal paging ----
  /// Horizontal shift of the day columns in pixels: positive reveals the
  /// previous page, negative the next.
  double _shift = 0;
  late final AnimationController _pageAnim = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() => _shift = _pageAnim.value));

  /// Width of the visible day columns (one page).
  double _pageWidth = 1;

  /// Trackpad gesture in progress: shift at its start, and the axis it
  /// locked to (null until it has moved far enough to tell).
  _TrackpadGesture? _pan;

  // ---- Zoom (pinch) ----
  /// Hour height after pinching; null until the user zooms.
  double? _zoomedHourHeight;
  double get _hourHeight => _zoomedHourHeight ?? widget.hourHeight;
  static const _maxHourHeight = 160.0;

  /// Fingers on the screen, for two-finger pinches.
  final _touches = <int, Offset>{};

  /// A two-finger pinch in progress: finger distance and hour height when
  /// it started.
  ({double span, double hourHeight})? _pinch;
  VelocityTracker? _velocity;
  Timer? _wheelSettle;

  bool get _paging =>
      widget.prevDays.length == widget.days.length &&
      widget.nextDays.length == widget.days.length;

  /// Previous, visible and next days, in order.
  List<DateTime> get _all => _paging
      ? [...widget.prevDays, ...widget.days, ...widget.nextDays]
      : widget.days;

  /// Index of the first visible day in [_all].
  int get _first => _paging ? widget.prevDays.length : 0;

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToWorkingHours());
  }

  /// Scrolls so the current time (or 8 AM on other weeks) is near the top.
  void scrollToWorkingHours() {
    if (!_scroll.hasClients) return;
    final now = _now;
    final showsToday = widget.days.any((d) => dateOnly(d) == dateOnly(now));
    final minutes = showsToday
        ? math.max(0, now.hour * 60 + now.minute - 90)
        : 8 * 60 - 30;
    _scroll.jumpTo(
      (minutes * _hourHeight / 60).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  void didUpdateWidget(WeekCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pending.removeWhere((id, range) {
      final item = widget.items.where((i) => i.id == id).firstOrNull;
      return item == null || (item.start == range.$1 && item.end == range.$2);
    });
  }

  @override
  void dispose() {
    _pageAnim.dispose();
    _wheelSettle?.cancel();
    _scroll.dispose();
    _autoScroll?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  // ---- Coordinates -----------------------------------------------------

  /// Day index and (unsnapped) minutes under a global pointer position.
  (int, double)? _slotAt(Offset global) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(global);
    final dayWidth = box.size.width / _all.length;
    // Only visible days: the neighbouring pages are off-screen.
    final day = (local.dx / dayWidth).floor().clamp(
      _first,
      _first + widget.days.length - 1,
    );
    return (day, local.dy / _hourHeight * 60);
  }

  // ---- Drag lifecycle --------------------------------------------------

  void _begin(
    _Mode mode,
    Offset global, {
    CalItem? item,
    double minCreate = 15,
  }) {
    final slot = _slotAt(global);
    if (slot == null) return;
    final op = _DragOp(mode, item: item, anchorDay: slot.$1, anchorMin: slot.$2)
      ..day = slot.$1
      ..minCreate = minCreate;
    if (item != null) {
      op
        ..start = item.start
        ..end = item.end;
    }
    _op = op;
    _lastPointer = global;
    _autoScroll ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
    if (mode == _Mode.create) _update(global);
  }

  void _update(Offset global) {
    final op = _op;
    if (op == null) return;
    _lastPointer = global;
    final slot = _slotAt(global);
    if (slot == null) return;
    final (dayIndex, minutes) = slot;
    final days = _all;

    if (op.mode == _Mode.move && widget.onDropOutside != null) {
      final box = context.findRenderObject() as RenderBox?;
      final outside = box != null && box.globalToLocal(global).dx < 0;
      if (outside) {
        // Show the block back in its original spot while it's out.
        op
          ..outside = true
          ..start = op.item!.start
          ..end = op.item!.end;
        widget.onDragOutside?.call(op.item!, global);
        setState(() {});
        return;
      }
      if (op.outside) {
        op.outside = false;
        widget.onDragOutside?.call(op.item!, null);
      }
    }

    switch (op.mode) {
      case _Mode.move:
        final item = op.item!;
        final originDay = dateOnly(item.start);
        final originMin = minutesFrom(originDay, item.start);
        final length = item.end.difference(item.start).inMinutes;
        // Shift by whole days (in the visible days list), keep the grab
        // point under the pointer, snap the start to 15 minutes.
        final originIndex = days.indexWhere((d) => dateOnly(d) == originDay);
        final targetDay = originIndex < 0
            ? DateTime(
                originDay.year,
                originDay.month,
                originDay.day + dayIndex - op.anchorDay,
              )
            : days[(originIndex + dayIndex - op.anchorDay).clamp(
                0,
                days.length - 1,
              )];
        final startMin = snap(originMin + minutes - op.anchorMin)
            .clamp(0, minutesPerDay - math.min(length, 15))
            .toDouble();
        final (s, e) = moveTo(item.start, item.end, targetDay, startMin);
        op
          ..start = s
          ..end = e;
      case _Mode.resizeTop:
        final item = op.item!;
        final day = dateOnly(item.start);
        final endMin = minutesFrom(day, item.end).clamp(0, minutesPerDay);
        op.start = timeOn(day, snap(minutes).clamp(0, endMin - 15).toDouble());
      case _Mode.resizeBottom:
        final item = op.item!;
        // The day the item ends on (an end at midnight belongs to the day
        // before).
        final lastDay = dateOnly(
          item.end.subtract(const Duration(microseconds: 1)),
        );
        final startMin = minutesFrom(lastDay, item.start);
        final endMin = snap(minutes)
            .clamp(math.max(0, startMin + 15), minutesPerDay)
            .toDouble();
        op.end = timeOn(lastDay, endMin);
      case _Mode.create:
        final day = days[op.anchorDay];
        final a = snapDown(op.anchorMin);
        var b = snap(minutes);
        if ((b - a).abs() < op.minCreate) b = a + op.minCreate;
        final lo = math.min(a, b), hi = math.max(a, b);
        op
          ..day = op.anchorDay
          ..start = timeOn(day, lo)
          ..end = timeOn(day, hi.clamp(lo + 15, minutesPerDay).toDouble());
      case _Mode.drop:
        final day = days[dayIndex];
        final length = widget.dropDuration.inMinutes;
        final startMin = snapDown(minutes)
            .clamp(0, minutesPerDay - length)
            .toDouble();
        op
          ..day = dayIndex
          ..start = timeOn(day, startMin)
          ..end = timeOn(day, startMin + length);
    }
    setState(() {});
  }

  void _end() {
    final op = _op;
    _op = null;
    _autoScroll?.cancel();
    _autoScroll = null;
    if (op == null) return;
    if (op.outside) {
      widget.onDragOutside?.call(op.item!, null);
      widget.onDropOutside?.call(op.item!, _lastPointer!);
      setState(() {});
      return;
    }
    final (start, end) = (op.start, op.end);
    if (start == null || end == null) {
      setState(() {});
      return;
    }
    switch (op.mode) {
      case _Mode.move || _Mode.resizeTop || _Mode.resizeBottom:
        final item = op.item!;
        if (start != item.start || end != item.end) {
          _pending[item.id] = (start, end);
          widget.onChanged(item, start, end);
        }
      case _Mode.create:
        widget.onCreate(start, end);
      case _Mode.drop:
        widget.onDropTask(op.task!, start, end);
    }
    setState(() {});
  }

  /// Ends a touch move of [item] if the system cancelled the gesture.
  void _cancelItem(CalItem item) {
    if (_op?.item?.id == item.id) _cancel();
  }

  void _cancel() {
    if (_op case _DragOp(outside: true, :final item?)) {
      widget.onDragOutside?.call(item, null);
    }
    _op = null;
    _autoScroll?.cancel();
    _autoScroll = null;
    setState(() {});
  }

  /// While dragging near the top or bottom edge, scroll the grid.
  void _autoScrollTick() {
    final pointer = _lastPointer;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (_op == null ||
        _op!.outside ||
        pointer == null ||
        box == null ||
        !_scroll.hasClients) {
      return;
    }
    const zone = 48.0;
    final y = box.globalToLocal(pointer).dy;
    double delta = 0;
    if (y < zone) delta = -(zone - y) / 3;
    if (y > box.size.height - zone) delta = (y - (box.size.height - zone)) / 3;
    if (delta == 0) return;
    final target = (_scroll.offset + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (target == _scroll.offset) return;
    _scroll.jumpTo(target);
    _update(pointer);
  }

  // ---- Build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      onPointerDown: _fingerDown,
      onPointerMove: _fingerMove,
      onPointerUp: _fingerUp,
      onPointerCancel: _fingerUp,
      onPointerPanZoomStart: _panStart,
      onPointerPanZoomUpdate: _panUpdate,
      onPointerPanZoomEnd: _panEnd,
      onPointerSignal: _wheel,
      child: GestureDetector(
        supportedDevices: _touch,
        onHorizontalDragStart: _touchSwipeStart,
        onHorizontalDragUpdate: _touchSwipeUpdate,
        onHorizontalDragEnd: _touchSwipeEnd,
        onHorizontalDragCancel: () => _touchSwipeEnd(null),
        child: Column(
          children: [
            _DayHeader(
              days: _all,
              now: _now,
              gutter: gutterWidth,
              pager: _pager,
            ),
            _AllDayRow(
              days: _all,
              pager: _pager,
              items: widget.allDayItems,
              gutter: gutterWidth,
              selectedId: widget.selectedId,
              onSelect: widget.onSelect,
              onOpen: widget.onOpen,
              onContextMenu: widget.onContextMenu,
            ),
            Divider(height: 1, color: theme.dividerColor),
            Expanded(child: _buildGrid(theme)),
          ],
        ),
      ),
    );
  }

  // ---- Touch swipes ------------------------------------------------------

  bool _touchSwiping = false;

  void _touchSwipeStart(DragStartDetails d) {
    if (!_paging || _op != null || _pinch != null) return;
    _pageAnim.stop();
    _touchSwiping = true;
  }

  void _touchSwipeUpdate(DragUpdateDetails d) {
    if (!_touchSwiping || _pinch != null) return;
    setState(() => _shift = _clampShift(_shift + d.delta.dx));
  }

  void _touchSwipeEnd(DragEndDetails? d) {
    if (!_touchSwiping) return;
    _touchSwiping = false;
    _settle(d?.primaryVelocity ?? 0);
  }

  /// Shows the visible page of a row of [_all] day columns, shifted by the
  /// current swipe.
  Widget _pager(Widget child) => _paging
      ? _Pager(
          widthFactor: _all.length / widget.days.length,
          leading: _first / widget.days.length,
          shift: _shift,
          child: child,
        )
      : child;

  // ---- Paging gestures --------------------------------------------------

  void _panStart(PointerPanZoomStartEvent e) {
    if (_op != null) return;
    if (_paging) _pageAnim.stop();
    _pan = _TrackpadGesture(shift: _shift, hourHeight: _hourHeight);
    _velocity = VelocityTracker.withKind(e.kind);
  }

  void _panUpdate(PointerPanZoomUpdateEvent e) {
    final p = _pan;
    if (p == null) return;
    _velocity?.addPosition(e.timeStamp, e.pan);
    // Pinching zooms the hours; it wins unless the gesture has already
    // turned into a sideways swipe.
    if (!p.zoom && p.axis != Axis.horizontal && (e.scale - 1).abs() > 0.04) {
      p.zoom = true;
    }
    if (p.zoom) {
      _zoomTo(p.hourHeight * e.scale, e.position);
      return;
    }
    if (!_paging) return;
    if (p.axis == null) {
      if (e.pan.distance < 8) return;
      // Lock to the dominant direction so vertical scrolling never drifts
      // sideways and vice versa.
      p
        ..axis = e.pan.dx.abs() > e.pan.dy.abs()
            ? Axis.horizontal
            : Axis.vertical
        ..lockDx = e.pan.dx;
    }
    if (p.axis == Axis.horizontal) {
      setState(() => _shift = _clampShift(p.shift + e.pan.dx - p.lockDx));
    }
  }

  void _panEnd(PointerPanZoomEndEvent e) {
    final p = _pan;
    _pan = null;
    if (p == null || p.zoom || p.axis != Axis.horizontal) return;
    _settle(_velocity?.getVelocity().pixelsPerSecond.dx ?? 0);
  }

  /// Horizontal mouse wheels, Shift+wheel, and trackpads in browsers (which
  /// also report pinches as scale events).
  void _wheel(PointerSignalEvent e) {
    if (e is PointerScaleEvent) {
      _zoomTo(_hourHeight * e.scale, e.position);
      return;
    }
    if (!_paging || e is! PointerScrollEvent || _op != null) return;
    final d = e.scrollDelta;
    if (d.dx.abs() <= d.dy.abs()) return;
    _pageAnim.stop();
    setState(() => _shift = _clampShift(_shift - d.dx));
    _wheelSettle?.cancel();
    _wheelSettle = Timer(const Duration(milliseconds: 140), () => _settle(0));
  }

  double _clampShift(double v) => v.clamp(-_pageWidth, _pageWidth).toDouble();

  // ---- Zoom ----------------------------------------------------------------

  /// Fully zoomed out, the whole day fits in the visible grid.
  double get _minHourHeight {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box.size.height / 24 : 12;
  }

  /// Sets the hour height, keeping the time under [focal] (a global
  /// position) where it is, like zooming a map.
  void _zoomTo(double hourHeight, Offset focal) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !_scroll.hasClients) return;
    final old = _hourHeight;
    final h = hourHeight.clamp(_minHourHeight, _maxHourHeight).toDouble();
    if ((h - old).abs() < 0.01) return;
    final y = box.globalToLocal(focal).dy.clamp(0.0, box.size.height);
    final minutes = (_scroll.offset + y) / old * 60;
    final maxOffset = math.max(0.0, h * 24 - box.size.height);
    final offset = (minutes / 60 * h - y).clamp(0.0, maxOffset);
    // Set the new offset without animating or clamping to the old content
    // height; the relayout below brings in the new one.
    _scroll.position.correctPixels(offset);
    setState(() => _zoomedHourHeight = h);
  }

  void _fingerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _touches[e.pointer] = e.position;
    if (_touches.length == 2 && _op == null) {
      // A second finger: pinch, and stop any swipe the first one started.
      if (_touchSwiping) {
        _touchSwiping = false;
        _settle(0);
      }
      setState(
        () => _pinch = (
          span: math.max(_fingerSpan(), 24.0),
          hourHeight: _hourHeight,
        ),
      );
    }
  }

  void _fingerMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.position;
    final pinch = _pinch;
    if (pinch == null || _touches.length < 2) return;
    final points = _touches.values.take(2).toList();
    _zoomTo(
      pinch.hourHeight * _fingerSpan() / pinch.span,
      (points[0] + points[1]) / 2,
    );
  }

  void _fingerUp(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2 && _pinch != null) setState(() => _pinch = null);
  }

  double _fingerSpan() {
    final points = _touches.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  /// The slide in progress: where it's heading, how far that moves (in
  /// days, or in pages), and which callback reports it.
  ({double target, int steps, bool byDay})? _slide;

  /// Snaps to the nearest day ([WeekCalendar.snapToDays]) or page, taking a
  /// fling into account.
  void _settle(double velocity) {
    final w = _pageWidth;
    if (widget.snapToDays) {
      final dayWidth = w / widget.days.length;
      // Carry on a little in the direction of a fling, then snap.
      final projected = _shift + velocity * 0.12;
      final days = (projected / dayWidth).round().clamp(
        -widget.days.length,
        widget.days.length,
      );
      _slideTo(days * dayWidth, steps: -days, byDay: true);
      return;
    }
    var dir = 0;
    if (_shift > w * 0.2 || velocity > 600) dir = -1;
    if (_shift < -w * 0.2 || velocity < -600) dir = 1;
    // Only page in the direction the grid has actually been pulled.
    if (dir != 0 && _shift != 0 && (_shift > 0) != (dir < 0)) dir = 0;
    _slideTo(-dir * w, steps: dir, byDay: false);
  }

  /// Animates the shift to [target], then reports the move.
  void _slideTo(double target, {required int steps, required bool byDay}) {
    _slide = (target: target, steps: steps, byDay: byDay);
    _pageAnim.value = _shift;
    _pageAnim
        .animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (mounted && _slide?.target == target && _shift == target) {
            _finishSlide();
          }
        });
  }

  void _finishSlide() {
    final slide = _slide!;
    _slide = null;
    // The parent shows the new days in the same frame as the shift resets,
    // so the swap is invisible.
    setState(() => _shift = 0);
    if (slide.steps == 0) return;
    if (slide.byDay) {
      widget.onScrollDays?.call(slide.steps);
    } else {
      widget.onSwipe?.call(slide.steps);
    }
  }

  /// Goes to the previous (-1) or next (+1) page with a slide animation,
  /// as if swiped (toolbar arrows, keyboard).
  void page(int dir) {
    if (!_paging) {
      widget.onSwipe?.call(dir);
      return;
    }
    if (_pageAnim.isAnimating) {
      // A second press finishes the slide in progress at once, so quick
      // presses each count.
      _pageAnim.stop();
      if (_slide != null) _finishSlide();
    }
    _slideTo(-dir * _pageWidth, steps: dir, byDay: false);
  }

  Widget _buildGrid(ThemeData theme) {
    final height = _hourHeight * 24;
    return DragTarget<Task>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        if (_op?.mode != _Mode.drop) {
          _begin(_Mode.drop, details.offset);
          _op?.task = details.data;
        }
        _update(details.offset);
      },
      onLeave: (_) {
        if (_op?.mode == _Mode.drop) _cancel();
      },
      onAcceptWithDetails: (details) {
        if (_op?.mode != _Mode.drop) {
          _begin(_Mode.drop, details.offset);
          _op?.task = details.data;
        }
        _update(details.offset);
        _end();
      },
      builder: (context, candidates, rejected) => SingleChildScrollView(
        key: _viewportKey,
        // While two fingers pinch, they zoom rather than scroll.
        physics: _pinch != null ? const NeverScrollableScrollPhysics() : null,
        controller: _scroll,
        child: SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: gutterWidth,
                child: _HourLabels(hourHeight: _hourHeight),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _pageWidth = constraints.maxWidth;
                    return _pager(
                      LayoutBuilder(
                        builder: (context, c) =>
                            _buildDays(theme, c.maxWidth, height),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Narrowest an overlapping block may get before overlapping blocks
  /// cascade instead of sitting side by side.
  static const _readableWidth = 72.0;

  /// Left offset and width of [p] within a day column [available] wide.
  ///
  /// Overlapping items sit side by side (each slightly wider than its
  /// column, like Notion Calendar) when that leaves them readable. When it
  /// wouldn't, they cascade instead: each is shifted right a little and
  /// keeps a readable width, later ones drawn on top.
  static (double, double) _place(PlacedItem p, double available) {
    if (p.columns == 1) return (0, available);
    final colWidth = available / p.columns;
    if (colWidth >= _readableWidth) {
      final left = p.column * colWidth;
      final last = p.column == p.columns - 1;
      return (
        left,
        last ? colWidth : math.min(colWidth * 1.6, available - left),
      );
    }
    final width = math.min(
      available,
      math.max(_readableWidth, available * 0.75),
    );
    final step = (available - width) / (p.columns - 1);
    return (p.column * step, width);
  }

  Widget _buildDays(ThemeData theme, double width, double height) {
    final days = _all;
    final dayWidth = width / days.length;
    final op = _op;
    final now = _now;

    // Items with in-flight edits applied.
    final items = [
      for (final i in widget.items)
        if (op != null && op.item?.id == i.id && op.start != null)
          i.withRange(op.start!, op.end!)
        else if (_pending[i.id] case (final s, final e))
          i.withRange(s, e)
        else
          i,
    ];

    final children = <Widget>[
      // Background: grid lines, click to deselect, drag to create.
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          supportedDevices: _touch,
          onTap: () => widget.onSelect?.call(null),
          onLongPressStart: (d) {
            HapticFeedback.mediumImpact();
            _begin(_Mode.create, d.globalPosition, minCreate: 60);
          },
          onLongPressMoveUpdate: (d) => _update(d.globalPosition),
          onLongPressEnd: (_) => _end(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            supportedDevices: _dragDevices,
            // Measure drags from where the button went down, not from where
            // the drag was recognized a few pixels later.
            dragStartBehavior: DragStartBehavior.down,
            onTap: () => widget.onSelect?.call(null),
            onPanStart: (d) => _begin(_Mode.create, d.globalPosition),
            onPanUpdate: (d) => _update(d.globalPosition),
            onPanEnd: (_) => _end(),
            onPanCancel: _cancel,
            child: CustomPaint(
              painter: _GridPainter(
                days: days.length,
                hourHeight: _hourHeight,
                line: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                weekend: theme.colorScheme.onSurface.withValues(alpha: 0.02),
                weekendDays: [
                  for (final d in days)
                    d.weekday == DateTime.saturday ||
                        d.weekday == DateTime.sunday,
                ],
              ),
            ),
          ),
        ),
      ),
    ];

    // Keyed by item and segment number (not day), so a block dragged to
    // another day keeps its widget, and with it the gesture in progress.
    final segments = <String, int>{};
    for (var d = 0; d < days.length; d++) {
      for (final p in layoutDay(items, days[d])) {
        final segment = segments.update(
          p.item.id,
          (n) => n + 1,
          ifAbsent: () => 0,
        );
        final top = p.startMin * _hourHeight / 60;
        final minHeight = _hourHeight / 4;
        final h = math.max(
          (p.endMin - p.startMin) * _hourHeight / 60,
          minHeight,
        );
        final (left, width) = _place(p, dayWidth - 6);
        final dragging = op?.item?.id == p.item.id;
        children.add(
          Positioned(
            key: ValueKey('${p.item.id}#$segment'),
            top: top,
            height: h,
            left: d * dayWidth + 1 + left,
            width: width,
            child: _EventBlock(
              item: p.item,
              height: h,
              width: width,
              overlapping: p.columns > 1,
              selected: widget.selectedId == p.item.id,
              dragging: dragging && !op!.outside,
              faded: dragging && op!.outside,
              onDown: () => widget.onSelect?.call(p.item),
              onOpen: () => widget.onOpen?.call(p.item),
              onContextMenu: (pos) => widget.onContextMenu?.call(p.item, pos),
              onDragStart: (mode, pos) => _begin(mode, pos, item: p.item),
              onDragUpdate: _update,
              onDragEnd: _end,
              onDragCancel: _cancel,
              onTouchCancel: () => _cancelItem(p.item),
              // Fingers: tap selects; tapping the selected block opens its
              // menu (there's no right-click or double-click).
              onTouchTap: (pos) => widget.selectedId == p.item.id
                  ? widget.onContextMenu?.call(p.item, pos)
                  : widget.onSelect?.call(p.item),
            ),
          ),
        );
      }
    }

    // Ghost for a new block or a task being dropped.
    if (op != null &&
        (op.mode == _Mode.create || op.mode == _Mode.drop) &&
        op.start != null) {
      final day = days[op.day];
      final startMin = minutesFrom(day, op.start!);
      final endMin = minutesFrom(day, op.end!).clamp(0, minutesPerDay);
      final color = op.task != null
          ? widget.colorForTask(op.task!)
          : theme.colorScheme.primary.toARGB32();
      children.add(
        Positioned(
          top: startMin * _hourHeight / 60,
          height: (endMin - startMin) * _hourHeight / 60,
          left: op.day * dayWidth + 1,
          width: dayWidth - 6,
          child: IgnorePointer(
            child: _EventBlock(
              item: CalItem(
                id: '_ghost',
                start: op.start!,
                end: op.end!,
                title: op.task?.title ?? 'New session',
                color: color,
              ),
              height: (endMin - startMin) * _hourHeight / 60,
              width: dayWidth - 6,
              selected: false,
              dragging: true,
            ),
          ),
        ),
      );
    }

    // Current time.
    final todayIndex = days.indexWhere((d) => dateOnly(d) == dateOnly(now));
    if (todayIndex >= 0) {
      final y = minutesFrom(now, now) * _hourHeight / 60;
      const red = Color(0xFFE5484D);
      children
        ..add(
          Positioned(
            top: y - 0.75,
            left: todayIndex * dayWidth,
            width: dayWidth,
            height: 1.5,
            child: const IgnorePointer(child: ColoredBox(color: red)),
          ),
        )
        ..add(
          Positioned(
            top: y - 4,
            left: todayIndex * dayWidth - 4,
            width: 8,
            height: 8,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(color: red, shape: BoxShape.circle),
              ),
            ),
          ),
        );
    }

    return Stack(key: _gridKey, clipBehavior: Clip.none, children: children);
  }
}

// ---- Pieces ----------------------------------------------------------------

class _EventBlock extends StatelessWidget {
  const _EventBlock({
    required this.item,
    required this.height,
    required this.width,
    required this.selected,
    required this.dragging,
    this.overlapping = false,
    this.faded = false,
    this.onDown,
    this.onOpen,
    this.onContextMenu,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.onTouchCancel,
    this.onTouchTap,
  });

  final CalItem item;
  final double height;
  final double width;
  final bool selected;
  final bool dragging;

  /// Shares its time with other blocks: outlined so they stay distinct.
  final bool overlapping;

  /// Being dragged out of the calendar.
  final bool faded;
  final VoidCallback? onDown;
  final VoidCallback? onOpen;
  final void Function(Offset globalPosition)? onContextMenu;
  final void Function(_Mode mode, Offset globalPosition)? onDragStart;
  final void Function(Offset globalPosition)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;
  final VoidCallback? onTouchCancel;
  final void Function(Offset globalPosition)? onTouchTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color = Color(item.color);
    final bg = Color.alphaBlend(
      color.withValues(alpha: dark ? 0.38 : 0.22),
      theme.colorScheme.surface,
    );
    final time = DateFormat.jm();
    final range =
        '${time.format(item.start).replaceAll(':00', '')}–'
        '${time.format(item.end).replaceAll(':00', '')}';
    final compact = height < 34;
    final titleStyle = theme.textTheme.labelMedium!.copyWith(
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface,
      decoration: item.done ? TextDecoration.lineThrough : null,
      height: 1.2,
    );
    final subStyle = theme.textTheme.labelSmall!.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
      height: 1.2,
    );
    // Too narrow to wrap whole words: show one clipped line (or nothing),
    // never words broken into a column of letters.
    final showText = width >= 22;
    final narrow =
        width < 60 ||
        !_wordsFit(
          item.title,
          titleStyle,
          width - 11, // border, padding and margin
          MediaQuery.textScalerOf(context),
        );

    Widget content = Container(
      margin: const EdgeInsets.only(right: 1, bottom: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: Border(left: BorderSide(color: color, width: 3)),
        boxShadow: dragging
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : overlapping
            ? [BoxShadow(color: theme.colorScheme.surface, spreadRadius: 1)]
            : null,
      ),
      foregroundDecoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: theme.colorScheme.onSurface,
                width: 1.5,
              ),
            )
          : null,
      padding: EdgeInsets.fromLTRB(narrow ? 3 : 5, compact ? 1 : 3, 2, 1),
      child: ClipRect(
        child: !showText
            ? const SizedBox.expand()
            : narrow
            ? Align(
                alignment: Alignment.topLeft,
                child: Text(
                  item.title,
                  style: titleStyle,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
              )
            : compact
            ? Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: item.title, style: titleStyle),
                    TextSpan(
                      text: '  ${time.format(item.start)}',
                      style: subStyle,
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: titleStyle,
                    maxLines: math.max(1, ((height - 22) / 15).floor()),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    item.label.isEmpty ? range : '$range · ${item.label}',
                    style: subStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
      ),
    );
    if (item.done || faded) {
      content = Opacity(opacity: faded ? 0.3 : 0.55, child: content);
    }

    final editable = item.editable && onDragStart != null;
    final body = GestureDetector(
      // Fingers: tap to select, long-press to pick up and move.
      behavior: HitTestBehavior.opaque,
      supportedDevices: _touch,
      onTapUp: (d) => onTouchTap?.call(d.globalPosition),
      onLongPressStart: editable
          ? (d) {
              HapticFeedback.mediumImpact();
              onDragStart!(_Mode.move, d.globalPosition);
            }
          : null,
      onLongPressMoveUpdate: editable
          ? (d) => onDragUpdate!(d.globalPosition)
          : null,
      onLongPressEnd: editable ? (_) => onDragEnd!() : null,
      onLongPressCancel: editable ? onTouchCancel : null,
      child: Listener(
        onPointerDown: (e) {
          // Mouse: select on press. Fingers select on tap (above), so that
          // scrolling past a block doesn't select it.
          if (e.kind != PointerDeviceKind.touch &&
              e.buttons == kPrimaryButton) {
            onDown?.call();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          supportedDevices: _dragDevices,
          // Measure drags from where the button went down, not from where
          // the drag was recognized a few pixels later.
          dragStartBehavior: DragStartBehavior.down,
          onDoubleTap: onOpen,
          onSecondaryTapUp: (d) => onContextMenu?.call(d.globalPosition),
          onPanStart: editable
              ? (d) => onDragStart!(_Mode.move, d.globalPosition)
              : null,
          onPanUpdate: editable ? (d) => onDragUpdate!(d.globalPosition) : null,
          onPanEnd: editable ? (_) => onDragEnd!() : null,
          onPanCancel: editable ? onDragCancel : null,
          child: MouseRegion(
            cursor: !editable
                ? SystemMouseCursors.click
                : dragging
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab,
            child: content,
          ),
        ),
      ),
    );
    if (!editable) return body;

    // Resize handles along the top and bottom edges: thin strips for the
    // mouse; once the block is selected, taller strips that fingers can
    // grab too (with dots to show them).
    final edge = selected
        ? math.min(24.0, height / 3)
        : math.min(7.0, height / 4);
    Widget handle(_Mode mode) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      supportedDevices: selected ? {..._dragDevices, ..._touch} : _dragDevices,
      // Measure drags from where the button went down, not from where
      // the drag was recognized a few pixels later.
      dragStartBehavior: DragStartBehavior.down,
      // A finger tap (not a drag) on a handle is a tap on the block: on a
      // short selected block the handles cover most of it.
      onTapUp: (d) {
        if (d.kind == PointerDeviceKind.touch) {
          onTouchTap?.call(d.globalPosition);
        }
      },
      // Vertical (not pan) so a finger's drag here beats the scroll view's.
      onVerticalDragStart: (d) => onDragStart!(mode, d.globalPosition),
      onVerticalDragUpdate: (d) => onDragUpdate!(d.globalPosition),
      onVerticalDragEnd: (_) => onDragEnd!(),
      onVerticalDragCancel: onDragCancel,
      child: const MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: SizedBox.expand(),
      ),
    );
    Widget dot() => Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.onSurface, width: 1.5),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (selected) ...[
          Positioned(top: 2, right: 4, child: IgnorePointer(child: dot())),
          Positioned(bottom: 2, left: 6, child: IgnorePointer(child: dot())),
        ],
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: edge,
          child: handle(_Mode.resizeTop),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: edge,
          child: handle(_Mode.resizeBottom),
        ),
      ],
    );
  }
}

/// Whether every word of [text] fits on a line [width] wide.
bool _wordsFit(String text, TextStyle style, double width, TextScaler scaler) {
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    if (w > width) return false;
  }
  return true;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.days,
    required this.now,
    required this.gutter,
    required this.pager,
  });
  final List<DateTime> days;
  final DateTime now;
  final double gutter;
  final Widget Function(Widget) pager;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox(width: gutter),
          Expanded(
            child: pager(
              Row(
                children: [
                  for (final d in days)
                    Expanded(
                      child: _DayLabel(day: d, now: now),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Mon 26" when there's room; weekday stacked over the date when the
/// column is narrow; scaled down rather than overflowing when tiny.
class _DayLabel extends StatelessWidget {
  const _DayLabel({required this.day, required this.now});
  final DateTime day;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isToday = dateOnly(day) == dateOnly(now);
    final style = theme.textTheme.titleSmall!.copyWith(
      color: isToday
          ? null
          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
      fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
    );
    final date = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: isToday
          ? BoxDecoration(
              color: const Color(0xFFE5484D),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Text(
        '${day.day}',
        style: style.copyWith(color: isToday ? Colors.white : null),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 84;
        final label = wide
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(DateFormat.E().format(day), style: style),
                  const SizedBox(width: 6),
                  date,
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    constraints.maxWidth >= 34
                        ? DateFormat.E().format(day)
                        : DateFormat.EEEEE().format(day),
                    style: theme.textTheme.labelSmall!.copyWith(
                      color: style.color,
                    ),
                  ),
                  date,
                ],
              );
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(fit: BoxFit.scaleDown, child: label),
          ),
        );
      },
    );
  }
}

class _AllDayRow extends StatelessWidget {
  const _AllDayRow({
    required this.days,
    required this.pager,
    required this.items,
    required this.gutter,
    this.selectedId,
    this.onSelect,
    this.onOpen,
    this.onContextMenu,
  });

  final List<DateTime> days;
  final Widget Function(Widget) pager;
  final List<CalItem> items;
  final double gutter;
  final String? selectedId;
  final void Function(CalItem? item)? onSelect;
  final void Function(CalItem item)? onOpen;
  final void Function(CalItem item, Offset globalPosition)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perDay = [
      for (final d in days)
        [
          for (final i in items)
            if (i.start.isBefore(DateTime(d.year, d.month, d.day + 1)) &&
                i.end.isAfter(dateOnly(d)))
              i,
        ],
    ];
    final rows = perDay.fold(0, (m, l) => math.max(m, l.length));
    if (rows == 0) return const SizedBox(height: 6);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutter,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: Text(
                'all-day',
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall!.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          Expanded(
            child: pager(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final list in perDay)
                    Expanded(
                      child: Column(
                        children: [
                          for (final i in list)
                            _AllDayChip(
                              item: i,
                              selected: selectedId == i.id,
                              onTap: () => onSelect?.call(i),
                              onOpen: () => onOpen?.call(i),
                              onContextMenu: (p) => onContextMenu?.call(i, p),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AllDayChip extends StatelessWidget {
  const _AllDayChip({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    required this.onContextMenu,
  });

  final CalItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final void Function(Offset) onContextMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(item.color);
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(1, 2, 5, 0),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kPrimaryButton) onTap();
        },
        child: GestureDetector(
          onDoubleTap: onOpen,
          onSecondaryTapUp: (d) => onContextMenu(d.globalPosition),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  color.withValues(alpha: dark ? 0.38 : 0.22),
                  theme.colorScheme.surface,
                ),
                borderRadius: BorderRadius.circular(5),
                border: selected
                    ? Border.all(color: theme.colorScheme.onSurface, width: 1.5)
                    : Border(left: BorderSide(color: color, width: 3)),
              ),
              child: Row(
                children: [
                  if (item.kind == CalKind.deadline)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        item.done
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 13,
                        color: color,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium!.copyWith(
                        fontWeight: FontWeight.w600,
                        decoration: item.done
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HourLabels extends StatelessWidget {
  const _HourLabels({required this.hourHeight});
  final double hourHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall!.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
    );
    return Stack(
      children: [
        for (var h = 1; h < 24; h++)
          Positioned(
            top: h * hourHeight - 7,
            right: 8,
            child: Text(
              DateFormat.j().format(DateTime(2000, 1, 1, h)),
              style: style,
            ),
          ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.days,
    required this.hourHeight,
    required this.line,
    required this.weekend,
    required this.weekendDays,
  });

  final int days;
  final double hourHeight;
  final Color line;
  final Color weekend;
  final List<bool> weekendDays;

  @override
  void paint(Canvas canvas, Size size) {
    final dayWidth = size.width / days;
    final shade = Paint()..color = weekend;
    for (var d = 0; d < days; d++) {
      if (weekendDays[d]) {
        canvas.drawRect(
          Rect.fromLTWH(d * dayWidth, 0, dayWidth, size.height),
          shade,
        );
      }
    }
    final paint = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var h = 1; h < 24; h++) {
      final y = h * hourHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var d = 0; d <= days; d++) {
      final x = d * dayWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.days != days ||
      old.hourHeight != hourHeight ||
      old.line != line ||
      old.weekend != weekend;
}

/// Lays its child out [widthFactor] times as wide as itself and shows the
/// part starting [leading] widths in, moved right by [shift] pixels. Used to
/// keep the neighbouring pages of days ready while swiping between them.
class _Pager extends SingleChildRenderObjectWidget {
  const _Pager({
    required this.widthFactor,
    required this.leading,
    required this.shift,
    required super.child,
  });

  final double widthFactor;
  final double leading;
  final double shift;

  @override
  _RenderPager createRenderObject(BuildContext context) =>
      _RenderPager(widthFactor, leading, shift);

  @override
  void updateRenderObject(BuildContext context, _RenderPager renderObject) =>
      renderObject
        ..widthFactor = widthFactor
        ..leading = leading
        ..shift = shift;
}

class _RenderPager extends RenderShiftedBox {
  _RenderPager(this._widthFactor, this._leading, this._shift) : super(null);

  double _widthFactor;
  set widthFactor(double v) {
    if (v == _widthFactor) return;
    _widthFactor = v;
    markNeedsLayout();
  }

  double _leading;
  set leading(double v) {
    if (v == _leading) return;
    _leading = v;
    markNeedsLayout();
  }

  double _shift;
  set shift(double v) {
    if (v == _shift) return;
    _shift = v;
    // Only the child's position changes; no relayout needed.
    if (hasSize && child != null) {
      (child!.parentData! as BoxParentData).offset = _childOffset;
      markNeedsPaint();
    }
  }

  Offset get _childOffset => Offset(-size.width * _leading + _shift, 0);

  @override
  void performLayout() {
    final w = constraints.maxWidth;
    final child = this.child!;
    child.layout(
      constraints.copyWith(
        minWidth: w * _widthFactor,
        maxWidth: w * _widthFactor,
      ),
      parentUsesSize: true,
    );
    size = constraints.constrain(Size(w, child.size.height));
    (child.parentData! as BoxParentData).offset = _childOffset;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // RenderBox.hitTest already ignores points outside [size], so the
    // off-screen pages can't be clicked either.
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(
        child,
        offset + (child.parentData! as BoxParentData).offset,
      ),
    );
  }
}

/// A two-finger trackpad gesture: a sideways swipe, a vertical scroll, or a
/// pinch, decided once it has moved far enough to tell.
class _TrackpadGesture {
  _TrackpadGesture({required this.shift, required this.hourHeight});

  /// Page shift and hour height when the gesture started.
  final double shift;
  final double hourHeight;
  Axis? axis;
  bool zoom = false;
  double lockDx = 0;
}
