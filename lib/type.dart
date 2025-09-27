class StartSessionResponse {
  final String sessionId;
  final String webSocketUrl;

  StartSessionResponse({required this.sessionId, required this.webSocketUrl});

  factory StartSessionResponse.fromJson(Map<String, dynamic> json) {
    return StartSessionResponse(
      sessionId: json['sessionId'],
      webSocketUrl: json['webSocketUrl'],
    );
  }

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'webSocketUrl': webSocketUrl,
  };
}
