/// Formats contact labels for same-org vs cross-org friends.
class ContactDisplayLabel {
  const ContactDisplayLabel._();

  /// Cross-org: `昵称 · 公司名`. Same-org or missing company: bare nickname/account.
  static String format({
    required String nickname,
    required String account,
    String companyName = '',
    bool isCrossOrganization = false,
    String serverDisplayName = '',
  }) {
    if (serverDisplayName.trim().isNotEmpty) {
      return serverDisplayName.trim();
    }
    final base = nickname.trim().isNotEmpty ? nickname.trim() : account.trim();
    final resolved = base.isNotEmpty ? base : '用户';
    if (!isCrossOrganization) {
      return resolved;
    }
    final company = companyName.trim();
    if (company.isEmpty) {
      return resolved;
    }
    return '$resolved · $company';
  }
}
