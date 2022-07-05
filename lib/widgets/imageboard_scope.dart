import 'package:chan/services/imageboard.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class ImageboardScope extends StatelessWidget {
	final Widget child;
	final String? imageboardKey;
	final Imageboard? imageboard;

	const ImageboardScope({
		required this.child,
		required this.imageboardKey,
		this.imageboard,
		Key? key
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		final b = imageboard ?? ImageboardRegistry.instance.getImageboardUnsafe(imageboardKey!);
		if (b == null) {
			return Center(
				child: ErrorMessageCard(
					'No such imageboard: $imageboardKey'
				)
			);
		}
		return AnimatedBuilder(
			animation: b,
			builder: (context, child) {
				if (b.boardsLoading) {
					return const Center(
						child: CupertinoActivityIndicator()
					);
				}
				else if (b.setupErrorMessage != null) {
					return Center(
						child: ErrorMessageCard('Error with imageboard $imageboardKey:\n${b.setupErrorMessage}')
					);
				}
				else if (b.boardFetchErrorMessage != null) {
					return Center(
						child: ErrorMessageCard('Error fetching boards for imageboard $imageboardKey:\n${b.boardFetchErrorMessage}', remedies: {
							'Retry': b.setupBoards
						})
					);
				}
				return child!;
			},
			child: MultiProvider(
				providers: [
					ChangeNotifierProvider.value(value: b),
					if (b.initialized) ...[
						Provider.value(value: b.site),
						ChangeNotifierProvider.value(value: b.persistence),
						ChangeNotifierProvider.value(value: b.threadWatcher),
						Provider.value(value: b.notifications)
					]
				],
				child: child
			)
		);
	}
}