import 'dart:convert';
import 'dart:typed_data';
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

  Future<Uint8List> downloadFile(String fileId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files/$fileId')
        .replace(queryParameters: {'alt': 'media'});
    final response = await _httpClient.get(uri, headers: await _authHeaders());
    _checkStatus(response);
    return response.bodyBytes;
  }

  Future<DriveFileInfo> uploadFile({
    required String name,
    required String parentId,
    required Uint8List content,
    String mimeType = 'application/octet-stream',
  }) async {
    final boundary = 'boundary_${DateTime.now().millisecondsSinceEpoch}';
    final metadataJson = jsonEncode({'name': name, 'parents': [parentId]});

    final bodyPrefix = utf8.encode(
      '--$boundary\r\n'
      'Content-Type: application/json; charset=UTF-8\r\n\r\n'
      '$metadataJson\r\n'
      '--$boundary\r\n'
      'Content-Type: $mimeType\r\n\r\n',
    );
    final bodySuffix = utf8.encode('\r\n--$boundary--');
    final fullBody = Uint8List(
        bodyPrefix.length + content.length + bodySuffix.length)
      ..setRange(0, bodyPrefix.length, bodyPrefix)
      ..setRange(bodyPrefix.length, bodyPrefix.length + content.length, content)
      ..setRange(bodyPrefix.length + content.length,
          bodyPrefix.length + content.length + bodySuffix.length, bodySuffix);

    final uri = Uri.parse('$_baseUrl/upload/drive/v3/files').replace(
      queryParameters: {
        'uploadType': 'multipart',
        'fields': 'id,name,mimeType,size,modifiedTime',
      },
    );

    final headers = await _authHeaders();
    headers['content-type'] = 'multipart/related; boundary=$boundary';
    final response =
        await _httpClient.post(uri, headers: headers, body: fullBody);
    _checkStatus(response);
    return DriveFileInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> updateFile({
    required String fileId,
    required Uint8List content,
    String mimeType = 'application/octet-stream',
  }) async {
    final uri = Uri.parse('$_baseUrl/upload/drive/v3/files/$fileId')
        .replace(queryParameters: {'uploadType': 'media'});
    final headers = await _authHeaders();
    headers['content-type'] = mimeType;
    final response =
        await _httpClient.patch(uri, headers: headers, body: content);
    _checkStatus(response);
  }

  Future<void> trashFile(String fileId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files/$fileId');
    final headers = await _authHeaders();
    headers['content-type'] = 'application/json';
    final response = await _httpClient.patch(
      uri,
      headers: headers,
      body: jsonEncode({'trashed': true}),
    );
    _checkStatus(response);
  }

  Future<DriveFileInfo> createFolder({
    required String name,
    required String parentId,
  }) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files').replace(
      queryParameters: {'fields': 'id,name,mimeType,size,modifiedTime'},
    );
    final headers = await _authHeaders();
    headers['content-type'] = 'application/json';
    final response = await _httpClient.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'name': name,
        'parents': [parentId],
        'mimeType': 'application/vnd.google-apps.folder',
      }),
    );
    _checkStatus(response);
    return DriveFileInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<DriveFileInfo?> getFileInfo(String fileId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files/$fileId').replace(
      queryParameters: {'fields': 'id,name,mimeType,size,modifiedTime'},
    );
    final response =
        await _httpClient.get(uri, headers: await _authHeaders());
    if (response.statusCode == 404) return null;
    _checkStatus(response);
    return DriveFileInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<DriveFileInfo>> listChildren(String parentId) async {
    final results = <DriveFileInfo>[];
    String? pageToken;

    do {
      final queryParams = <String, String>{
        'q': "'$parentId' in parents and trashed=false",
        'fields': 'nextPageToken,files(id,name,mimeType,size,modifiedTime)',
        'pageSize': '1000',
      };
      if (pageToken != null) queryParams['pageToken'] = pageToken;

      final uri = Uri.parse('$_baseUrl/drive/v3/files')
          .replace(queryParameters: queryParams);
      final response = await _httpClient.get(uri, headers: await _authHeaders());
      _checkStatus(response);

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final files = json['files'] as List<dynamic>;
      results.addAll(files.map((f) => DriveFileInfo.fromJson(f as Map<String, dynamic>)));
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);

    return results;
  }
}
