import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/viewers/viewer.dart';
import 'package:flutter/material.dart';

import 'package:chan/models/attachment.dart';
import 'package:flutter/services.dart';
import 'package:extended_image/extended_image.dart';

class AttachmentGallery extends StatefulWidget {
	final List<Attachment> attachments;
	final ValueChanged<Attachment>? onChange;
	final ValueChanged<Attachment>? onTap;
	final Attachment? initialAttachment;
	final double thumbnailSize;
	final double height;
	final Color backgroundColor;
	final bool showThumbnails;

	const AttachmentGallery({
		required this.attachments,
		this.onChange,
		this.onTap,
		this.initialAttachment,
		this.thumbnailSize = 32,
		this.height = double.infinity,
		this.backgroundColor = Colors.transparent,
		this.showThumbnails = true,
		Key? key
	}) : super(key: key);

	@override
	createState() => _AttachmentGalleryState();
}

GlobalKey<_AttachmentGalleryState> galleryKey = GlobalKey();

class _AttachmentGalleryState extends State<AttachmentGallery> {
	late PageController _pageController;
	late ScrollController _scrollController;
	late List<Widget> pageWidgets;

	int _currentIndex = 0;
	FocusNode _focusNode = FocusNode();

	void _generatePageWidgets() {
		pageWidgets = widget.attachments.map((attachment) {
			return GestureDetector(
				child: AttachmentViewer(
					attachment: attachment,
					backgroundColor: widget.backgroundColor,
					autoload: attachment == widget.initialAttachment
				),
				onTap: () {
					widget.onTap?.call(attachment);
				}
			);
		}).toList();
	}

	@override
	void initState() {
		super.initState();
		if (widget.initialAttachment != null) {
			_currentIndex = widget.attachments.indexOf(widget.initialAttachment!);
		}
		_pageController = PageController(
			initialPage: _currentIndex
		);
		_scrollController = ScrollController();
		_generatePageWidgets();
	}

	@override void didUpdateWidget(AttachmentGallery old) {
		super.didUpdateWidget(old);
		if (widget.attachments != old.attachments) {
			_generatePageWidgets();
		}
		if (widget.initialAttachment != old.initialAttachment && widget.initialAttachment != null) {
			_currentIndex = widget.attachments.indexOf(widget.initialAttachment!);
		}
	}

	@override
	void dispose() {
		super.dispose();
		_pageController.dispose();
		_scrollController.dispose();
	}

	void _onPageChanged(int index) {
		widget.onChange?.call(widget.attachments[index]);
		double centerPosition = ((widget.thumbnailSize + 8) * (index - 1.5)) - (_scrollController.position.viewportDimension / 2);
		bool shouldScrollLeft = (centerPosition > _scrollController.position.pixels) && (_scrollController.position.extentAfter > 0);
		bool shouldScrollRight = (centerPosition < _scrollController.position.pixels) && (_scrollController.position.extentBefore > 0);
		setState(() {
			_currentIndex = index;
			if (shouldScrollLeft || shouldScrollRight) {
				_scrollController.animateTo(
					centerPosition.clamp(0.0, _scrollController.position.maxScrollExtent),
					duration: const Duration(milliseconds: 200),
					curve: Curves.ease
				);
			}
		});
	}

	void _selectImage(int index, {int milliseconds = 500}) {
		widget.onChange?.call(widget.attachments[index]);
		setState(() {
			if (milliseconds == 0) {
				_pageController.jumpToPage(index);
			}
			else {
				_pageController.animateToPage(
					index,
					duration: Duration(milliseconds: milliseconds),
					curve: Curves.ease
				);
			}
		});
	}

	@override
	Widget build(BuildContext context) {
		return Container(
			height: widget.height,
			color: widget.backgroundColor,
			child: RawKeyboardListener(
				autofocus: true,
				focusNode: _focusNode,
				onKey: (event) {
					if (event is RawKeyDownEvent) {
						if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
							if (_currentIndex > 0) {
								_selectImage(_currentIndex - 1, milliseconds: 0);
							}
						}
						else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
							if (_currentIndex < widget.attachments.length - 1) {
								_selectImage(_currentIndex + 1, milliseconds: 0);
							}
						}
						else if (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.keyG) {
							Navigator.of(context).pop();
						}
						else if (event.logicalKey == LogicalKeyboardKey.space) {
							widget.onTap?.call(widget.attachments[_currentIndex]);
						}
					}
				},
				child: Stack(
					children: [
						ExtendedImageGesturePageView(
							onPageChanged: _onPageChanged,
							controller: _pageController,
							children: pageWidgets
						),
						Visibility(
							visible: widget.showThumbnails,
							maintainState: true,
							child: SafeArea(
								child: Column(
									crossAxisAlignment: CrossAxisAlignment.center,
									children: [
										Expanded(
											child: Container()
										),
										Container(
											decoration: BoxDecoration(
												color: Colors.black38
											),
											height: widget.thumbnailSize + 8,
											child: ListView.builder(
												controller: _scrollController,
												itemCount: widget.attachments.length,
												scrollDirection: Axis.horizontal,
												itemBuilder: (context, index) {
													return GestureDetector(
														onTap: () {
															_selectImage(index);
														},
														child: Container(
															decoration: BoxDecoration(
																color: Colors.transparent,
																border: Border.all(color: index ==  _currentIndex ? Colors.blue : Colors.transparent, width: 2)
															),
															margin: const EdgeInsets.only(left: 4, right: 4),
															child: AttachmentThumbnail(
																attachment: widget.attachments[index],
																width: widget.thumbnailSize,
																height: widget.thumbnailSize,
																hero: false
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
		);
	}
}