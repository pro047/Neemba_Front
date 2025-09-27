String? validateRtmpUrl(String url) {
  final String trimmed = url.trim();

  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) {
    return 'URL을 확인해주세요';
  }

  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return '올바름 URL형식이 아닙니다';
  }

  final bool isRtmp = uri.scheme == 'rtmp' || uri.scheme == 'rtmps';
  if (!isRtmp) {
    return 'rtmp 또는 rtmps 형식만 허용합니다';
  }

  if (uri.pathSegments.isEmpty) {
    return '잘못된 경로입니다';
  }

  if (uri.pathSegments.length < 1) {
    return '스트림 키가 없습니다';
  }

  if (RegExp(r'[^\x29-\x7E]').hasMatch(trimmed)) {
    return '허용되지 않는 문자가 있습니다';
  }
  return null;
}
