/// 夸克网盘账号与认证信息
class QuarkAccount {
  final String id;
  final String uid;
  final String nickname;
  final String avatarUrl;
  final String cookie;
  final int totalCapacity;
  final int usedCapacity;
  final DateTime updatedAt;
  final bool isVip;

  QuarkAccount({
    required this.id,
    required this.uid,
    required this.nickname,
    this.avatarUrl = '',
    required this.cookie,
    this.totalCapacity = 0,
    this.usedCapacity = 0,
    required this.updatedAt,
    this.isVip = false,
  });

  bool get isValid => cookie.trim().isNotEmpty;

  double get usedPercentage {
    if (totalCapacity <= 0) return 0.0;
    return (usedCapacity / totalCapacity).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'uid': uid,
        'nickname': nickname,
        'avatarUrl': avatarUrl,
        'cookie': cookie,
        'totalCapacity': totalCapacity,
        'usedCapacity': usedCapacity,
        'updatedAt': updatedAt.toIso8601String(),
        'isVip': isVip,
      };

  factory QuarkAccount.fromJson(Map<String, dynamic> json) => QuarkAccount(
        id: json['id'] as String? ?? 'default',
        uid: json['uid'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '夸克用户',
        avatarUrl: json['avatarUrl'] as String? ?? '',
        cookie: json['cookie'] as String? ?? '',
        totalCapacity: json['totalCapacity'] as int? ?? 0,
        usedCapacity: json['usedCapacity'] as int? ?? 0,
        updatedAt: json['updatedAt'] != null
            ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        isVip: json['isVip'] as bool? ?? false,
      );

  QuarkAccount copyWith({
    String? id,
    String? uid,
    String? nickname,
    String? avatarUrl,
    String? cookie,
    int? totalCapacity,
    int? usedCapacity,
    DateTime? updatedAt,
    bool? isVip,
  }) =>
      QuarkAccount(
        id: id ?? this.id,
        uid: uid ?? this.uid,
        nickname: nickname ?? this.nickname,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        cookie: cookie ?? this.cookie,
        totalCapacity: totalCapacity ?? this.totalCapacity,
        usedCapacity: usedCapacity ?? this.usedCapacity,
        updatedAt: updatedAt ?? this.updatedAt,
        isVip: isVip ?? this.isVip,
      );
}
