import 'dart:convert';
import 'package:http/http.dart' as http;

class DriveFileInfo {
  final String id;
  final String name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedTime;

  const DriveFileInfo({
    required this.id,
    required this.name,
    this.mimeType,
    this.size,
    this.modifiedTime,
  });

  factory DriveFileInfo.fromJson(Map<String, dynamic> json) {
    return DriveFileInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      mimeType: json['mimeType'] as String?,
      // Drive API returns size as String
      size: json['size'] != null ? int.tryParse(json['size'] as String) : null,
      modifiedTime: json['modifiedTime'] != null
          ? DateTime.tryParse(json['modifiedTime'] as String)
          : null,
    );
  }
}

class GoogleDriveException implements Exception {
  final String message;
  final int? statusCode;
  GoogleDriveException(this.message, {this.statusCode});
  @override
  String toString() => 'GoogleDriveException($statusCode): $message';
}

class GoogleDriveAuthException extends GoogleDriveException {
  GoogleDriveAuthException(super.message) : super(statusCode: 401);
}

class GoogleDriveQuotaException extends GoogleDriveException {
  GoogleDriveQuotaException(super.message) : super(statusCode: 403);
}

class GoogleDriveApiClient {
  static const _baseUrl = 'https://www.googleapis.com';

  final Future<String> Function() _getAccessToken;
  final http.Client _httpClient;

  GoogleDriveApiClient({
    required Future<String> Function() getAccessToken,
    http.Client? httpClient,
  })  : _getAccessToken = getAccessToken,
        _httpClient = httpClient ?? http.Client();

  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    return {'Authorization': 'Bearer $token'};
  }

  void _checkStatus(http.Response response) {
    if (response.statusCode == 401) {
      throw GoogleDriveAuthException('Unauthorized — token may have expired');
    }
    if (response.statusCode == 403) {
      throw GoogleDriveQuotaException('Forbidden — quota or permission error');
    }
    if (response.statusCode >= 400) {
      throw GoogleDriveException(
        'HTTP ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<List<DriveFileInfo>> listChildren(String parentId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files').replace(
      queryParameters: {
        'q': "'$parentId' in parents and trashed=false",
        'fields': 'files(id,name,mimeType,size,modifiedTime)',
        'pageSize': '1000',
      },
    );
    final response = await _httpClient.get(uri, headers: await _authHeaders());
    _checkStatus(response);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final files = json['files'] as List<dynamic>;
    return files
        .map((f) => DriveFileInfo.fromJson(f as Map<String, dynamic>))
        .toList();
  }
}
