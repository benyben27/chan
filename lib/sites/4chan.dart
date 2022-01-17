// ignore_for_file: file_names
import 'dart:io';
import 'dart:math';

import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/search.dart';
import 'package:chan/services/persistence.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' as dom;
import 'package:html_unescape/html_unescape_small.dart';
import 'package:linkify/linkify.dart';
import 'imageboard_site.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/widgets/post_spans.dart';

class _ThreadCacheEntry {
	final Thread thread;
	final String lastModified;
	_ThreadCacheEntry({
		required this.thread,
		required this.lastModified
	});
}

const _catalogCacheLifetime = Duration(seconds: 10);

class _CatalogCacheEntry {
	final int page;
	final DateTime lastModified;
	final int replyCount;

	_CatalogCacheEntry({
		required this.page,
		required this.lastModified,
		required this.replyCount
	});
}

class _CatalogCache {
	final DateTime lastUpdated;
	final Map<int, _CatalogCacheEntry> entries;

	_CatalogCache({
		required this.lastUpdated,
		required this.entries
	});
}

class Site4Chan extends ImageboardSite {
	@override
	final String name;
	final String baseUrl;
	final String staticUrl;
	final String sysUrl;
	final String apiUrl;
	@override
	final String imageUrl;
	final String captchaKey;
	List<ImageboardBoard>? _boards;
	static final unescape = HtmlUnescape();
	final Map<String, _ThreadCacheEntry> _threadCache = {};
	final Map<String, _CatalogCache> _catalogCaches = {};
	final _lastActionTime = {
		ImageboardAction.postReply: <String, DateTime>{},
		ImageboardAction.postReplyWithImage: <String, DateTime>{},
		ImageboardAction.postThread: <String, DateTime>{},
	};

	static List<PostSpan> parsePlaintext(String text) {
		return linkify(text, linkifiers: [const UrlLinkifier()]).map((elem) {
			if (elem is UrlElement) {
				return PostLinkSpan(elem.url);
			}
			else {
				return PostTextSpan(elem.text);
			}
		}).toList();
	}

	static PostSpan makeSpan(String board, int threadId, String data) {
		final doc = parse(data.replaceAll('<wbr>', '').replaceAllMapped(RegExp(r'\[math\](.+?)\[\/math\]'), (match) {
			return '<tex>${match.group(1)!}</tex>';
		}).replaceAllMapped(RegExp(r'\[eqn\](.+?)\[\/eqn\]'), (match) {
			return '<tex>${match.group(1)!}</tex>';
		}));
		final List<PostSpan> elements = [];
		int spoilerSpanId = 0;
		for (final node in doc.body!.nodes) {
			if (node is dom.Element) {
				if (node.localName == 'br') {
					elements.add(PostTextSpan('\n'));
				}
				else if (node.localName == 'tex') {
					elements.add(PostTeXSpan(node.innerHtml));
				}
				else if (node.localName == 'a' && node.classes.contains('quotelink')) {
					if (node.attributes['href']!.startsWith('#p')) {
						elements.add(PostQuoteLinkSpan(
							board: board,
							threadId: threadId,
							postId: int.parse(node.attributes['href']!.substring(2)),
							dead: false
						));
					}
					else if (node.attributes['href']!.contains('#p')) {
						// href looks like '/tv/thread/123456#p123457'
						final parts = node.attributes['href']!.split('/');
						final threadIndex = parts.indexOf('thread');
						final ids = parts[threadIndex + 1].split('#p');
						elements.add(PostQuoteLinkSpan(
							board: parts[threadIndex - 1],
							threadId: int.parse(ids[0]),
							postId: int.parse(ids[1]),
							dead: false
						));
					}
					else {
						// href looks like '//boards.4chan.org/pol/'
						final parts = node.attributes['href']!.split('/');
						final catalogSearchMatch = RegExp(r'^catalog#s=(.+)$').firstMatch(parts.last);
						if (catalogSearchMatch != null) {
							elements.add(PostCatalogSearchSpan(board: board, query: catalogSearchMatch.group(1)!));
						}
						else {
							elements.add(PostBoardLink(parts[parts.length - 2]));
						}
					}
				}
				else if (node.localName == 'span') {
					if (node.attributes['class']?.contains('deadlink') ?? false) {
						final parts = node.innerHtml.replaceAll('&gt;', '').split('/');
						elements.add(PostQuoteLinkSpan(
							board: (parts.length > 2) ? parts[1] : board,
							postId: int.parse(parts.last),
							dead: true
						));
					}
					else if (node.attributes['class']?.contains('quote') ?? false) {
						elements.add(PostQuoteSpan(makeSpan(board, threadId, node.innerHtml)));
					}
					else {
						elements.add(PostTextSpan(node.text));
					}
				}
				else if (node.localName == 's') {
					elements.add(PostSpoilerSpan(makeSpan(board, threadId, node.innerHtml), spoilerSpanId++));
				}
				else if (node.localName == 'pre') {
					elements.add(PostCodeSpan(unescape.convert(node.innerHtml.replaceFirst(RegExp(r'<br>$'), '').replaceAll('<br>', '\n'))));
				}
				else {
					elements.addAll(parsePlaintext(node.text));
				}
			}
			else {
				elements.addAll(parsePlaintext(node.text ?? ''));
			}
		}
		return PostNodeSpan(elements);
	}

	ImageboardFlag? _makeFlag(dynamic data) {
		if (data['country'] != null) {
			return ImageboardFlag(
				name: data['country_name'],
				imageUrl: Uri.https(staticUrl, '/image/country/${data['country'].toLowerCase()}.gif').toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
		else if (data['troll_country'] != null) {
			return ImageboardFlag(
				name: data['country_name'],
				imageUrl: Uri.https(staticUrl, '/image/country/troll/${data['troll_country'].toLowerCase()}.gif').toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
		return null;
	}

	Post _makePost(String board, int threadId, dynamic data) {
		return Post(
			board: board,
			text: data['com'] ?? '',
			name: data['name'] ?? '',
			time: DateTime.fromMillisecondsSinceEpoch(data['time'] * 1000),
			id: data['no'],
			threadId: threadId,
			attachment: _makeAttachment(board, threadId, data),
			attachmentDeleted: data['filedeleted'] == 1,
			spanFormat: PostSpanFormat.chan4,
			flag: _makeFlag(data),
			posterId: data['id']
		);
	}
	Attachment? _makeAttachment(String board, int threadId, dynamic data) {
		if (data['tim'] != null) {
			final int id = data['tim'];
			final String ext = data['ext'];
			return Attachment(
				id: id,
				type: data['ext'] == '.webm' ? AttachmentType.webm : AttachmentType.image,
				filename: unescape.convert(data['filename'] ?? '') + (data['ext'] ?? ''),
				ext: ext,
				board: board,
				url: Uri.https(imageUrl, '/$board/$id$ext'),
				thumbnailUrl: Uri.https(imageUrl, '/$board/${id}s.jpg'),
				md5: data['md5'],
				spoiler: data['spoiler'] == 1,
				width: data['w'],
				height: data['h'],
				threadId: threadId
			);
		}
		return null;
	}

	Future<int?> _getThreadPage(ThreadIdentifier thread) async {
		final now = DateTime.now();
		if (_catalogCaches[thread.board] == null || now.difference(_catalogCaches[thread.board]!.lastUpdated).compareTo(_catalogCacheLifetime) > 0) {
			final response = await client.get(Uri.https(apiUrl, '/${thread.board}/catalog.json').toString(), options: Options(
				validateStatus: (x) => true
			));
			if (response.statusCode != 200) {
				if (response.statusCode == 404) {
					return Future.error(BoardNotFoundException(thread.board));
				}
				else {
					return Future.error(HTTPStatusException(response.statusCode!));
				}
			}
			final Map<int, _CatalogCacheEntry> entries = {};
			for (final page in response.data) {
				for (final threadData in page['threads']) {
					entries[threadData['no']] = _CatalogCacheEntry(
						page: page['page'],
						replyCount: threadData['replies'],
						lastModified: DateTime.fromMillisecondsSinceEpoch(threadData['last_modified'] * 1000)
					);
				}
			}
			_catalogCaches[thread.board] = _CatalogCache(
				lastUpdated: now,
				entries: entries
			);
		}
		return _catalogCaches[thread.board]!.entries[thread.id]?.page;
	}

	@override
	Future<Thread> getThread(ThreadIdentifier thread) async {
		Map<String, String>? headers;
		if (_threadCache['${thread.board}/${thread.id}'] != null) {
			headers = {
				'If-Modified-Since': _threadCache['${thread.board}/${thread.id}']!.lastModified
			};
		}
		final response = await client.get(
			Uri.https(apiUrl,'/${thread.board}/thread/${thread.id}.json').toString(),
			options: Options(
				headers: headers,
				validateStatus: (x) => true
			)
		);
		if (response.statusCode == 200) {
			final data = response.data;
			final String? title = data['posts']?[0]?['sub'];
			final output = Thread(
				board: thread.board,
				isDeleted: false,
				replyCount: data['posts'][0]['replies'],
				imageCount: data['posts'][0]['images'],
				isArchived: (data['posts'][0]['archived'] ?? 0) == 1,
				posts: (data['posts'] ?? []).map<Post>((postData) {
					return _makePost(thread.board, thread.id, postData);
				}).toList(),
				id: data['posts'][0]['no'],
				attachment: _makeAttachment(thread.board, thread.id, data['posts'][0]),
				attachmentDeleted: data['posts'][0]['filedeleted'] == 1,
				title: (title == null) ? null : unescape.convert(title),
				isSticky: data['posts'][0]['sticky'] == 1,
				time: DateTime.fromMillisecondsSinceEpoch(data['posts'][0]['time'] * 1000),
				flag: _makeFlag(data['posts'][0]),
				currentPage: await _getThreadPage(thread),
				uniqueIPCount: data['posts'][0]['unique_ips'],
				customSpoilerId: data['posts'][0]['custom_spoiler']
			);
			_threadCache['${thread.board}/${thread.id}'] = _ThreadCacheEntry(
				thread: output,
				lastModified: response.headers.value('last-modified')!
			);
			if (output.attachment != null) {
				await ensureCookiesMemoized(output.attachment!.url);
				await ensureCookiesMemoized(output.attachment!.thumbnailUrl);
			}
		}
		else if (!(response.statusCode == 304 && headers != null)) {
			if (response.statusCode == 404) {
				return Future.error(ThreadNotFoundException(thread));
			}
			return Future.error(HTTPStatusException(response.statusCode!));
		}
		_threadCache['${thread.board}/${thread.id}']!.thread.currentPage = await _getThreadPage(thread);
		return _threadCache['${thread.board}/${thread.id}']!.thread;
	}

	@override
	Future<Post> getPost(String board, int id) async {
		throw Exception('Not implemented');
	}

	@override
	Future<List<Thread>> getCatalog(String board) async {
		final response = await client.get(Uri.https(apiUrl, '/$board/catalog.json').toString(), options: Options(
			validateStatus: (x) => true
		));
		if (response.statusCode != 200) {
			if (response.statusCode == 404) {
				return Future.error(BoardNotFoundException(board));
			}
			else {
				return Future.error(HTTPStatusException(response.statusCode!));
			}
		}
		final List<Thread> threads = [];
		for (final page in response.data) {
			for (final threadData in page['threads']) {
				final String? title = threadData['sub'];
				final int threadId = threadData['no'];
				final Post threadAsPost = _makePost(board, threadId, threadData);
				Thread thread = Thread(
					board: board,
					id: threadId,
					replyCount: threadData['replies'],
					imageCount: threadData['images'],
					attachment: _makeAttachment(board, threadId, threadData),
					posts: [threadAsPost],
					title: (title == null) ? null : unescape.convert(title),
					isSticky: threadData['sticky'] == 1,
					time: DateTime.fromMillisecondsSinceEpoch(threadData['time'] * 1000),
					flag: _makeFlag(threadData),
					currentPage: page['page']
				);
				threads.add(thread);
			}
		}
		return threads;
	}
	Future<List<ImageboardBoard>> _getBoards() async {
		final response = await client.get(Uri.https(apiUrl, '/boards.json').toString());
		return (response.data['boards'] as List<dynamic>).map((board) {
			return ImageboardBoard(
				name: board['board'],
				title: board['title'],
				isWorksafe: board['ws_board'] == 1,
				webmAudioAllowed: board['webm_audio'] == 1,
				maxCommentCharacters: board['max_comment_chars'],
				maxImageSizeBytes: board['max_filesize'],
				maxWebmSizeBytes: board['max_webm_filesize'],
				maxWebmDurationSeconds: board['max_webm_duration'],
				threadCommentLimit: board['bump_limit'],
				threadImageLimit: board['image_limit'],
				pageCount: board['pages'],
				threadCooldown: board['cooldowns']?['threads'],
				replyCooldown: board['cooldowns']?['replies'],
				imageCooldown: board['cooldowns']?['images']
			);
		}).toList();
	}
	@override
	Future<List<ImageboardBoard>> getBoards() async {
		_boards ??= await _getBoards();
		return _boards!;
	}

	@override
	CaptchaRequest getCaptchaRequest(String board, [int? threadId]) {
		return Chan4CustomCaptchaRequest(
			challengeUrl: Uri.https(sysUrl, '/captcha', {
				'board': board,
				if (threadId != null) 'thread_id': threadId.toString()
			})
		);
	}

	
	Future<PostReceipt> _post({
		required String board,
		int? threadId,
		String name = '',
		String? subject,
		String options = '',
		required String text,
		required CaptchaSolution captchaSolution,
		File? file,
		String? overrideFilename
	}) async {
		final random = Random();
		final password = List.generate(64, (i) => random.nextInt(16).toRadixString(16)).join();
		final response = await client.post(
			Uri.https(sysUrl, '/$board/post').toString(),
			data: FormData.fromMap({
				if (threadId != null) 'resto': threadId.toString(),
				if (subject != null) 'sub': subject,
				'com': text,
				'mode': 'regist',
				'pwd': password,
				if (captchaSolution is RecaptchaSolution) 'g-recaptcha-response': captchaSolution.response
				else if (captchaSolution is Chan4CustomCaptchaSolution) ...{
					't-challenge': captchaSolution.challenge,
					't-response': captchaSolution.response
				},
				if (file != null) 'upfile': await MultipartFile.fromFile(file.path, filename: overrideFilename)
			}),
			options: Options(
				responseType: ResponseType.plain
			)
		);
		final document = parse(response.data);
		final metaTag = document.querySelector('meta[http-equiv="refresh"]');
		if (metaTag != null) {
			if (threadId == null) {
				_lastActionTime[ImageboardAction.postThread]![board] = DateTime.now();
			}
			else {
				_lastActionTime[ImageboardAction.postReply]![board] = DateTime.now();
				if (file != null) {
					_lastActionTime[ImageboardAction.postReplyWithImage]![board] = DateTime.now();
				}
			}
			return PostReceipt(
				id: int.parse(metaTag.attributes['content']!.split(RegExp(r'\/|(#p)')).last),
				password: password
			);
		}
		else {
			final errSpan = document.querySelector('#errmsg');
			if (errSpan != null) {
				throw PostFailedException(errSpan.text);
			}
			else {
				print(response.data);
				throw PostFailedException('Unknown error');
			}
		}
	}

	@override
	Future<PostReceipt> createThread({
		required String board,
		String name = '',
		String options = '',
		String subject = '',
		required String text,
		required CaptchaSolution captchaSolution,
		File? file,
		String? overrideFilename
	}) => _post(
		board: board,
		name: name,
		options: options,
		subject: subject,
		text: text,
		captchaSolution: captchaSolution,
		file: file,
		overrideFilename: overrideFilename
	);

	@override
	Future<PostReceipt> postReply({
		required ThreadIdentifier thread,
		String name = '',
		String options = '',
		required String text,
		required CaptchaSolution captchaSolution,
		File? file,
		String? overrideFilename
	}) => _post(
		board: thread.board,
		threadId: thread.id,
		name: name,
		options: options,
		text: text,
		captchaSolution: captchaSolution,
		file: file,
		overrideFilename: overrideFilename
	);

	@override
	DateTime? getActionAllowedTime(String board, ImageboardAction action) {
		final lastActionTime = _lastActionTime[action]![board];
		final b = persistence!.getBoard(board);
		switch (action) {
			case ImageboardAction.postReply:
				return lastActionTime?.add(Duration(seconds: b.replyCooldown ?? 0));
			case ImageboardAction.postReplyWithImage:
				return lastActionTime?.add(Duration(seconds: b.imageCooldown ?? 0));
			case ImageboardAction.postThread:
				return lastActionTime?.add(Duration(seconds: b.threadCooldown ?? 0));
		}
	}

	@override
	Future<void> deletePost(String board, PostReceipt receipt) async {
		final response = await client.post(
			Uri.https(sysUrl, '/$board/imgboard.php').toString(),
			data: FormData.fromMap({
				receipt.id.toString(): 'delete',
				'mode': 'usrdel',
				'pwd': receipt.password
			})
		);
		if (response.statusCode != 200) {
			throw HTTPStatusException(response.statusCode!);
		}
	}

	@override
	Future<ImageboardArchiveSearchResult> search(ImageboardArchiveSearchQuery query, {required int page}) async {
		String s = '';
		for (final archive in archives) {
			try {
				return await archive.search(query, page: page);
			}
			catch(e, st) {
				if (e is! BoardNotFoundException) {
					print('Error from ${archive.name}');
					print(e);
					print(st);
					s += '\n${archive.name}: $e';
				}
			}
		}
		throw Exception('Search failed - exhausted all archives$s');
	}

	@override
	String getWebUrl(String board, [int? threadId, int? postId]) {
		String webUrl = 'https://$baseUrl/$board/';
		if (threadId != null) {
			webUrl += 'thread/$threadId';
			if (postId != null) {
				webUrl += '#p$postId';
			}
		}
		return webUrl;
	}

	@override
	Uri getSpoilerImageUrl(Attachment attachment, {ThreadIdentifier? thread}) {
		final customSpoilerId = (thread == null) ? null : _threadCache['${thread.board}/${thread.id}']?.thread.customSpoilerId;
		if (customSpoilerId != null) {
			return Uri.https(staticUrl, '/image/spoiler-${attachment.board}$customSpoilerId.png');
		}
		else {
			return Uri.https(staticUrl, '/image/spoiler.png');
		}
	}

	@override
	Uri getPostReportUrl(String board, int id) {
		return Uri.https(sysUrl, '/$board/imgboard.php', {
			'mode': 'report',
			'no': id.toString()
		});
	}

	Site4Chan({
		required this.baseUrl,
		required this.staticUrl,
		required this.sysUrl,
		required this.apiUrl,
		required this.imageUrl,
		required this.name,
		required this.captchaKey,
		List<ImageboardSiteArchive> archives = const []
	}) : super(archives);
}