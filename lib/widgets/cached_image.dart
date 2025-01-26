import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class CachedImage extends StatelessWidget {
  final String? imageUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final BorderRadius? borderRadius;
  final Color? backgroundColor;
  final Widget? placeholder;
  final Widget? errorWidget;
  final bool circle;

  const CachedImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.borderRadius,
    this.backgroundColor,
    this.placeholder,
    this.errorWidget,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return _buildPlaceholder();
    }

    Widget image = CachedNetworkImage(
      imageUrl: imageUrl!,
      width: width,
      height: height,
      fit: fit ?? BoxFit.cover,
      placeholder: (context, url) => _buildPlaceholder(),
      errorWidget: (context, url, error) => _buildErrorWidget(),
      fadeInDuration: const Duration(milliseconds: 300),
    );

    // 圆形或圆角
    if (circle || borderRadius != null) {
      image = ClipRRect(
        borderRadius: circle 
          ? BorderRadius.circular(width != null ? width! / 2 : height! / 2)
          : borderRadius ?? BorderRadius.zero,
        child: image,
      );
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: backgroundColor ?? Theme.of(context).cardColor,
        borderRadius: circle 
          ? BorderRadius.circular(width != null ? width! / 2 : height! / 2)
          : borderRadius,
      ),
      child: image,
    );
  }

  Widget _buildPlaceholder() {
    return placeholder ?? Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.2),
        borderRadius: circle 
          ? BorderRadius.circular(width != null ? width! / 2 : height! / 2)
          : borderRadius,
      ),
      child: Icon(
        Icons.account_circle_sharp,
        size: (width ?? height ?? 24) * 0.5,
        color: Colors.grey.withValues(alpha: .3),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return errorWidget ?? Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: .1),
        borderRadius: circle 
          ? BorderRadius.circular(width != null ? width! / 2 : height! / 2)
          : borderRadius,
      ),
      child: Icon(
        Icons.broken_image_outlined,
        size: (width ?? height ?? 24) * 0.5,
        color: Colors.grey.withValues(alpha: .3),
      ),
    );
  }
} 