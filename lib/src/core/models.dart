enum ItemStatus {
  planned,
  downloaded,
  existsSkipped,
  uploaded,
  retryableFailed,
  permanentFailed,
}

String itemStatusToDb(ItemStatus status) {
  switch (status) {
    case ItemStatus.planned:
      return 'planned';
    case ItemStatus.downloaded:
      return 'downloaded';
    case ItemStatus.existsSkipped:
      return 'exists_skipped';
    case ItemStatus.uploaded:
      return 'uploaded';
    case ItemStatus.retryableFailed:
      return 'retryable_failed';
    case ItemStatus.permanentFailed:
      return 'permanent_failed';
  }
}

ItemStatus itemStatusFromDb(String value) {
  switch (value) {
    case 'planned':
      return ItemStatus.planned;
    case 'downloaded':
      return ItemStatus.downloaded;
    case 'exists_skipped':
      return ItemStatus.existsSkipped;
    case 'uploaded':
      return ItemStatus.uploaded;
    case 'retryable_failed':
      return ItemStatus.retryableFailed;
    case 'permanent_failed':
      return ItemStatus.permanentFailed;
    default:
      throw ArgumentError('Unknown item status: $value');
  }
}

class EmojiSpec {
  const EmojiSpec({required this.name, required this.src});

  final String name;
  final String src;
}

class UploadItem {
  const UploadItem({
    required this.runId,
    required this.name,
    required this.src,
    required this.status,
    required this.attempts,
    this.lastError,
    this.localPath,
    this.contentSha256,
  });

  final String runId;
  final String name;
  final String src;
  final ItemStatus status;
  final int attempts;
  final String? lastError;
  final String? localPath;
  final String? contentSha256;
}

class TeamInfo {
  const TeamInfo({
    required this.id,
    required this.name,
    required this.displayName,
  });

  final String id;
  final String name;
  final String displayName;
}

class Profile {
  const Profile({
    required this.server,
    required this.loginId,
    required this.userId,
    required this.token,
    required this.createdAtIso,
    this.selectedTeamId,
  });

  final String server;
  final String loginId;
  final String userId;
  final String token;
  final String createdAtIso;
  final String? selectedTeamId;

  Profile copyWith({String? selectedTeamId}) {
    return Profile(
      server: server,
      loginId: loginId,
      userId: userId,
      token: token,
      createdAtIso: createdAtIso,
      selectedTeamId: selectedTeamId,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'server': server,
      'login_id': loginId,
      'user_id': userId,
      'token': token,
      'created_at': createdAtIso,
      'selected_team_id': selectedTeamId,
    };
  }

  static Profile fromJson(Map<String, Object?> json) {
    return Profile(
      server: json['server'] as String,
      loginId: json['login_id'] as String,
      userId: json['user_id'] as String,
      token: json['token'] as String,
      createdAtIso: json['created_at'] as String,
      selectedTeamId: json['selected_team_id'] as String?,
    );
  }
}

class LoginResult {
  const LoginResult({required this.token, required this.userId});

  final String token;
  final String userId;
}

class RunRecord {
  const RunRecord({
    required this.runId,
    required this.sourcePath,
    required this.status,
  });

  final String runId;
  final String sourcePath;
  final String status;
}

class UploadSummary {
  const UploadSummary({
    required this.runId,
    required this.total,
    required this.uploaded,
    required this.skippedExisting,
    required this.retryableFailed,
    required this.permanentFailed,
  });

  final String runId;
  final int total;
  final int uploaded;
  final int skippedExisting;
  final int retryableFailed;
  final int permanentFailed;
}
