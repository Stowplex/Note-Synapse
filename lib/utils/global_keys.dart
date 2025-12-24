import 'package:flutter/material.dart';

/// Global key for the navigator to allow navigation from non-UI code
/// (e.g. Services) without passing context around or creating circular dependencies.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
