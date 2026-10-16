import 'package:flutter/material.dart';

class BrowseChoice<T> {
  final T value;
  final String label;
  final int? channelCount;

  const BrowseChoice(this.value, this.label, {this.channelCount});
}

/// A touch-friendly sheet on phones and an anchored menu on larger screens.
class BrowsePicker<T> extends StatelessWidget {
  final String title;
  final String tooltip;
  final String searchHint;
  final T value;
  final List<BrowseChoice<T>> choices;
  final ValueChanged<T> onSelected;
  final Widget child;
  final bool enabled;

  const BrowsePicker({
    super.key,
    required this.title,
    required this.tooltip,
    required this.searchHint,
    required this.value,
    required this.choices,
    required this.onSelected,
    required this.child,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (MediaQuery.sizeOf(context).width >= 600 ||
        MediaQuery.navigationModeOf(context) == NavigationMode.directional) {
      return PopupMenuButton<T>(
        tooltip: tooltip,
        enabled: enabled,
        initialValue: value,
        position: PopupMenuPosition.under,
        constraints: BoxConstraints(
          minWidth: 280,
          maxWidth: 400,
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        onSelected: onSelected,
        itemBuilder: (_) => [
          for (final choice in choices)
            PopupMenuItem<T>(
              value: choice.value,
              child: _ChoiceLabel(
                choice: choice,
                selected: choice.value == value,
              ),
            ),
        ],
        child: child,
      );
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: !enabled
            ? null
            : () async {
                FocusManager.instance.primaryFocus?.unfocus();
                final selected = await showModalBottomSheet<T>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  showDragHandle: true,
                  backgroundColor: colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    side: BorderSide(color: colors.outlineVariant),
                  ),
                  builder: (_) => _PickerSheet(
                    title: title,
                    searchHint: searchHint,
                    choices: choices,
                    value: value,
                  ),
                );
                if (context.mounted && selected != null) onSelected(selected);
              },
        child: child,
      ),
    );
  }
}

class _PickerSheet<T> extends StatefulWidget {
  final String title;
  final String searchHint;
  final List<BrowseChoice<T>> choices;
  final T value;

  const _PickerSheet({
    required this.title,
    required this.searchHint,
    required this.choices,
    required this.value,
  });

  @override
  State<_PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<_PickerSheet<T>> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim().toLowerCase();
    final visible = widget.choices
        .where((choice) => choice.label.toLowerCase().contains(query))
        .toList();
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final available = MediaQuery.sizeOf(context).height - keyboard;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: 'Close picker',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
    final filter = widget.choices.length <= 8
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: widget.searchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear filter',
                        onPressed: () => setState(_controller.clear),
                        icon: const Icon(Icons.clear),
                      ),
              ),
            ),
          );
    const empty = Padding(
      padding: EdgeInsets.all(24),
      child: Text('No matches found'),
    );
    const listPadding = EdgeInsets.fromLTRB(12, 0, 12, 16);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: available * .78),
          child: CustomScrollView(
            shrinkWrap: true,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(child: header),
              if (filter != null) SliverToBoxAdapter(child: filter),
              if (visible.isEmpty)
                const SliverToBoxAdapter(child: empty)
              else
                SliverPadding(
                  padding: listPadding,
                  sliver: SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _choiceTile(context, visible[index]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _choiceTile(BuildContext context, BrowseChoice<T> choice) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        FocusScope.of(context).unfocus();
        Navigator.of(context).pop(choice.value);
      },
      child: _ChoiceLabel(
        choice: choice,
        selected: choice.value == widget.value,
      ),
    ),
  );
}

class _ChoiceLabel<T> extends StatelessWidget {
  final BrowseChoice<T> choice;
  final bool selected;

  const _ChoiceLabel({required this.choice, required this.selected});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? colors.primary.withValues(alpha: .12) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                choice.label,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? colors.primary : colors.onSurface,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (choice.channelCount != null) ...[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.outlineVariant.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${choice.channelCount}',
                  semanticsLabel: '${choice.channelCount} channels',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 12),
            SizedBox(
              width: 20,
              child: selected
                  ? Icon(Icons.check, color: colors.primary, size: 20)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
