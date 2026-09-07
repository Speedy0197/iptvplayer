import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../config/ui_constants.dart';

/// A remote-controlled list whose cursor can reach rows not yet built by Flutter.
/// One focus node owns the column; selection is remembered by item identity.
class TvRemoteList<T> extends StatefulWidget {
  const TvRemoteList({
    super.key,
    required this.focusNode,
    required this.items,
    required this.itemId,
    required this.itemBuilder,
    required this.memoryKey,
    required this.onFocused,
    required this.onActivate,
    required this.onLeft,
    required this.onRight,
    required this.onBack,
    this.selectedId,
    this.itemExtent = 72,
    this.autofocus = false,
    this.onLongPress,
    this.empty = const Center(child: Text('No channels found')),
  });

  final FocusNode focusNode;
  final List<T> items;
  final String Function(T) itemId;
  final Widget Function(BuildContext, T, bool focused) itemBuilder;
  final String memoryKey;
  final String? selectedId;
  final double itemExtent;
  final bool autofocus;
  final ValueChanged<T> onFocused;
  final ValueChanged<T> onActivate;
  final ValueChanged<T>? onLongPress;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onBack;
  final Widget empty;

  @override
  State<TvRemoteList<T>> createState() => _TvRemoteListState<T>();
}

class _TvRemoteListState<T> extends State<TvRemoteList<T>> {
  final _scroll = ScrollController();
  final _offsets = <String, double>{};
  String? _selectedId;
  Timer? _holdTimer;
  bool _selectDown = false;
  bool _held = false;
  int _scrollGeneration = 0;
  bool _restorePending = false;

  int get _index {
    final index = widget.items.indexWhere(
      (item) => widget.itemId(item) == _selectedId,
    );
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _reconcileSelection();
    _scheduleScroll(restore: true);
  }

  @override
  void didUpdateWidget(covariant TvRemoteList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedContext = oldWidget.memoryKey != widget.memoryKey;
    if (changedContext) {
      if (_scroll.hasClients) {
        _offsets[oldWidget.memoryKey] = _scroll.offset;
      }
      _cancelSelect();
    }
    final previous = _selectedId;
    _reconcileSelection();
    if (changedContext ||
        previous != _selectedId ||
        oldWidget.items != widget.items ||
        oldWidget.itemExtent != widget.itemExtent) {
      _scheduleScroll(restore: changedContext);
    }
  }

  void _reconcileSelection() {
    if (widget.items.isEmpty) return;
    final requested = widget.selectedId ?? _selectedId;
    final index = widget.items.indexWhere(
      (item) => widget.itemId(item) == requested,
    );
    final item = widget.items[index < 0 ? 0 : index];
    _selectedId = widget.itemId(item);
    if (_selectedId != widget.selectedId) {
      final identity = _selectedId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedId != identity || widget.items.isEmpty) return;
        widget.onFocused(widget.items[_index]);
      });
    }
  }

  void _scheduleScroll({bool restore = false}) {
    // A group can temporarily have no list while its channels load. Keep the
    // restore request until the replacement list has a scroll position.
    _restorePending = _restorePending || restore;
    final generation = ++_scrollGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _scrollGeneration || !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      if (_restorePending) {
        _restorePending = false;
        _scroll.jumpTo(
          (_offsets[widget.memoryKey] ?? 0).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
      }
      final top = _index * widget.itemExtent;
      final bottom = top + widget.itemExtent;
      var target = _scroll.offset;
      if (top < target) target = top;
      if (bottom > target + position.viewportDimension) {
        target = bottom - position.viewportDimension;
      }
      target = target.clamp(0.0, position.maxScrollExtent);
      // A new remote repeat immediately supersedes the previous scroll target.
      // Animated scrolls here lag behind a held D-pad and can hide the cursor.
      if (target != _scroll.offset) _scroll.jumpTo(target);
    });
  }

  void _focusItem(int index) {
    if (widget.items.isEmpty) return;
    final item = widget.items[index.clamp(0, widget.items.length - 1)];
    setState(() => _selectedId = widget.itemId(item));
    widget.onFocused(item);
    _scheduleScroll();
  }

  void _cancelSelect() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _selectDown = false;
    _held = false;
  }

  bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.space;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_isSelect(key)) {
      if (event is KeyDownEvent && !_selectDown) {
        _selectDown = true;
        _held = false;
        _holdTimer = Timer(kTvLongPressDuration, () => _held = true);
      } else if (event is KeyUpEvent && _selectDown) {
        final held = _held;
        _cancelSelect();
        if (widget.items.isNotEmpty) {
          final item = widget.items[_index];
          if (held && widget.onLongPress != null) {
            widget.onLongPress!(item);
          } else {
            widget.onActivate(item);
          }
        }
      }
      return KeyEventResult.handled;
    }
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (down) {
        _cancelSelect();
        _focusItem(_index + (key == LogicalKeyboardKey.arrowUp ? -1 : 1));
      }
      return KeyEventResult.handled;
    }
    final action = key == LogicalKeyboardKey.arrowLeft
        ? widget.onLeft
        : key == LogicalKeyboardKey.arrowRight
        ? widget.onRight
        : key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape
        ? widget.onBack
        : null;
    if (action != null) {
      if (event is KeyDownEvent) {
        _cancelSelect();
        action();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _cancelSelect();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      includeSemantics: false,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        setState(() {});
        if (!focused) {
          _cancelSelect();
        } else if (widget.items.isNotEmpty) {
          widget.onFocused(widget.items[_index]);
          _scheduleScroll();
        }
      },
      child: ExcludeFocus(
        child: widget.items.isEmpty
            ? widget.empty
            : ListView.builder(
                controller: _scroll,
                itemExtent: widget.itemExtent,
                itemCount: widget.items.length,
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  final focused = widget.focusNode.hasFocus && index == _index;
                  return Semantics(
                    button: true,
                    focusable: true,
                    focused: focused,
                    selected: focused,
                    child: GestureDetector(
                      onTap: () {
                        widget.focusNode.requestFocus();
                        _focusItem(index);
                        widget.onActivate(item);
                      },
                      onLongPress: widget.onLongPress == null
                          ? null
                          : () {
                              widget.focusNode.requestFocus();
                              _focusItem(index);
                              widget.onLongPress!(item);
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 3,
                          horizontal: 3,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: focused
                                ? const Color(0xffeef5ff)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: focused
                                  ? const Color(0xff8fc9ff)
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: DefaultTextStyle.merge(
                            style: TextStyle(
                              color: focused ? const Color(0xff111d2c) : null,
                            ),
                            child: IconTheme.merge(
                              data: IconThemeData(
                                color: focused ? const Color(0xff111d2c) : null,
                              ),
                              child: widget.itemBuilder(context, item, focused),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
