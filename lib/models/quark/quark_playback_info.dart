class QuarkVideoVariant {
  const QuarkVideoVariant({
    required this.resolution,
    required this.url,
    this.height,
  });

  final String resolution;
  final Uri url;
  final int? height;

  String get label {
    final height = this.height;
    if (height != null && height > 0) return '${height}p';
    return switch (resolution) {
      'low' => '流畅',
      'normal' => '标清',
      'high' => '高清',
      'super' => '超清',
      '2k' => '2K',
      '4k' => '4K',
      'origin' => '原画',
      _ => resolution,
    };
  }
}

class QuarkPlaybackInfo {
  const QuarkPlaybackInfo({
    required this.variants,
    required this.defaultResolution,
    this.videoAuthCookie,
  });

  final List<QuarkVideoVariant> variants;
  final String? defaultResolution;
  final String? videoAuthCookie;

  QuarkVideoVariant? variantFor(String? resolution) {
    for (final variant in variants) {
      if (variant.resolution == (resolution ?? defaultResolution)) {
        return variant;
      }
    }
    return resolution == null ? variants.firstOrNull : null;
  }
}
