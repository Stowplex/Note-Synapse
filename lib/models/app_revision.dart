import 'package:json_annotation/json_annotation.dart';

part 'app_revision.g.dart';

@JsonSerializable()
class AppRevision {
  final String id;
  final String appId;
  final int revisionNumber;
  final DateTime revisionTimestamp;
  final String userPrompt;
  final String aiResponse;
  final String appCode;
  final List<String> attachmentPaths;

  const AppRevision({
    required this.id,
    required this.appId,
    required this.revisionNumber,
    required this.revisionTimestamp,
    required this.userPrompt,
    required this.aiResponse,
    required this.appCode,
    this.attachmentPaths = const [],
  });

  factory AppRevision.fromJson(Map<String, dynamic> json) => _$AppRevisionFromJson(json);
  Map<String, dynamic> toJson() => _$AppRevisionToJson(this);

  AppRevision copyWith({
    String? id,
    String? appId,
    int? revisionNumber,
    DateTime? revisionTimestamp,
    String? userPrompt,
    String? aiResponse,
    String? appCode,
    List<String>? attachmentPaths,
  }) {
    return AppRevision(
      id: id ?? this.id,
      appId: appId ?? this.appId,
      revisionNumber: revisionNumber ?? this.revisionNumber,
      revisionTimestamp: revisionTimestamp ?? this.revisionTimestamp,
      userPrompt: userPrompt ?? this.userPrompt,
      aiResponse: aiResponse ?? this.aiResponse,
      appCode: appCode ?? this.appCode,
      attachmentPaths: attachmentPaths ?? this.attachmentPaths,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppRevision && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

