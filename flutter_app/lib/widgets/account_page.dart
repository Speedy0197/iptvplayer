import 'dart:math' as math;
import 'package:flutter/material.dart';

class StreamPilotWordmark extends StatelessWidget {
  const StreamPilotWordmark({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'StreamPilot',
    excludeSemantics: true,
    child: Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'stream'),
          TextSpan(
            text: 'pilot',
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w800,
        letterSpacing: -.6,
      ),
    ),
  );
}

/// A common readable surface for account and pairing tasks.
class AccountPage extends StatelessWidget {
  const AccountPage({
    super.key,
    required this.child,
    this.title,
    this.maxWidth = 460,
  });
  final Widget child;
  final String? title;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: title == null ? null : AppBar(title: Text(title!)),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - 40),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const StreamPilotWordmark(),
                        const SizedBox(height: 28),
                        child,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
