import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';

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
  ({double base, Axis? axis, double lockDx})? _pan;
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
      (minutes * widget.hourHeight / 60).clamp(
        0,
        _scroll.position.maxScrollExtent,
      ),
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
    return (day, local.dy / widget.hourHeight * 60);
  }

  // ---- Drag lifecycle --------------------------------------------------

  void _begin(_Mode mode, Offset global, {CalItem? item}) {
    final slot = _slotAt(global);
    if (slot == null) return;
    final op = _DragOp(mode, item: item, anchorDay: slot.$1, anchorMin: slot.$2)
      ..day = slot.$1;
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
        if ((b - a).abs() < 15) b = a + 15;
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
      onPointerPanZoomStart: _panStart,
      onPointerPanZoomUpdate: _panUpdate,
      onPointerPanZoomEnd: _panEnd,
      onPointerSignal: _wheel,
      child: Column(
        children: [
          _DayHeader(days: _all, now: _now, gutter: gutterWidth, pager: _pager),
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
    );
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
    if (!_paging || _op != null) return;
    _pageAnim.stop();
    _pan = (base: _shift, axis: null, lockDx: 0);
    _velocity = VelocityTracker.withKind(e.kind);
  }

  void _panUpdate(PointerPanZoomUpdateEvent e) {
    final pan = _pan;
    if (pan == null) return;
    _velocity?.addPosition(e.timeStamp, e.pan);
    if (pan.axis == null) {
      if (e.pan.distance < 8) return;
      // Lock to the dominant direction so vertical scrolling never drifts
      // sideways and vice versa.
      _pan = (
        base: pan.base,
        axis: e.pan.dx.abs() > e.pan.dy.abs() ? Axis.horizontal : Axis.vertical,
        lockDx: e.pan.dx,
      );
    }
    final p = _pan!;
    if (p.axis == Axis.horizontal) {
      setState(() => _shift = _clampShift(p.base + e.pan.dx - p.lockDx));
    }
  }

  void _panEnd(PointerPanZoomEndEvent e) {
    final pan = _pan;
    _pan = null;
    if (pan?.axis != Axis.horizontal) return;
    _settle(_velocity?.getVelocity().pixelsPerSecond.dx ?? 0);
  }

  /// Horizontal mouse wheels, Shift+wheel, and trackpads in browsers.
  void _wheel(PointerSignalEvent e) {
    if (!_paging || e is! PointerScrollEvent || _op != null) return;
    final d = e.scrollDelta;
    if (d.dx.abs() <= d.dy.abs()) return;
    _pageAnim.stop();
    setState(() => _shift = _clampShift(_shift - d.dx));
    _wheelSettle?.cancel();
    _wheelSettle = Timer(const Duration(milliseconds: 140), () => _settle(0));
  }

  double _clampShift(double v) => v.clamp(-_pageWidth, _pageWidth).toDouble();

  /// Snaps to the nearest page (or the one flung towards).
  void _settle(double velocity) {
    final w = _pageWidth;
    var dir = 0;
    if (_shift > w * 0.2 || velocity > 600) dir = -1;
    if (_shift < -w * 0.2 || velocity < -600) dir = 1;
    // Only page in the direction the grid has actually been pulled.
    if (dir != 0 && _shift != 0 && (_shift > 0) != (dir < 0)) dir = 0;
    _animateTo(dir);
  }

  /// Animates to the previous (-1) or next (+1) page, or back to the
  /// current one (0), then reports the change through [WeekCalendar.onSwipe].
  void _animateTo(int dir) {
    final target = -dir * _pageWidth;
    _pageAnim.value = _shift;
    _pageAnim
        .animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (!mounted || dir == 0 || _shift != target) return;
          // The parent shows the new page in the same frame as the shift
          // resets, so the swap is invisible.
          setState(() => _shift = 0);
          widget.onSwipe?.call(dir);
        });
  }

  /// Goes to the previous (-1) or next (+1) page with a slide animation,
  /// as if swiped (toolbar arrows, keyboard).
  void page(int dir) {
    if (!_paging) {
      widget.onSwipe?.call(dir);
      return;
    }
    // A second press while sliding finishes the first page immediately.
    if (_pageAnim.isAnimating) {
      _pageAnim.stop();
      return page(dir);
    }
    _animateTo(dir);
  }

  Widget _buildGrid(ThemeData theme) {
    final height = widget.hourHeight * 24;
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
        controller: _scroll,
        child: SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: gutterWidth,
                child: _HourLabels(hourHeight: widget.hourHeight),
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
              hourHeight: widget.hourHeight,
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
        final top = p.startMin * widget.hourHeight / 60;
        final minHeight = widget.hourHeight / 4;
        final h = math.max(
          (p.endMin - p.startMin) * widget.hourHeight / 60,
          minHeight,
        );
        final colWidth = (dayWidth - 6) / p.columns;
        final dragging = op?.item?.id == p.item.id;
        children.add(
          Positioned(
            key: ValueKey('${p.item.id}#$segment'),
            top: top,
            height: h,
            left: d * dayWidth + 1 + p.column * colWidth,
            // Overlapping items overlap slightly, like Notion Calendar.
            width: p.column == p.columns - 1
                ? colWidth
                : math.min(colWidth * 1.6, dayWidth - 6 - p.column * colWidth),
            child: _EventBlock(
              item: p.item,
              height: h,
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
          top: startMin * widget.hourHeight / 60,
          height: (endMin - startMin) * widget.hourHeight / 60,
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
              height: (endMin - startMin) * widget.hourHeight / 60,
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
      final y = minutesFrom(now, now) * widget.hourHeight / 60;
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
    required this.selected,
    required this.dragging,
    this.faded = false,
    this.onDown,
    this.onOpen,
    this.onContextMenu,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  final CalItem item;
  final double height;
  final bool selected;
  final bool dragging;

  /// Being dragged out of the calendar.
  final bool faded;
  final VoidCallback? onDown;
  final VoidCallback? onOpen;
  final void Function(Offset globalPosition)? onContextMenu;
  final void Function(_Mode mode, Offset globalPosition)? onDragStart;
  final void Function(Offset globalPosition)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;

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
      padding: EdgeInsets.fromLTRB(5, compact ? 1 : 3, 4, 1),
      child: ClipRect(
        child: compact
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
    final body = Listener(
      onPointerDown: (e) {
        if (e.buttons == kPrimaryButton) onDown?.call();
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
    );
    if (!editable) return body;

    final edge = math.min(7.0, height / 4);
    Widget handle(_Mode mode) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      supportedDevices: _dragDevices,
      // Measure drags from where the button went down, not from where
      // the drag was recognized a few pixels later.
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: (d) => onDragStart!(mode, d.globalPosition),
      onPanUpdate: (d) => onDragUpdate!(d.globalPosition),
      onPanEnd: (_) => onDragEnd!(),
      onPanCancel: onDragCancel,
      child: const MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: SizedBox.expand(),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
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
    final theme = Theme.of(context);
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
                      child: Center(
                        child: () {
                          final isToday = dateOnly(d) == dateOnly(now);
                          final style = theme.textTheme.titleSmall!.copyWith(
                            color: isToday
                                ? null
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                            fontWeight: isToday
                                ? FontWeight.w600
                                : FontWeight.w400,
                          );
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(DateFormat.E().format(d), style: style),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: isToday
                                    ? BoxDecoration(
                                        color: const Color(0xFFE5484D),
                                        borderRadius: BorderRadius.circular(6),
                                      )
                                    : null,
                                child: Text(
                                  '${d.day}',
                                  style: style.copyWith(
                                    color: isToday ? Colors.white : null,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }(),
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
