import 'package:flutter/material.dart';
import 'package:nipaplay/models/quark/quark_file.dart';
import 'package:nipaplay/models/quark/quark_mount_folder.dart';
import 'package:nipaplay/services/quark/quark_service.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_dialog.dart';
import 'package:nipaplay/themes/nipaplay/widgets/hover_scale_text_button.dart';
import 'package:nipaplay/utils/app_accent_color.dart';
import 'package:uuid/uuid.dart';

/// 夸克网盘目录选择弹窗
class QuarkFolderPickerDialog extends StatefulWidget {
  const QuarkFolderPickerDialog({super.key});

  static Future<QuarkMountFolder?> show(BuildContext context) {
    return BlurDialog.show<QuarkMountFolder>(
      context: context,
      title: '选择要挂载的夸克目录',
      desktopMaxWidth: 560,
      desktopMaxHeightFactor: 0.8,
      phoneHeightRatio: 0.88,
      contentWidget: const QuarkFolderPickerDialog(),
    );
  }

  @override
  State<QuarkFolderPickerDialog> createState() =>
      _QuarkFolderPickerDialogState();
}

class _QuarkFolderPickerDialogState extends State<QuarkFolderPickerDialog> {
  final List<({String fid, String name})> _breadcrumbs = [
    (fid: '0', name: '夸克网盘根目录')
  ];

  List<QuarkFile> _folders = [];
  bool _isLoading = true;
  String? _errorMessage;

  ({String fid, String name}) get _current => _breadcrumbs.last;

  String get _currentPath {
    if (_breadcrumbs.length <= 1) return '/';
    return '/' + _breadcrumbs.skip(1).map((b) => b.name).join('/');
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentFolder();
  }

  Future<void> _loadCurrentFolder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final items = await QuarkService.instance.listFiles(_current.fid);
      if (!mounted) return;
      setState(() {
        _folders = items.where((f) => f.isDir).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  void _navigateToChild(QuarkFile folder) {
    setState(() {
      _breadcrumbs.add((fid: folder.fid, name: folder.fileName));
    });
    _loadCurrentFolder();
  }

  void _navigateToBreadcrumb(int index) {
    if (index >= _breadcrumbs.length - 1) return;
    setState(() {
      _breadcrumbs.removeRange(index + 1, _breadcrumbs.length);
    });
    _loadCurrentFolder();
  }

  void _navigateUp() {
    if (_breadcrumbs.length <= 1) return;
    setState(() {
      _breadcrumbs.removeLast();
    });
    _loadCurrentFolder();
  }

  void _confirmSelection() {
    final mountFolder = QuarkMountFolder(
      id: const Uuid().v4(),
      fid: _current.fid,
      name: _current.name == '夸克网盘根目录' ? '夸克根目录' : _current.name,
      path: _currentPath,
      addedAt: DateTime.now(),
      autoScan: true,
    );
    Navigator.of(context).pop(mountFolder);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = AppAccentColors.current;
    final textColor = theme.colorScheme.onSurface;
    final subTextColor = textColor.withOpacity(0.65);

    return SizedBox(
      height: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 面包屑导航与返回上一级
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                if (_breadcrumbs.length > 1)
                  IconButton(
                    icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                    tooltip: '返回上一级',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: _isLoading ? null : _navigateUp,
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: List.generate(_breadcrumbs.length, (index) {
                        final crumb = _breadcrumbs[index];
                        final isLast = index == _breadcrumbs.length - 1;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (index > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Text('/', style: TextStyle(color: subTextColor)),
                              ),
                            InkWell(
                              onTap: isLast || _isLoading
                                  ? null
                                  : () => _navigateToBreadcrumb(index),
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Text(
                                  crumb.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight:
                                        isLast ? FontWeight.w600 : FontWeight.normal,
                                    color: isLast ? accentColor : textColor,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 目录列表区域
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.colorScheme.onSurface.withOpacity(0.1),
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _buildListContent(theme, accentColor, textColor, subTextColor),
            ),
          ),
          const SizedBox(height: 12),

          // 底部操作栏
          Row(
            children: [
              Expanded(
                child: Text(
                  '挂载路径: $_currentPath',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: subTextColor),
                ),
              ),
              HoverScaleTextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text('取消', style: TextStyle(color: textColor)),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _confirmSelection,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(
                  _breadcrumbs.length == 1 ? '挂载整盘根目录' : '选择当前目录',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildListContent(
    ThemeData theme,
    Color accentColor,
    Color textColor,
    Color subTextColor,
  ) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 12),
            Text('正在加载网盘目录...', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 36),
              const SizedBox(height: 10),
              Text(
                '加载失败: $_errorMessage',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _loadCurrentFolder,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 40, color: subTextColor.withOpacity(0.5)),
            const SizedBox(height: 8),
            Text(
              '当前目录下没有子文件夹\n（可直接点击右下角挂载当前目录）',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: subTextColor),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _folders.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        indent: 48,
        color: theme.colorScheme.onSurface.withOpacity(0.06),
      ),
      itemBuilder: (context, index) {
        final folder = _folders[index];
        return ListTile(
          dense: true,
          leading: Icon(
            Icons.folder_rounded,
            color: accentColor.withOpacity(0.85),
            size: 26,
          ),
          title: Text(
            folder.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          trailing: const Icon(Icons.chevron_right_rounded, size: 20),
          onTap: () => _navigateToChild(folder),
        );
      },
    );
  }
}
