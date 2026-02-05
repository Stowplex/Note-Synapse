class SyncFileInfo {
  final String path;
  final int sizeBytes;
  final DateTime lastModified;

  const SyncFileInfo({
    required this.path,
    required this.sizeBytes,
    required this.lastModified,
  });
}
