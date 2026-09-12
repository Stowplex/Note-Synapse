import 'package:flutter/widgets.dart';

import '../models/user_app.dart';

/// The public User App API uses stable, fully-qualified locale tags even when
/// an old preference or a widget test provides a language-only Flutter locale.
String userAppLocaleTag(Locale locale) {
  switch (locale.languageCode.toLowerCase()) {
    case 'en':
      return 'en-US';
    case 'zh':
      return 'zh-CN';
    default:
      return locale.toLanguageTag();
  }
}

extension UserAppPresentation on UserApp {
  String displayName(BuildContext context) =>
      nameForTag(userAppLocaleTag(Localizations.localeOf(context)));

  String displayDescription(BuildContext context) =>
      descriptionForTag(userAppLocaleTag(Localizations.localeOf(context)));
}
