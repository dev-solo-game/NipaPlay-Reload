import 'package:flutter/material.dart';
import 'package:nipaplay/themes/cupertino/widgets/player_menu/adaptive_player_menu_primitives.dart';
import 'package:nipaplay/utils/video_player_state.dart';

import 'blur_snackbar.dart';
import 'player_menu_theme.dart';

class QuarkQualityOptions extends StatelessWidget {
  const QuarkQualityOptions({
    super.key,
    required this.videoState,
    this.adaptive = false,
  });

  final VideoPlayerState videoState;
  final bool adaptive;

  Future<void> _select(BuildContext context, String resolution) async {
    try {
      await videoState.selectQuarkResolution(resolution);
    } catch (_) {
      if (context.mounted) BlurSnackBar.show(context, '切换夸克清晰度失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: videoState,
      builder: (context, _) {
        final switching = videoState.switchingQuarkQuality;
        final colors = PlayerMenuTheme.colorsOf(context);
        final rows = <Widget>[
          if (switching)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('正在切换清晰度…'),
            ),
        ];
        for (final variant in videoState.quarkVideoVariants) {
          final selected =
              variant.resolution == videoState.currentQuarkResolution;
          final onTap = selected || switching
              ? null
              : () => _select(context, variant.resolution);
          final check = selected
              ? Icon(Icons.check_rounded, color: colors.accent, size: 19)
              : null;
          rows.add(
            adaptive
                ? AdaptivePlayerMenuTile(
                    title: Text(variant.label),
                    trailing: check,
                    onTap: onTap,
                  )
                : ListTile(
                    title: Text(variant.label),
                    textColor: colors.foreground,
                    selectedColor: colors.selectedForeground,
                    selectedTileColor: colors.selectedBackground,
                    selected: selected,
                    trailing: check,
                    onTap: onTap,
                  ),
          );
        }
        return adaptive
            ? AdaptivePlayerMenuSection(children: rows)
            : Material(
                color: Colors.transparent,
                child: Column(mainAxisSize: MainAxisSize.min, children: rows),
              );
      },
    );
  }
}
