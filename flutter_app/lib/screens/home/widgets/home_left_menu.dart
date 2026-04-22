import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/auth_store.dart';
import '../home_types.dart';

class HomeLeftMenu extends StatelessWidget {
  final HomeSection section;
  final ValueChanged<HomeSection> onChanged;

  const HomeLeftMenu({super.key, required this.section, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Expanded(
                child: NavigationRail(
                  selectedIndex: HomeSection.values.indexOf(section),
                  onDestinationSelected: (index) =>
                      onChanged(HomeSection.values[index]),
                  labelType: NavigationRailLabelType.none,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.ondemand_video_outlined),
                      selectedIcon: Icon(Icons.ondemand_video),
                      label: Text('Watch'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.star_border),
                      selectedIcon: Icon(Icons.star),
                      label: Text('Favorites'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.playlist_play_outlined),
                      selectedIcon: Icon(Icons.playlist_play),
                      label: Text('Playlists'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                button: true,
                label: 'Logout',
                child: InkResponse(
                  onTap: () => context.read<AuthStore>().logout(),
                  radius: 24,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.logout),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
