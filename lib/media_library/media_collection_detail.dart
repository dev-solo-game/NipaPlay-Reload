import 'package:flutter/widgets.dart';
import 'package:nipaplay/models/bangumi_model.dart';
import 'package:nipaplay/models/playable_item.dart';
import 'package:nipaplay/models/shared_remote_library.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/themes/nipaplay/widgets/themed_anime_detail.dart';
import 'package:nipaplay/utils/media_source_utils.dart';
import 'package:path/path.dart' as p;

Future<WatchHistoryItem?> showMediaCollectionDetail(
  BuildContext context,
  WatchHistoryItem item, {
  required List<WatchHistoryItem> episodes,
  required String sourceLabel,
  BangumiAnime? detail,
}) {
  final byPath = {for (final episode in episodes) episode.filePath: episode};
  return ThemedAnimeDetail.show(
    context,
    item.animeId!,
    sharedSourceLabel: sourceLabel,
    sharedSummary: SharedRemoteAnimeSummary(
      animeId: item.animeId!,
      name: item.animeName,
      nameCn: detail?.nameCn,
      summary: detail?.summary,
      imageUrl: detail?.imageUrl.isNotEmpty == true
          ? detail!.imageUrl
          : item.thumbnailPath,
      lastWatchTime: item.lastWatchTime,
      episodeCount: episodes.length,
      hasMissingFiles: false,
    ),
    sharedEpisodeLoader: () async => [
      for (final episode in episodes)
        SharedRemoteEpisode(
          shareId: episode.filePath,
          title: episode.episodeTitle ?? episode.animeName,
          fileName:
              MediaSourceUtils.parseQuarkPath(episode.filePath)?.fileName ??
                  p.basename(episode.filePath),
          streamPath: episode.filePath,
          fileExists: true,
          animeId: episode.animeId,
          episodeId: episode.episodeId,
          duration: episode.duration,
          lastPosition: episode.lastPosition,
          progress: episode.watchProgress,
          lastWatchTime: episode.lastWatchTime,
          videoHash: episode.videoHash,
        ),
    ],
    sharedEpisodeBuilder: (episode) {
      final history = byPath[episode.shareId]!;
      return PlayableItem(
        videoPath: history.filePath,
        title: history.animeName,
        subtitle: history.episodeTitle,
        animeId: history.animeId,
        episodeId: history.episodeId,
        historyItem: history,
      );
    },
  );
}
