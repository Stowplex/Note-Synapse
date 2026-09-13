import 'package:json_annotation/json_annotation.dart';

part 'user_app.g.dart';

enum UserAppType { normal, noteAction, aiTool }

/// Localized, user-visible package metadata for a single BCP-47 locale.
class UserAppLocalizedMetadata {
  final String? name;
  final String? description;

  const UserAppLocalizedMetadata({this.name, this.description});

  factory UserAppLocalizedMetadata.fromJson(Map<String, dynamic> json) {
    String? nonBlankString(Object? value) {
      if (value is! String || value.trim().isEmpty) return null;
      return value.trim();
    }

    return UserAppLocalizedMetadata(
      name: nonBlankString(json['name']),
      description: nonBlankString(json['description']),
    );
  }

  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (description != null) 'description': description,
  };

  bool get isEmpty => name == null && description == null;
}

String normalizeUserAppLocaleTag(String tag) {
  final parts = tag
      .trim()
      .replaceAll('_', '-')
      .split('-')
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';
  final normalized = <String>[parts.first.toLowerCase()];
  for (final part in parts.skip(1)) {
    if (RegExp(r'^[A-Za-z]{4}$').hasMatch(part)) {
      normalized.add(
        '${part.substring(0, 1).toUpperCase()}${part.substring(1).toLowerCase()}',
      );
    } else if (RegExp(r'^(?:[A-Za-z]{2}|[0-9]{3})$').hasMatch(part)) {
      normalized.add(part.toUpperCase());
    } else {
      normalized.add(part.toLowerCase());
    }
  }
  return normalized.join('-');
}

bool isValidUserAppLocaleTag(String tag) =>
    RegExp(r'^[A-Za-z]{2,8}(?:[-_][A-Za-z0-9]{1,8})*$').hasMatch(tag.trim());

Map<String, UserAppLocalizedMetadata> userAppI18nFromJson(Object? value) {
  if (value is! Map) return const {};
  final result = <String, UserAppLocalizedMetadata>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! Map) continue;
    if (!isValidUserAppLocaleTag(entry.key as String)) continue;
    final normalized = normalizeUserAppLocaleTag(entry.key as String);
    if (normalized.isEmpty || result.containsKey(normalized)) continue;
    final metadata = UserAppLocalizedMetadata.fromJson(
      Map<String, dynamic>.from(entry.value as Map),
    );
    if (!metadata.isEmpty) result[normalized] = metadata;
  }
  return Map.unmodifiable(result);
}

Map<String, dynamic> userAppI18nToJson(
  Map<String, UserAppLocalizedMetadata> value,
) => {for (final entry in value.entries) entry.key: entry.value.toJson()};

UserAppLocalizedMetadata? resolveUserAppLocalizedMetadata(
  Map<String, UserAppLocalizedMetadata> i18n,
  String? languageTag,
) {
  final normalized = normalizeUserAppLocaleTag(languageTag ?? '');
  if (normalized.isEmpty) return null;
  final normalizedEntries = {
    for (final entry in i18n.entries)
      normalizeUserAppLocaleTag(entry.key): entry.value,
  };
  return normalizedEntries[normalized] ??
      normalizedEntries[normalized.split('-').first];
}

class UserAppLibraryInfo {
  final String name;
  final String? usage;
  final List<String> links;

  const UserAppLibraryInfo({
    required this.name,
    this.usage,
    required this.links,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'usage': usage,
    'links': links,
  };

  factory UserAppLibraryInfo.fromJson(Map<String, dynamic> json) =>
      UserAppLibraryInfo(
        name: json['name'] as String,
        usage: json['usage'] as String?,
        links: (json['links'] as List<dynamic>).cast<String>(),
      );
}

@JsonSerializable()
class UserApp {
  final String id;
  final String uuid;
  final String name;
  final String description;
  final List<String> steps;
  final String htmlContent;
  final Map<String, dynamic>? appState;
  final UserAppType type;
  final String? selectedRevisionId;
  final String author;
  final String license;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<UserAppLibraryInfo>? libraries;
  @JsonKey(fromJson: userAppI18nFromJson, toJson: userAppI18nToJson)
  final Map<String, UserAppLocalizedMetadata> i18n;

  const UserApp({
    required this.id,
    required this.uuid,
    required this.name,
    required this.description,
    required this.steps,
    required this.htmlContent,
    this.appState,
    this.type = UserAppType.normal,
    this.selectedRevisionId,
    this.author = '',
    this.license = '',
    required this.createdAt,
    required this.updatedAt,
    this.libraries,
    this.i18n = const {},
  });

  factory UserApp.fromJson(Map<String, dynamic> json) =>
      _$UserAppFromJson(json);
  Map<String, dynamic> toJson() => _$UserAppToJson(this);

  UserApp copyWith({
    String? id,
    String? uuid,
    String? name,
    String? description,
    List<String>? steps,
    String? htmlContent,
    Map<String, dynamic>? appState,
    UserAppType? type,
    String? selectedRevisionId,
    String? author,
    String? license,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<UserAppLibraryInfo>? libraries,
    Map<String, UserAppLocalizedMetadata>? i18n,
  }) {
    return UserApp(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      description: description ?? this.description,
      steps: steps ?? this.steps,
      htmlContent: htmlContent ?? this.htmlContent,
      appState: appState ?? this.appState,
      type: type ?? this.type,
      selectedRevisionId: selectedRevisionId ?? this.selectedRevisionId,
      author: author ?? this.author,
      license: license ?? this.license,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      libraries: libraries ?? this.libraries,
      i18n: i18n ?? this.i18n,
    );
  }

  UserAppLocalizedMetadata? _metadataForTag(String? languageTag) {
    return resolveUserAppLocalizedMetadata(i18n, languageTag);
  }

  String nameForTag(String? languageTag) {
    return _metadataForTag(languageTag)?.name?.trim().isNotEmpty == true
        ? _metadataForTag(languageTag)!.name!.trim()
        : name;
  }

  String descriptionForTag(String? languageTag) {
    return _metadataForTag(languageTag)?.description?.trim().isNotEmpty == true
        ? _metadataForTag(languageTag)!.description!.trim()
        : description;
  }

  Iterable<String> get searchableMetadata sync* {
    yield name;
    yield description;
    for (final metadata in i18n.values) {
      if (metadata.name != null) yield metadata.name!;
      if (metadata.description != null) yield metadata.description!;
    }
  }

  Map<String, UserAppLocalizedMetadata> get i18nWithoutNames =>
      Map.unmodifiable({
        for (final entry in i18n.entries)
          if (entry.value.description != null)
            entry.key: UserAppLocalizedMetadata(
              description: entry.value.description,
            ),
      });

  Map<String, UserAppLocalizedMetadata> get i18nWithoutDescriptions =>
      Map.unmodifiable({
        for (final entry in i18n.entries)
          if (entry.value.name != null)
            entry.key: UserAppLocalizedMetadata(name: entry.value.name),
      });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserApp && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
