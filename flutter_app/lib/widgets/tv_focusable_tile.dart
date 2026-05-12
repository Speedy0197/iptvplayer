import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/ui_constants.dart';

/// Wraps a tile in a D-pad-friendly focus shell for Android TV.
///
/// Responsibilities:
///   * Visible focus ring + subtle scale so the user can see where focus is.
///   * Scroll the focused tile into view when focus changes.
///   * Map a short Select/OK press to [onTap] and a long press (≥
///     [kTvLongPressDuration]) to [onLongPress]. Flutter's
///     `GestureDetector.onLongPress` does not fire from D-pad/keyboard events,
///     so we wire it manually off raw key events.
class TvFocusableTile extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final EdgeInsetsGeometry margin;

  const TvFocusableTile({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.margin = const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
  });

  @override
  State<TvFocusableTile> createState() => _TvFocusableTileState();
}

class _TvFocusableTileState extends State<TvFocusableTile> {
  bool _focused = false;
  Timer? _longPressTimer;
  bool _longPressFired = false;
  bool _selectKeyDown = false;
  DateTime? _selectPressedAt;

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _onFocusChange(bool hasFocus) {
    if (!mounted) return;
    setState(() => _focused = hasFocus);
    if (hasFocus) {
      // Defer to next frame so the ScrollPosition is up-to-date.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.3,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      });
    } else {
      _cancelLongPress();
    }
  }

  bool _isSelectKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space;
  }

  void _startLongPress() {
    _cancelLongPressTimer();
    if (widget.onLongPress == null) return;
    _longPressFired = false;
    _longPressTimer = Timer(kTvLongPressDuration, () {
      if (!mounted) return;
      _longPressFired = true;
    });
  }

  void _cancelLongPress() {
    _cancelLongPressTimer();
    _selectKeyDown = false;
    _selectPressedAt = null;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isSelectKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      if (_selectKeyDown) {
        return KeyEventResult.handled;
      }
      _selectKeyDown = true;
      _selectPressedAt = DateTime.now();
      _startLongPress();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      // Ignore repeats so they don't reset the long-press timer.
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (!_selectKeyDown) {
        return KeyEventResult.handled;
      }
      final pressedAt = _selectPressedAt;
      final heldLongEnough =
          pressedAt != null &&
          DateTime.now().difference(pressedAt) >= kTvLongPressDuration;
      final wasLong = _longPressFired;
      final triggerLongPress =
          widget.onLongPress != null && (wasLong || heldLongEnough);
      _cancelLongPress();
      if (triggerLongPress) {
        widget.onLongPress?.call();
      } else if (!heldLongEnough) {
        widget.onTap();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final focusColor = colorScheme.primary;

    return Padding(
      padding: widget.margin,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _onFocusChange,
        onKeyEvent: _onKeyEvent,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? focusColor : Colors.transparent,
                width: 2,
              ),
              color: _focused
                  ? colorScheme.primaryContainer.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
