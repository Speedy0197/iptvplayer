import 'package:flutter/material.dart';

import '../../../config/device_utils.dart';
import '../../../services/playlist_store.dart';

class HomeSearchBar extends StatelessWidget {
  final TextEditingController searchCtrl;
  final PlaylistStore store;
  final ValueChanged<String> onChanged;
  final VoidCallback onTap;
  final bool inAppBar;

  const HomeSearchBar({
    super.key,
    required this.searchCtrl,
    required this.store,
    required this.onChanged,
    required this.onTap,
    this.inAppBar = false,
  });

  @override
  Widget build(BuildContext context) {
    final directionalNavigation = isAndroidTv(context);

    Widget buildSearchButton({required Color backgroundColor}) {
      return Semantics(
        button: true,
        label: 'Search channels and groups',
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.search, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Search channels, groups',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (inAppBar) {
      final colorScheme = Theme.of(context).colorScheme;
      if (directionalNavigation) {
        return buildSearchButton(
          backgroundColor: colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.6,
          ),
        );
      }
      return TextField(
        controller: searchCtrl,
        autofocus: false,
        readOnly: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search channels, groups',
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          isDense: true,
        ),
        onTap: onTap,
      );
    }
    if (directionalNavigation) {
      return buildSearchButton(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }
    return TextField(
      controller: searchCtrl,
      readOnly: true,
      decoration: const InputDecoration(
        labelText: 'Search channels, groups',
        prefixIcon: Icon(Icons.search),
      ),
      onTap: onTap,
    );
  }
}
