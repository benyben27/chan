import 'dart:io';
import 'dart:math' as math;

import 'package:chan/models/attachment.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/webm.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/rx_stream_builder.dart';
import 'package:chan/widgets/video_controls.dart';
import 'package:chan/widgets/viewers/viewer.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share/share.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

extension InvertBrightness on Brightness? {
	Brightness? get inverted {
		if (this == null) {
			return null;
		}
		return (this == Brightness.dark) ? Brightness.light : Brightness.dark;
	}
}

const double _THUMBNAIL_SIZE = 60;

class AttachmentStatus {

}

class AttachmentUnloadedStatus extends AttachmentStatus {
	
}

class AttachmentLoadingStatus extends AttachmentStatus {
	final double? progress;
	AttachmentLoadingStatus({this.progress});
}

class AttachmentUnavailableStatus extends AttachmentStatus {
	String cause;
	AttachmentUnavailableStatus(this.cause);
}

class AttachmentImageUrlAvailableStatus extends AttachmentStatus {
	final Uri url;
	AttachmentImageUrlAvailableStatus(this.url);
}

class AttachmentVideoAvailableStatus extends AttachmentStatus {
	final VideoPlayerController controller;
	AttachmentVideoAvailableStatus(this.controller);
}

class GalleryPage extends StatefulWidget {
	final List<Attachment> attachments;
	final Attachment? initialAttachment;
	final bool initiallyShowChrome;
	final ValueChanged<Attachment>? onChange;
	final List<int> semanticParentIds;

	GalleryPage({
		required this.attachments,
		required this.initialAttachment,
		required this.semanticParentIds,
		this.initiallyShowChrome = false,
		this.onChange,
	});

	@override
	createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
	// Data
	late int currentIndex;
	Attachment get currentAttachment => widget.attachments[currentIndex];
	AttachmentStatus get currentAttachmentStatus => statuses[currentAttachment]!.value!;
	final Map<Attachment, BehaviorSubject<AttachmentStatus>> statuses = Map();
	final Map<Attachment, File> cachedFiles = Map();
	// View
	final ScrollController thumbnailScrollController = ScrollController();
	late final PageController pageController;
	final FocusNode keyboardShortcutFocusNode = FocusNode();
	late bool showChrome;
	final Key _pageControllerKey = GlobalKey();
	bool rotatedViewer = false;

	@override
	void initState() {
		super.initState();
		showChrome = widget.initiallyShowChrome;
		currentIndex = (widget.initialAttachment != null) ? widget.attachments.indexOf(widget.initialAttachment!) : 0;
		pageController = PageController(keepPage: true, initialPage: currentIndex);
		statuses.addEntries(widget.attachments.map((attachment) => MapEntry(attachment, BehaviorSubject()..add(AttachmentUnloadedStatus()))));
		statuses.entries.forEach((entry) {
			entry.value.listen((_) {
				if (currentAttachment == entry.key) {
					setState(() {});
				}
			});
		});
		if (context.read<Settings>().autoloadAttachments) {
			requestRealViewer(widget.attachments[currentIndex]);
		}
	}

	@override
	void didUpdateWidget(GalleryPage old) {
		super.didUpdateWidget(old);
		if (widget.initialAttachment != old.initialAttachment) {
			currentIndex = (widget.initialAttachment != null) ? widget.attachments.indexOf(widget.initialAttachment!) : 0;
		}
	}

	Future<Uri> _getGoodUrl(Attachment attachment) async {
		// Should check archives and send scaffold messages here
		final site = context.read<ImageboardSite>();
		final url = site.getAttachmentUrl(attachment);	
		final result = await site.client.head(url);
		if (result.statusCode == 200) {
			return url;
		}
		else {
			throw HTTPStatusException(result.statusCode);
		}
	}

	Future<void> requestRealViewer(Attachment attachment) async {
		try {
			if (attachment.type == AttachmentType.Image) {
				final provisionalStatus = AttachmentLoadingStatus(progress: 0);
				statuses[attachment]!.add(provisionalStatus);
				Future.delayed(const Duration(milliseconds: 500), () {
					if (statuses[attachment]!.value == provisionalStatus && mounted) {
						statuses[attachment]!.add(AttachmentLoadingStatus());
					}
				});
				final url = await _getGoodUrl(attachment);
				statuses[attachment]!.add(AttachmentImageUrlAvailableStatus(url));
			}
			else if (attachment.type == AttachmentType.WEBM) {
				statuses[attachment]!.add(AttachmentLoadingStatus());
				final url = await _getGoodUrl(attachment);
				final webm = WEBM(url);
				webm.status.listen((webmStatus) async {
					if (webmStatus is WEBMErrorStatus) {
						statuses[attachment]!.add(AttachmentUnavailableStatus(webmStatus.errorMessage));
					}
					else if (webmStatus is WEBMLoadingStatus) {
						statuses[attachment]!.add(AttachmentLoadingStatus(progress: webmStatus.progress));
					}
					else if (webmStatus is WEBMReadyStatus) {
						final controller = VideoPlayerController.file(webmStatus.file);
						await controller.initialize();
						await controller.setLooping(true);
						await controller.play();
						cachedFiles[attachment] = webmStatus.file;
						statuses[attachment]!.add(AttachmentVideoAvailableStatus(controller));
					}
				});
				webm.startProcessing();
			}
		}
		catch (e) {
			statuses[attachment]!.add(AttachmentUnavailableStatus(e.toString()));
		}
	}

	void _animateToPage(int index, {int milliseconds = 200}) {
		final attachment = widget.attachments[index];
		widget.onChange?.call(attachment);
		if (context.read<Settings>().autoloadAttachments && statuses[attachment]!.value is AttachmentUnloadedStatus) {
			requestRealViewer(widget.attachments[index]);
		}
		setState(() {
			if (milliseconds == 0) {
				pageController.jumpToPage(index);
			}
			else {
				pageController.animateToPage(
					index,
					duration: Duration(milliseconds: milliseconds),
					curve: Curves.ease
				);
			}
		});
	}

	void _onPageChanged(int index) {
		final attachment = widget.attachments[index];
		widget.onChange?.call(attachment);
		if (context.read<Settings>().autoloadAttachments && statuses[attachment]!.value is AttachmentUnloadedStatus) {
			requestRealViewer(widget.attachments[index]);
		}
		double centerPosition = ((_THUMBNAIL_SIZE + 12) * (index + 0.5)) - (thumbnailScrollController.position.viewportDimension / 2);
		bool shouldScrollLeft = (centerPosition > thumbnailScrollController.position.pixels) && (thumbnailScrollController.position.extentAfter > 0);
		bool shouldScrollRight = (centerPosition < thumbnailScrollController.position.pixels) && (thumbnailScrollController.position.extentBefore > 0);
		currentIndex = index;
		if (shouldScrollLeft || shouldScrollRight) {
			thumbnailScrollController.animateTo(
				centerPosition.clamp(0.0, thumbnailScrollController.position.maxScrollExtent),
				duration: const Duration(milliseconds: 200),
				curve: Curves.ease
			);
		}
		for (final status in statuses.entries) {
			if (status.value.value is AttachmentVideoAvailableStatus) {
				if (status.key == currentAttachment) {
					(status.value.value! as AttachmentVideoAvailableStatus).controller.play();
				}
				else {
					(status.value.value! as AttachmentVideoAvailableStatus).controller.pause();
				}
			}
		}
		setState(() {});
	}

	bool canShare(Attachment attachment) {
		return cachedFiles[attachment] != null;
	}

	Future<void> share(Attachment attachment) async {
		final systemTempDirectory = await getTemporaryDirectory();
		final shareDirectory = await (new Directory(systemTempDirectory.path + '/sharecache')).create(recursive: true);
		final newFilename = currentAttachment.id.toString() + currentAttachment.ext.replaceFirst('webm', 'mp4');
		final renamedFile = await cachedFiles[currentAttachment]!.copy(shareDirectory.path.toString() + '/' + newFilename);
		await Share.shareFiles([renamedFile.path], subject: currentAttachment.filename);
	}

	void _toggleChrome() {
		setState(() {
			showChrome = !showChrome;
		});
	}

	@override
	Widget build(BuildContext context) {
		return ExtendedImageSlidePage(
			resetPageDuration: const Duration(milliseconds: 100),
			slidePageBackgroundHandler: (offset, size) {
				return Colors.black.withOpacity((0.38 * (1 - (offset.dx / size.width).abs()) * (1 - (offset.dy / size.height).abs())).clamp(0, 1));
			},
			child: CupertinoTheme(
				data: CupertinoThemeData(brightness: Brightness.dark, primaryColor: Colors.white),
				child: CupertinoPageScaffold(
					backgroundColor: Colors.transparent,
					navigationBar: showChrome ? CupertinoNavigationBar(
						brightness: Platform.isAndroid ? CupertinoTheme.of(context).brightness.inverted : null,
						middle: Text(currentAttachment.filename),
						backgroundColor: Colors.black38,
						trailing: Row(
							mainAxisSize: MainAxisSize.min,
							children: [
								CupertinoButton(
									padding: EdgeInsets.zero,
									child: Transform(
										alignment: Alignment.center,
										transform: rotatedViewer ? Matrix4.identity() : Matrix4.rotationY(math.pi),
										child: Icon(Icons.rotate_90_degrees_ccw)
									),
									onPressed: () {
										setState(() {
											rotatedViewer = !rotatedViewer;
										});
									}
								),
								CupertinoButton(
									padding: EdgeInsets.zero,
									child: Icon(Icons.ios_share),
									onPressed: canShare(currentAttachment) ? () => share(currentAttachment) : null
								)
							]
						)
					) : null,
					child: Container(
							height: double.infinity,
							color: Colors.transparent,
							child: RawKeyboardListener(
								autofocus: true,
								focusNode: keyboardShortcutFocusNode,
								onKey: (event) {
									if (event is RawKeyDownEvent) {
										if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
											if (currentIndex > 0) {
												_animateToPage(currentIndex - 1, milliseconds: 0);
											}
										}
										else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
											if (currentIndex < widget.attachments.length - 1) {
												_animateToPage(currentIndex + 1, milliseconds: 0);
											}
										}
										else if (event.logicalKey == LogicalKeyboardKey.keyG) {
											Navigator.of(context).pop();
										}
										else if (event.logicalKey == LogicalKeyboardKey.space) {
											_toggleChrome();
										}
									}
								},
								child: Stack(
									children: [
										KeyedSubtree(
											key: _pageControllerKey,
											child: ExtendedImageGesturePageView.builder(
												onPageChanged: _onPageChanged,
												controller: pageController,
												itemCount: widget.attachments.length,
												itemBuilder: (context, index) {
													final attachment = widget.attachments[index];
													return RxStreamBuilder<AttachmentStatus>(
														stream: statuses[attachment]!,
														builder: (context, snapshot) {
															final status = snapshot.data!;
															return GestureDetector(
																child: RotatedBox(
																	quarterTurns: rotatedViewer ? 1 : 0,
																	child: AttachmentViewer(
																		attachment: attachment,
																		status: status,
																		backgroundColor: Colors.transparent,
																		autoload: attachment == currentAttachment,
																		tag: AttachmentSemanticLocation(
																			attachment: attachment,
																			semanticParents: widget.semanticParentIds
																		),
																		onCacheCompleted: (file) {
																			setState(() {
																				cachedFiles[attachment] = file;
																			});
																		}
																	)
																),
																onTap: (status is AttachmentUnloadedStatus) ? () {
																	if (status is AttachmentUnloadedStatus) {
																		requestRealViewer(attachment);
																	}
																} : _toggleChrome
															);
														}
													);
												}
											)
										),
										Visibility(
											visible: showChrome,
											maintainState: true,
											child: SafeArea(
												child: Column(
													mainAxisAlignment: MainAxisAlignment.end,
													crossAxisAlignment: CrossAxisAlignment.center,
													children: [
														if (currentAttachmentStatus is AttachmentVideoAvailableStatus) Container(
															decoration: BoxDecoration(
																color: Colors.black38
															),
															child: VideoControls(
																controller: (currentAttachmentStatus as AttachmentVideoAvailableStatus).controller,
																onUpdate: () => setState(() {})
															)
														),
														Container(
															decoration: BoxDecoration(
																color: Colors.black38
															),
															height: _THUMBNAIL_SIZE + 8,
															child: ListView.builder(
																controller: thumbnailScrollController,
																itemCount: widget.attachments.length,
																scrollDirection: Axis.horizontal,
																itemBuilder: (context, index) {
																	final attachment = widget.attachments[index];
																	return GestureDetector(
																		onTap: () => _animateToPage(index),
																		child: Container(
																			decoration: BoxDecoration(
																				color: Colors.transparent,
																				borderRadius: BorderRadius.all(Radius.circular(4)),
																				border: Border.all(color: attachment == currentAttachment ? Colors.blue : Colors.transparent, width: 2)
																			),
																			margin: const EdgeInsets.all(4),
																			child: AttachmentThumbnail(
																				attachment: widget.attachments[index],
																				width: _THUMBNAIL_SIZE,
																				height: _THUMBNAIL_SIZE
																			)
																		)
																	);
																}
															)
														)
													]
												)
											)
										)
									]
								)
							)
						)
				)
			)
		);
	}

	@override
	void dispose() {
		super.dispose();
		for (final status in statuses.values) {
			if (status.value is AttachmentVideoAvailableStatus) {
				(status.value as AttachmentVideoAvailableStatus).controller.dispose();
			}
			status.close();
		}
	}
}