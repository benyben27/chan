import 'package:chan/services/imageboard.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class ImageboardIcon extends StatelessWidget {
	final String? imageboardKey;
	final String? boardName;
	final double size;

	const ImageboardIcon({
		this.imageboardKey,
		this.boardName,
		this.size = 16,
		Key? key
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		Imageboard? imageboard = context.watch<Imageboard?>();
		if (imageboardKey != null) {
			imageboard = ImageboardRegistry.instance.getImageboard(imageboardKey!);
		}
		if (imageboard == null) {
			return Icon(CupertinoIcons.exclamationmark_triangle_fill, size: size);
		}
		Uri url = imageboard.site.iconUrl;
		bool clipOval = false;
		if (boardName != null) {
			final boardUrl = imageboard.persistence.getBoard(boardName!).icon;
			if (boardUrl != null) {
				url = boardUrl;
				clipOval = true;
			}
		}
		final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
		final child = ExtendedImage.network(
			url.toString(),
			headers: imageboard.site.getHeaders(url),
			cache: true,
			enableLoadState: false,
			filterQuality: FilterQuality.high,
			fit: BoxFit.contain,
			width: size,
			height: size,
			cacheWidth: cacheSize,
			cacheHeight: cacheSize,
		);
		if (clipOval) {
			return ClipOval(
				child: child
			);
		}
		return child;
	}
}