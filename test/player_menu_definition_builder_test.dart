import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/quark/quark_playback_info.dart';
import 'package:nipaplay/player_abstraction/player_abstraction.dart';
import 'package:nipaplay/player_menu/player_menu_definition_builder.dart';
import 'package:nipaplay/player_menu/player_menu_models.dart';
import 'package:nipaplay/utils/video_player_state.dart';

class _FakeVideoPlayerState extends ChangeNotifier implements VideoPlayerState {
  _FakeVideoPlayerState({
    required this.playerValue,
    this.currentExternalSubtitlePathValue,
    this.currentVideoPathValue,
    this.quarkVideoVariants = const [],
  });

  final Player playerValue;
  final String? currentExternalSubtitlePathValue;
  final String? currentVideoPathValue;

  @override
  final List<QuarkVideoVariant> quarkVideoVariants;

  @override
  Player get player => playerValue;

  @override
  bool get hasVideo => true;

  @override
  String? get currentVideoPath => currentVideoPathValue;

  @override
  String? get currentExternalSubtitlePath => currentExternalSubtitlePathValue;

  @override
  int? get animeId => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayer implements Player {
  _FakePlayer({List<PlayerSubtitleStreamInfo>? subtitleTracks})
      : mediaInfoValue = PlayerMediaInfo(
          duration: 0,
          subtitle: subtitleTracks,
        );

  final PlayerMediaInfo mediaInfoValue;

  @override
  PlayerMediaInfo get mediaInfo => mediaInfoValue;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PlayerMenuDefinitionBuilder', () {
    test('includes the complete playback controls', () {
      final paneIds = _visiblePaneIds(subtitleTracks: const []);

      expect(paneIds, contains(PlayerMenuPaneId.seekStep));
      expect(paneIds, contains(PlayerMenuPaneId.playbackRate));
    });

    test('shows Quark quality selection only when there is a choice', () {
      final variants = [
        QuarkVideoVariant(
          resolution: 'high',
          url: Uri.parse('https://cdn.quark.cn/high'),
        ),
        QuarkVideoVariant(
          resolution: 'low',
          url: Uri.parse('https://cdn.quark.cn/low'),
        ),
      ];
      expect(
        _visiblePaneIds(subtitleTracks: const [], quarkVideoVariants: variants),
        isNot(contains(PlayerMenuPaneId.quarkQuality)),
      );
      expect(
        _visiblePaneIds(
          subtitleTracks: const [],
          currentVideoPath: 'quark://file/episode.mp4',
          quarkVideoVariants: [variants.first],
        ),
        isNot(contains(PlayerMenuPaneId.quarkQuality)),
      );
      expect(
        _visiblePaneIds(
          subtitleTracks: const [],
          currentVideoPath: 'quark://file/episode.mp4',
          quarkVideoVariants: variants,
        ),
        contains(PlayerMenuPaneId.quarkQuality),
      );
    });

    test('hides subtitle settings and list when no subtitle tracks exist', () {
      final paneIds = _visiblePaneIds(subtitleTracks: const []);

      expect(paneIds, isNot(contains(PlayerMenuPaneId.subtitleSettings)));
      expect(paneIds, contains(PlayerMenuPaneId.subtitleTracks));
      expect(paneIds, isNot(contains(PlayerMenuPaneId.subtitleList)));
    });

    test('shows subtitle settings and list when embedded subtitles exist', () {
      final paneIds = _visiblePaneIds(
        subtitleTracks: [
          PlayerSubtitleStreamInfo(
            title: '简体中文',
            language: 'zh-Hans',
            rawRepresentation: 'Subtitle: 简体中文',
          ),
        ],
      );

      expect(paneIds, contains(PlayerMenuPaneId.subtitleSettings));
      expect(paneIds, contains(PlayerMenuPaneId.subtitleTracks));
      expect(paneIds, contains(PlayerMenuPaneId.subtitleList));
    });

    test('shows subtitle settings and list when external subtitle is active',
        () {
      final paneIds = _visiblePaneIds(
        subtitleTracks: const [],
        currentExternalSubtitlePath: '/tmp/subtitle.ass',
      );

      expect(paneIds, contains(PlayerMenuPaneId.subtitleSettings));
      expect(paneIds, contains(PlayerMenuPaneId.subtitleTracks));
      expect(paneIds, contains(PlayerMenuPaneId.subtitleList));
    });
  });
}

List<PlayerMenuPaneId> _visiblePaneIds({
  required List<PlayerSubtitleStreamInfo>? subtitleTracks,
  String? currentExternalSubtitlePath,
  String? currentVideoPath,
  List<QuarkVideoVariant> quarkVideoVariants = const [],
}) {
  final videoState = _FakeVideoPlayerState(
    playerValue: _FakePlayer(subtitleTracks: subtitleTracks),
    currentExternalSubtitlePathValue: currentExternalSubtitlePath,
    currentVideoPathValue: currentVideoPath,
    quarkVideoVariants: quarkVideoVariants,
  );

  return PlayerMenuDefinitionBuilder(
    context: PlayerMenuContext(
      videoState: videoState,
      kernelType: PlayerKernelType.mediaKit,
    ),
  ).build().map((item) => item.paneId).toList(growable: false);
}
