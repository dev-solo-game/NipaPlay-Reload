import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nipaplay/models/quark/quark_account.dart';
import 'package:nipaplay/services/quark/quark_service.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_snackbar.dart';
import 'package:nipaplay/utils/app_accent_color.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QuarkConnectionDialog {
  static Future<bool?> show(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF2F2F2);

    return BlurDialog.show<bool>(
      context: context,
      title: '夸克网盘',
      backgroundColor: backgroundColor,
      contentWidget: const _QuarkContent(),
    );
  }
}

class _QuarkContent extends StatefulWidget {
  const _QuarkContent();

  @override
  State<_QuarkContent> createState() => _QuarkContentState();
}

class _QuarkContentState extends State<_QuarkContent>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _cookieController = TextEditingController();

  String? _qrUrl;
  String? _qrToken;
  String _scanStatusText = '正在获取登录二维码...';
  bool _isQrLoading = true;
  bool _isManualLoading = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    if (!QuarkService.instance.isLoggedIn) {
      _loadQrCode();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabController.dispose();
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _loadQrCode() async {
    _pollTimer?.cancel();
    setState(() {
      _isQrLoading = true;
      _scanStatusText = '正在获取登录二维码...';
    });

    try {
      final info = await QuarkService.instance.client.getQrCode();
      if (!mounted) return;
      setState(() {
        _qrToken = info['token'] as String;
        _qrUrl = info['qrUrl'] as String;
        _isQrLoading = false;
        _scanStatusText = '请使用手机夸克 App 扫描二维码';
      });

      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isQrLoading = false;
        _scanStatusText = '获取二维码失败，请点击重试';
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1800), (timer) async {
      if (_qrToken == null || !mounted) {
        timer.cancel();
        return;
      }

      try {
        final status = await QuarkService.instance.client.pollQrCode(_qrToken!);
        if (!mounted) return;

        if (status.isSuccess && status.cookie != null) {
          timer.cancel();
          setState(() {
            _scanStatusText = '登录成功，正在加载网盘空间...';
          });
          await QuarkService.instance.loginWithCookie(status.cookie!);
          if (mounted) {
            BlurSnackBar.show(context, '夸克网盘登录成功！');
            setState(() {});
          }
        } else if (status.isExpired) {
          timer.cancel();
          setState(() {
            _scanStatusText = '二维码已失效，点击刷新';
          });
        } else {
          setState(() {
            _scanStatusText = status.message;
          });
        }
      } catch (e) {
        debugPrint('夸克轮询异常: $e');
      }
    });
  }

  Future<void> _handleManualLogin() async {
    final cookie = _cookieController.text.trim();
    if (cookie.isEmpty) {
      BlurSnackBar.show(context, '请输入 Cookie');
      return;
    }

    if (!cookie.contains('__pus')) {
      BlurSnackBar.show(context, 'Cookie 格式不完整，需包含 __pus 凭证');
      return;
    }

    setState(() => _isManualLoading = true);
    try {
      await QuarkService.instance.loginWithCookie(cookie);
      if (mounted) {
        BlurSnackBar.show(context, '夸克网盘 Cookie 验证通过');
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        BlurSnackBar.show(context, '登录失败: $e');
      }
    } finally {
      if (mounted) setState(() => _isManualLoading = false);
    }
  }

  String _formatCapacity(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    int i = 0;
    double d = bytes.toDouble();
    while (d >= 1024 && i < suffixes.length - 1) {
      d /= 1024;
      i++;
    }
    return '${d.toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final quark = QuarkService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = AppAccentColors.current;

    // 已登录界面
    if (quark.isLoggedIn) {
      final account = quark.currentAccount!;
      return _buildLoggedInView(account, primaryColor, isDark);
    }

    // 未登录界面（带扫码登录与手动输入 Tab）
    return SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            controller: _tabController,
            labelColor: primaryColor,
            unselectedLabelColor: isDark ? Colors.white60 : Colors.black54,
            indicatorColor: primaryColor,
            tabs: const [
              Tab(icon: Icon(Icons.qr_code_scanner, size: 20), text: '扫码登录'),
              Tab(icon: Icon(Icons.key, size: 20), text: 'Cookie 登录'),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 320,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildQrScanTab(primaryColor, isDark),
                _buildManualCookieTab(primaryColor, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoggedInView(
      QuarkAccount account, Color primaryColor, bool isDark) {
    return SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? Colors.white12 : Colors.black12,
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: primaryColor.withOpacity(0.2),
                  child: Icon(Icons.cloud_done, color: primaryColor, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              account.nickname,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (account.isVip) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.amber.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.amber),
                              ),
                              child: const Text(
                                'VIP',
                                style: TextStyle(
                                  color: Colors.amber,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'UID: ${account.uid.isNotEmpty ? account.uid : "已认证"}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 空间容量进度
          Text(
            '网盘容量: ${_formatCapacity(account.usedCapacity)} / ${_formatCapacity(account.totalCapacity)}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: account.usedPercentage,
              backgroundColor: isDark ? Colors.white12 : Colors.black12,
              valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await QuarkService.instance.logout();
                    if (mounted) _loadQrCode();
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('退出登录'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop(true);
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('完成'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQrScanTab(Color primaryColor, bool isDark) {
    if (_isQrLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: primaryColor),
            const SizedBox(height: 16),
            Text(_scanStatusText, style: const TextStyle(fontSize: 14)),
          ],
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_qrUrl != null)
          GestureDetector(
            onTap: _loadQrCode,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrImageView(
                data: _qrUrl!,
                version: QrVersions.auto,
                size: 190,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
              ),
            ),
          )
        else
          Container(
            width: 214,
            height: 214,
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.qr_code_2_rounded, size: 48, color: Colors.grey),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _loadQrCode,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('点击获取二维码'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                _scanStatusText,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: '刷新二维码',
              onPressed: _loadQrCode,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildManualCookieTab(Color primaryColor, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          '将浏览器中登录 pan.quark.cn 后的 Cookie 完整粘贴至下方：',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: _cookieController,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: '__pus=...; __puus=...; __uid=...',
              hintStyle: const TextStyle(fontSize: 12),
              filled: true,
              fillColor: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: isDark ? Colors.white24 : Colors.black26,
                ),
              ),
            ),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _isManualLoading ? null : _handleManualLogin,
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: _isManualLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('保存并登录'),
        ),
      ],
    );
  }
}
