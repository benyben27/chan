import 'dart:io';

import 'package:chan/services/media.dart';
import 'package:chan/widgets/thumbnail_image_provider.dart';
import 'package:flutter/material.dart';

class SavedAttachmentThumbnail extends StatefulWidget {
	final File file;
	final BoxFit? fit;
	final double? fontSize;
	const SavedAttachmentThumbnail({
		required this.file,
		this.fit,
		this.fontSize,
		Key? key
	}) : super(key: key);

	@override
	createState() => _SavedAttachmentThumbnailState();
}

class _SavedAttachmentThumbnailState extends State<SavedAttachmentThumbnail> {
	MediaScan? scan;

	String get ext => widget.file.path.split('.').last.toLowerCase();

	Future<void> _scan() async {
		if (ext == 'webm' || ext == 'mp4' || ext == 'mov') {
			scan = await MediaScan.scan(widget.file.uri);
			if (mounted) setState(() {});
		}
	}

	@override
	void initState() {
		super.initState();
		_scan();
	}

	@override
	void didUpdateWidget(SavedAttachmentThumbnail old) {
		super.didUpdateWidget(old);
		if (widget.file.path != old.file.path) {
			setState(() {
				scan = null;
			});
			_scan();
		}
	}

	@override
	Widget build(BuildContext context) {
		return LayoutBuilder(
			builder: (context, constraints) {
				Widget? label;
				if (scan != null) {
					final minutes = scan!.duration?.inMinutes ?? 0;
					final seconds = (scan!.duration?.inSeconds ?? 0) - (minutes * 60);
					if ((seconds + minutes) > 0) {
						label = Text('${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}', style: TextStyle(fontSize: widget.fontSize));
					}
				}
				if ((ext == 'webm' || ext == 'mp4' || ext == 'mov') && constraints.maxWidth > 50 && constraints.maxHeight > 50) {
					return IntrinsicWidth(
						child: Stack(
							alignment: Alignment.center,
							fit: StackFit.passthrough,
							children: [
								Image(
									image: ThumbnailImageProvider(
										file: widget.file
									),
									fit: widget.fit
								),
								if (label != null) Align(
									alignment: Alignment.bottomRight,
									child: Container(
										decoration: const BoxDecoration(
											borderRadius: BorderRadius.only(topLeft: Radius.circular(4)),
											color: Colors.black54
										),
										padding: const EdgeInsets.only(left: 4, top: 4, right: 2, bottom: 2),
										child: label
									)
								)
							]
						)
					);
				}
				else {
					return Image(
						image: ThumbnailImageProvider(file: widget.file),
						fit: widget.fit
					);
				}
			}
		);
	}
}