import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'radio_page.dart';

final radioFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/radio',
    label: 'Radio',
    icon: Icons.radio_outlined,
    selectedIcon: Icons.radio,
  ),
  routes: [GoRoute(path: '/radio', builder: (_, _) => const RadioPage())],
);
