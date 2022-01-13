import 'dart:math';

import 'package:chan/models/attachment.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/thread_spans.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:chan/models/thread.dart';

class ThreadRow extends StatelessWidget {
	final Thread thread;
	final bool isSelected;
	final Function(Object?, StackTrace?)? onThumbnailLoadError;
	final ValueChanged<Attachment>? onThumbnailTap;
	final Iterable<int> semanticParentIds;
	final bool contentFocus;
	final bool showBoardName;
	const ThreadRow({
		required this.thread,
		required this.isSelected,
		this.onThumbnailLoadError,
		this.onThumbnailTap,
		this.contentFocus = false,
		this.showBoardName = false,
		this.semanticParentIds = const [],
		Key? key
	}) : super(key: key);

	String _timeDiff(DateTime value) {
		final diff = value.difference(DateTime.now()).abs();
		String timeDiff = '';
		if (diff.inDays > 365) {
			timeDiff = '${diff.inDays ~/ 365}y';
		}
		else if (diff.inDays > 30) {
			timeDiff = '${diff.inDays ~/ 30}m';
		}
		else if (diff.inDays > 0) {
			timeDiff = '${diff.inDays}d';
		}
		else if (diff.inHours > 0) {
			timeDiff = '${diff.inHours}h';
		}
		else if (diff.inMinutes > 0) {
			timeDiff = '${diff.inMinutes}m';
		}
		else {
			timeDiff = '${(diff.inMilliseconds / 1000).round()}s';
		}
		if (value.isAfter(DateTime.now())) {
			timeDiff = 'in $timeDiff';
		}
		return timeDiff;
	}

	@override
	Widget build(BuildContext context) {
		return ValueListenableBuilder(
			valueListenable: context.watch<Persistence>().listenForPersistentThreadStateChanges(thread.identifier),
			builder: (context, box, child) {
				final settings = context.watch<EffectiveSettings>();
				final threadState = context.watch<Persistence>().getThreadStateIfExists(thread.identifier);
				final _thread = threadState?.thread ?? thread;
				final int latestReplyCount = max(thread.replyCount, _thread.replyCount);
				final int latestImageCount = max(thread.imageCount, _thread.imageCount);
				int unseenReplyCount = 0;
				int unseenYouCount = 0;
				int unseenImageCount = 0;
				final grey = CupertinoTheme.of(context).primaryColorWithBrightness(0.6);
				Color? replyCountColor;
				Color? imageCountColor;
				Color? otherMetadataColor;
				if (threadState?.lastSeenPostId != null) {
					unseenReplyCount = (threadState?.unseenReplyCount ?? 0) + ((latestReplyCount + 1) - _thread.posts.length);
					unseenYouCount = threadState?.unseenReplyIdsToYou?.length ?? 0;
					unseenImageCount = (threadState?.unseenImageCount ?? 0) + ((latestImageCount + 1) - (threadState?.thread?.posts.where((x) => x.attachment != null).length ?? 0));
					replyCountColor = unseenReplyCount == 0 ? grey : null;
					imageCountColor = unseenImageCount == 0 ? grey : null;
					otherMetadataColor = unseenReplyCount == 0 && unseenImageCount == 0 ? grey : null;
				}
				Widget _makeCounters() => Container(
					decoration: BoxDecoration(
						borderRadius: const BorderRadius.only(topLeft: Radius.circular(8)),
						color: CupertinoTheme.of(context).scaffoldBackgroundColor,
						border: Border.all(color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2))
					),
					padding: const EdgeInsets.all(2),
					child: Wrap(
						verticalDirection: VerticalDirection.up,
						alignment: WrapAlignment.end,
						runSpacing: 4,
						crossAxisAlignment: WrapCrossAlignment.center,
						children: [
							const SizedBox(width: 4),
							if (_thread.isSticky) ... [
								Icon(Icons.push_pin, color: otherMetadataColor, size: 18),
								const SizedBox(width: 4),
							],
							if (_thread.isArchived) ... [
								Icon(Icons.archive, color: grey, size: 18),
								const SizedBox(width: 4),
							],
							FittedBox(
								fit: BoxFit.contain,
									child: Row(
									mainAxisSize: MainAxisSize.min,
									children: [
										Icon(Icons.access_time_filled, color: otherMetadataColor, size: 18),
										const SizedBox(width: 4),
										Text(_timeDiff(thread.time), style: TextStyle(color: otherMetadataColor)),
										const SizedBox(width: 2),
									]
								)
							),
							FittedBox(
								fit: BoxFit.contain,
								child: Row(
									mainAxisSize: MainAxisSize.min,
									children: [
										const SizedBox(width: 6),
										Icon(Icons.reply_rounded, size: 18, color: replyCountColor),
										const SizedBox(width: 4),
										Text((latestReplyCount - unseenReplyCount).toString(), style: TextStyle(color: threadState?.lastSeenPostId == null ? null : grey)),
										if (unseenReplyCount > 0) Text('+$unseenReplyCount'),
										if (unseenYouCount > 0) Text(' (+$unseenYouCount)', style: TextStyle(color: CupertinoTheme.of(context).textTheme.actionTextStyle.color)),
										const SizedBox(width: 2),
									]
								)
							),
							if (settings.showImageCountInCatalog) FittedBox(
								fit: BoxFit.contain,
								child: Row(
									mainAxisSize: MainAxisSize.min,
									children: [
										const SizedBox(width: 6),
										Icon(Icons.image, size: 18, color: imageCountColor),
										const SizedBox(width: 4),
										Text((latestImageCount - unseenImageCount).toString(), style: TextStyle(color: threadState?.lastSeenPostId == null ? null : grey)),
										if (unseenImageCount > 0) Text('+$unseenImageCount'),
										const SizedBox(width: 2)
									]
								)
							)
						]
					)
				);
				final borderRadius = contentFocus ? const BorderRadius.all(Radius.circular(8)) : BorderRadius.zero;
				return Container(
					decoration: BoxDecoration(
						color: isSelected ? CupertinoTheme.of(context).primaryColorWithBrightness(0.4) : CupertinoTheme.of(context).scaffoldBackgroundColor,
						border: contentFocus ? Border.all(color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2)) : null,
						borderRadius: borderRadius
					),
					padding: contentFocus ? null : const EdgeInsets.only(left: 8, top: 8),
					margin: contentFocus ? const EdgeInsets.all(4) : null,
					child: ClipRRect(
						borderRadius: borderRadius,
						child: Stack(
							fit: StackFit.passthrough,
							children: [
								if (contentFocus) ...[
									Column(
										mainAxisSize: MainAxisSize.min,
										children: [
											if (thread.attachment != null) Flexible(child: LayoutBuilder(
												builder: (context, constraints) {
													return Stack(
														children: [
															AttachmentThumbnail(
																width: constraints.maxWidth,
																height: constraints.maxHeight,
																fit: BoxFit.cover,
																attachment: _thread.attachment!,
																thread: _thread.identifier,
																onLoadError: onThumbnailLoadError,
																hero: null
															),
															if (_thread.attachment?.type == AttachmentType.webm) Positioned(
																bottom: 0,
																right: 0,
																child: Container(
																	decoration: BoxDecoration(
																		borderRadius: const BorderRadius.only(topLeft: Radius.circular(6)),
																		color: CupertinoTheme.of(context).scaffoldBackgroundColor,
																		border: Border.all(color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2))
																	),
																	padding: const EdgeInsets.all(2),
																	child: const Icon(Icons.play_arrow)
																)
															)
														]
													);
												}
											)),
											Expanded(
												child: Container(
													constraints: const BoxConstraints(maxHeight: 125, minHeight: 25),
													padding: const EdgeInsets.all(8),
													child: ChangeNotifierProvider<PostSpanZoneData>(
														create: (ctx) => PostSpanRootZoneData(
															thread: _thread,
															site: context.watch<ImageboardSite>()
														),
														child: Builder(
															builder: (ctx) => IgnorePointer(
																child: Text.rich(
																	TextSpan(
																		children: [
																			if (_thread.title != null) TextSpan(
																				text: settings.filterProfanity(_thread.title!) + '\n',
																				style: const TextStyle(fontWeight: FontWeight.bold)
																			),
																			_thread.posts[0].span.build(ctx, PostSpanRenderOptions()),
																			WidgetSpan(
																				child: Visibility(
																					visible: false,
																					maintainState: true,
																					maintainAnimation: true,
																					maintainSize: true,
																					child: _makeCounters()
																				)
																			)
																		]
																	),
																	overflow: TextOverflow.fade
																)
															)
														)
													)
												)
											)
										]
									)
								]
								else Row(
									crossAxisAlignment: CrossAxisAlignment.start,
									mainAxisSize: MainAxisSize.max,
									children: [
										if (_thread.attachment != null && settings.showImages(context, _thread.board)) Column(
											mainAxisSize: MainAxisSize.min,
											children: [
												Flexible(
													child: Container(
														padding: const EdgeInsets.only(bottom: 8),
														child: GestureDetector(
															child: Stack(
																alignment: Alignment.center,
																fit: StackFit.loose,
																children: [
																	AttachmentThumbnail(
																		onLoadError: onThumbnailLoadError,
																		attachment: _thread.attachment!,
																		thread: _thread.identifier,
																		hero: AttachmentSemanticLocation(
																			attachment: _thread.attachment!,
																			semanticParents: semanticParentIds
																		)
																	),
																	if (_thread.attachment?.type == AttachmentType.webm) SizedBox(
																		width: 75,
																		height: 75,
																		child: Center(
																			child: AspectRatio(
																				aspectRatio: (_thread.attachment!.width ?? 1) / (_thread.attachment!.height ?? 1),
																				child: Align(
																					alignment: Alignment.bottomRight,
																					child: Container(
																						decoration: BoxDecoration(
																							borderRadius: const BorderRadius.only(topLeft: Radius.circular(6)),
																							color: CupertinoTheme.of(context).scaffoldBackgroundColor,
																							border: Border.all(color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2))
																						),
																						padding: const EdgeInsets.all(1),
																						child: const Icon(Icons.play_arrow, size: 18)
																					)
																				)
																			)
																		)
																	)
																]
															),
															onTap: () => onThumbnailTap?.call(_thread.attachment!)
														)
													)
												)
											]
										)
										else if (_thread.attachmentDeleted) const Center(
											child: SizedBox(
												width: 75,
												height: 75,
												child: Icon(Icons.broken_image, size: 36)
											)
										),
										Expanded(
											child: Container(
												constraints: const BoxConstraints(maxHeight: 125, minHeight: 75),
												padding: const EdgeInsets.only(left: 8, right: 8),
												child: ChangeNotifierProvider<PostSpanZoneData>(
													create: (ctx) => PostSpanRootZoneData(
														thread: _thread,
														site: context.watch<ImageboardSite>()
													),
													child: Builder(
														builder: (ctx) => IgnorePointer(
															child: Text.rich(
																TextSpan(
																	children: [
																		TextSpan(
																			children: [
																				TextSpan(
																					text: settings.filterProfanity(_thread.posts[0].name),
																					style: const TextStyle(fontWeight: FontWeight.w600)
																				),
																				const TextSpan(text: ' '),
																				if (_thread.flag != null) ...[
																					FlagSpan(_thread.flag!),
																					const TextSpan(text: ' '),
																					TextSpan(
																						text: _thread.flag!.name,
																						style: const TextStyle(
																							fontStyle: FontStyle.italic
																						)
																					),
																					const TextSpan(text: ' ')
																				],
																				TextSpan(
																					text: formatTime(_thread.time)
																				),
																				const TextSpan(text: ' '),
																				TextSpan(
																					text: showBoardName ? 
																						'/${_thread.board}/${_thread.id}' :
																						_thread.id.toString(),
																					style: const TextStyle(color: Colors.grey)
																				),
																				const TextSpan(text: '\n')
																			]
																		),
																		if (_thread.title != null) TextSpan(
																			text: settings.filterProfanity(_thread.title!) + '\n',
																			style: const TextStyle(fontWeight: FontWeight.bold)
																		),
																		_thread.posts[0].span.build(ctx, PostSpanRenderOptions()),
																	]
																),
																overflow: TextOverflow.fade
															)
														)
													)
												)
											)
										)
									]
								),
								Positioned.fill(
									child: Align(
										alignment: Alignment.bottomRight,
										child: _makeCounters()
									)
								)
							]
						)
					)
				);
			}
		);
	}
}