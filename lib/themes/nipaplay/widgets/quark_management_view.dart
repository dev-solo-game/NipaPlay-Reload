import 'package:flutter/material.dart';
import 'package:nipaplay/models/quark/quark_mount_folder.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/providers/watch_history_provider.dart';
import 'package:nipaplay/services/quark/quark_service.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_snackbar.dart';
import 'package:nipaplay/themes/nipaplay/widgets/hover_scale_text_button.dart';
import 'package:nipaplay/themes/nipaplay/widgets/library_management_layout.dart';
import 'package:nipaplay/themes/nipaplay/widgets/quark_connection_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/quark_folder_picker_dialog.dart';
import 'package:nipaplay/utils/app_accent_color.dart';
import 'package:provider/provider.dart';

/// 夸克网盘管理视图
class QuarkManagementView extends StatefulWidget {
  const QuarkManagementView({
    super.key,
    required this.onPlayEpisode,
  });

  final void Function(WatchHistoryItem item) onPlayEpisode;

  @override
  State<QuarkManagementView> createState() => _QuarkManagementViewState();
}

class _QuarkManagementViewState extends State<QuarkManagementView> {
  @override
  void initState() {
    super.initState();
    QuarkService.instance.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    QuarkService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var i = 0;
    double d = bytes.toDouble();
    while (d >= 1024 && i < suffixes.length - 1) {
      d /= 1024;
      i++;
    }
    return '${d.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> _pickAndAddFolder() async {
    final mountFolder = await QuarkFolderPickerDialog.show(context);
    if (!mounted || mountFolder == null) return;

    await QuarkService.instance.addMountFolder(mountFolder);
    if (!mounted) return;
    BlurSnackBar.show(context, '已挂载目录：${mountFolder.name}，正在开始首次扫描刮削...');

    // 自动触发首次扫描
    _startScanFolder(mountFolder);
  }

  Future<void> _startScanFolder(QuarkMountFolder folder) async {
    if (QuarkService.instance.isScanning) {
      BlurSnackBar.show(context, '已有扫描任务在进行中，请稍候');
      return;
    }

    try {
      final result = await QuarkService.instance.scanMountFolder(folder);
      if (!mounted) return;

      await context.read<WatchHistoryProvider>().refreshAfterScan();
      if (!mounted) return;

      final total = result['total'] ?? 0;
      final works = result['works'] ?? 0;
      BlurSnackBar.show(
        context,
        '夸克网盘 [${folder.name}] 已入库 $total 个视频，归为 $works 部作品',
      );
    } catch (e) {
      if (mounted) {
        final message = e is StateError ? e.message : e.toString();
        BlurSnackBar.show(context, '夸克刮削失败：$message');
      }
    }
  }

  Future<void> _confirmRemoveFolder(QuarkMountFolder folder) async {
    final confirmed = await BlurDialog.show<bool>(
      context: context,
      title: '解除目录挂载',
      content: '确定要从媒体库中解除挂载【${folder.name}】吗？网盘中的实际文件不会被删除。',
      actionsBuilder: (dialogContext) => [
        HoverScaleTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('取消'),
          ),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
          ),
          child: const Text('确认解除'),
        ),
      ],
    );

    if (confirmed == true && mounted) {
      await QuarkService.instance.removeMountFolder(folder.fid);
      if (mounted) {
        BlurSnackBar.show(context, '已解除挂载：${folder.name}');
      }
    }
  }

  Future<void> _confirmLogout() async {
    final confirmed = await BlurDialog.show<bool>(
      context: context,
      title: '退出夸克账号',
      content: '确定要退出当前的夸克账号吗？退出后将无法在线播放和扫描夸克网盘视频。',
      actionsBuilder: (dialogContext) => [
        HoverScaleTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('取消'),
          ),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
          ),
          child: const Text('退出登录'),
        ),
      ],
    );

    if (confirmed == true && mounted) {
      await QuarkService.instance.logout();
      if (mounted) {
        BlurSnackBar.show(context, '夸克账号已退出');
      }
    }
  }

  Future<void> _configureTmdb() async {
    var input = '';
    final token = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('TMDB 元数据'),
        content: TextField(
          onChanged: (value) => input = value,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'API 读取令牌'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          if (QuarkService.instance.hasTmdbToken)
            TextButton(onPressed: () => Navigator.pop(dialogContext, ''), child: const Text('清除令牌')),
          TextButton(
            onPressed: () {
              final value = input.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || token == null) return;
    try {
      await QuarkService.instance.setTmdbToken(token);
      if (mounted) BlurSnackBar.show(context, '元数据来源已保存，下次刮削生效');
    } catch (_) {
      if (mounted) BlurSnackBar.show(context, '保存元数据配置失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = QuarkService.instance;
    final account = service.currentAccount;
    final folders = service.mountFolders;
    final theme = Theme.of(context);
    final accentColor = AppAccentColors.current;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // 账号信息卡片
        _buildAccountCard(account, theme, accentColor),
        const SizedBox(height: 12),
        LibraryManagementCard(
          child: ListTile(
            title: const Text('自动扫描刮削'),
            subtitle: const Text('应用运行时，按设定周期检查挂载目录。'),
            trailing: DropdownButton<int>(
              value: service.autoScanHours,
              items: [
                for (final hours in QuarkService.autoScanIntervals)
                  DropdownMenuItem(value: hours, child: Text(hours == 0 ? '关闭' : '每 $hours 小时')),
              ],
              onChanged: (hours) async {
                if (hours == null) return;
                try {
                  await service.setAutoScanHours(hours);
                } catch (error) {
                  if (context.mounted) BlurSnackBar.show(context, '保存自动扫描间隔失败：$error');
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        LibraryManagementCard(
          child: ListTile(
            title: const Text('目录扫描请求间隔'),
            subtitle: const Text('手动和自动扫描均适用，下次扫描生效。'),
            trailing: DropdownButton<int>(
              value: service.scanRequestSeconds,
              items: [
                for (final seconds in QuarkService.scanRequestIntervals)
                  DropdownMenuItem(
                    value: seconds,
                    child: Text('每 $seconds 秒一页'),
                  ),
              ],
              onChanged: (seconds) async {
                if (seconds == null) return;
                try {
                  await service.setScanRequestSeconds(seconds);
                } catch (error) {
                  if (context.mounted) {
                    BlurSnackBar.show(context, '保存目录请求间隔失败：$error');
                  }
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        LibraryManagementCard(
          child: ListTile(
            title: const Text('作品资料来源'),
            subtitle: Text(service.hasTmdbToken
                ? 'TMDB · 通过片名和年份补充电影及电视剧资料'
                : 'Bangumi 公开搜索 · 可配置 TMDB 读取令牌'),
            trailing: TextButton(onPressed: _configureTmdb, child: const Text('设置 TMDB')),
          ),
        ),
        const SizedBox(height: 18),

        // 挂载目录标题与添加按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_shared_rounded, size: 20),
                const SizedBox(width: 8),
                Text(
                  '已挂载的网盘目录 (${folders.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            ElevatedButton.icon(
              onPressed: _pickAndAddFolder,
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加挂载目录'),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 挂载目录列表
        if (folders.isEmpty)
          LibraryManagementEmptyState(
            icon: Icons.cloud_off_rounded,
            title: '尚未挂载任何夸克网盘目录',
            subtitle: '点击右上角“添加挂载目录”，选择您网盘中存放动漫影视的文件夹。',
          )
        else
          ...folders.map((folder) => _buildFolderCard(folder, theme, accentColor)),
      ],
    );
  }

  Widget _buildAccountCard(dynamic account, ThemeData theme, Color accentColor) {
    final isDark = theme.brightness == Brightness.dark;
    final onSurface = theme.colorScheme.onSurface;
    final subColor = onSurface.withOpacity(0.65);

    final nickname = account?.nickname ?? '未登录夸克网盘';
    final uid = account?.uid ?? '';
    final isVip = account?.isVip ?? false;
    final total = account?.totalCapacity ?? 0;
    final used = account?.usedCapacity ?? 0;
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;

    return LibraryManagementCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // 头像 / 夸克徽标
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFF007AFF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.cloud_queue_rounded,
                      color: Color(0xFF007AFF),
                      size: 32,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // 用户名与 UID
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (isVip)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.amber.withOpacity(0.2),
                                border: Border.all(color: Colors.amber, width: 0.8),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'SVIP 会员',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.amber,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        uid.isNotEmpty ? '夸克 UID: $uid' : '未绑定有效夸克 UID',
                        style: TextStyle(fontSize: 12, color: subColor),
                      ),
                    ],
                  ),
                ),
                // 重新登录与退出
                HoverScaleTextButton(
                  onPressed: () => QuarkConnectionDialog.show(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('账号设置', style: TextStyle(color: accentColor, fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 4),
                HoverScaleTextButton(
                  onPressed: _confirmLogout,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('退出登录', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ),
              ],
            ),
            if (total > 0) ...[
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('网盘存储空间', style: TextStyle(fontSize: 12, color: subColor)),
                  Text(
                    '${_formatBytes(used)} / ${_formatBytes(total)} (${(ratio * 100).toStringAsFixed(1)}%)',
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: isDark
                      ? Colors.white.withOpacity(0.1)
                      : Colors.black.withOpacity(0.08),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    ratio > 0.9 ? Colors.redAccent : const Color(0xFF007AFF),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFolderCard(
    QuarkMountFolder folder,
    ThemeData theme,
    Color accentColor,
  ) {
    final subColor = theme.colorScheme.onSurface.withOpacity(0.65);
    final isScanningThis = QuarkService.instance.scanningFolderId == folder.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LibraryManagementCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.folder_rounded, color: accentColor, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '路径: ${folder.path}  •  已发现 ${folder.videoCount} 个视频',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: subColor),
                    ),
                    if (folder.lastScanTime != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '上次刮削: ${folder.lastScanTime!.toLocal().toString().split('.').first}',
                          style: TextStyle(fontSize: 11, color: subColor.withOpacity(0.8)),
                        ),
                      ),
                    if (isScanningThis && QuarkService.instance.scanningStatus.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                QuarkService.instance.scanningStatus,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: accentColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isScanningThis)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: () => _startScanFolder(folder),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor.withOpacity(0.12),
                    foregroundColor: accentColor,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('扫描刮削', style: TextStyle(fontSize: 12)),
                ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: Colors.redAccent.withOpacity(0.85),
                tooltip: '解除挂载',
                onPressed: () => _confirmRemoveFolder(folder),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
