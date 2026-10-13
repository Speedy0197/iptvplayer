import 'package:flutter/material.dart';
import '../../account_screen.dart';
import '../home_types.dart';

class HomeLeftMenu extends StatelessWidget {
  final HomeSection section;
  final ValueChanged<HomeSection> onChanged;
  const HomeLeftMenu({
    super.key,
    required this.section,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: SizedBox(
      width: 104,
      child: Column(
        children: [
          Expanded(
            child: NavigationRail(
              selectedIndex: HomeSection.values.indexOf(section),
              onDestinationSelected: (index) =>
                  onChanged(HomeSection.values[index]),
              labelType: NavigationRailLabelType.all,
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
                  icon: Icon(Icons.dns_outlined),
                  selectedIcon: Icon(Icons.dns),
                  label: Text('Sources'),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [Icon(Icons.person_outline), Text('Account')],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}
