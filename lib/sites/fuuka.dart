import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' show parse, parseFragment;
import 'package:html/dom.dart' as dom;

class FuukaException implements Exception {
	String error;
	FuukaException(this.error);
	@override
	String toString() => 'Fuuka Error: $error';
}

final _threadLinkMatcher = RegExp(r'\/([a-zA-Z]+)\/thread\/S?(\d+)(#p(\d+))?$');
final _postLinkMatcher = RegExp(r'\/([a-zA-Z]+)\/post\/S?(\d+)$');
final _crossBoardLinkMatcher = RegExp(r'^>>>\/([A-Za-z]+)\/(\d+)$');

class FuukaArchive extends ImageboardSiteArchive {
	List<ImageboardBoard>? boards;
	final String baseUrl;
	@override
	final String name;
	static PostNodeSpan makeSpan(String board, int threadId, Map<String, int> linkedPostThreadIds, String data) {
		final body = parseFragment(data.trim());
		final List<PostSpan> elements = [];
		for (final node in body.nodes) {
			if (node is dom.Element) {
				if (node.localName == 'br') {
					elements.add(const PostLineBreakSpan());
				}
				else if (node.localName == 'span') {
					if (node.classes.contains('unkfunc')) {
						final match = _crossBoardLinkMatcher.firstMatch(node.innerHtml);
						if (match != null) {
							elements.add(PostQuoteLinkSpan.dead(board: match.group(1)!, postId: int.parse(match.group(2)!)));
						}
						else {
							elements.add(PostQuoteSpan(makeSpan(board, threadId, linkedPostThreadIds, node.innerHtml)));
						}
					}
					else {
						elements.addAll(Site4Chan.parsePlaintext(node.text));
					}
				}
				else if (node.localName == 'a') {
					final match = _postLinkMatcher.firstMatch(node.attributes['href']!);
					if (match != null) {
						final board = match.group(1)!;
						final postId = int.parse(match.group(2)!);
						elements.add(PostQuoteLinkSpan(
							board: board,
							postId: postId,
							threadId: linkedPostThreadIds['$board/$postId'] ?? threadId
						));
					}
					else {
						final match = RegExp(r'^#p(\d+)$').firstMatch(node.attributes['href']!);
						if (match != null) {
							elements.add(PostQuoteLinkSpan(
								board: board,
								postId: int.parse(match.group(1)!),
								threadId: threadId
							));
						}
						else {
							elements.addAll(Site4Chan.parsePlaintext(node.text));
						}
					}
				}
				else {
					elements.addAll(Site4Chan.parsePlaintext(node.text));
				}
			}
			else {
				elements.addAll(Site4Chan.parsePlaintext(node.text ?? ''));
			}
		}
		return PostNodeSpan(elements.toList(growable: false));
	}
	Attachment? _makeAttachment(dom.Element? element, int threadId) {
		if (element != null) {
			final String url = element.attributes['href']!;
			final urlMatch = RegExp(r'\/data\/([A-Za-z]+)\/img\/\d+\/\d+\/(\d+)(\..+)$').firstMatch(url)!;
			final ext = urlMatch.group(3)!;
			RegExpMatch? fileDetailsMatch;
			for (final span in element.parent!.querySelectorAll('span')) {
				fileDetailsMatch = RegExp(r'File: ([^ ]+) ([KMG]?B), (\d+)x(\d+), (.+)').firstMatch(span.text);
				if (fileDetailsMatch != null) {
					break;
				}
			}
			if (fileDetailsMatch == null) {
				throw FuukaException('Could not find atttachment details');
			}
			int multiplier = 1;
			if (fileDetailsMatch.group(2) == 'KB') {
				multiplier = 1024;
			}
			else if (fileDetailsMatch.group(2) == 'MB') {
				multiplier = 1024*1024;
			}
			else if (fileDetailsMatch.group(2) == 'GB') {
				multiplier = 1024*1024*1024;
			}
			return Attachment(
				board: urlMatch.group(1)!,
				id: urlMatch.group(2)!,
				filename: fileDetailsMatch.group(5)!,
				ext: ext,
				type: ext == '.webm' ? AttachmentType.webm : AttachmentType.image,
				url: 'https:$url',
				thumbnailUrl: 'https:${element.querySelector('.thumb')!.attributes['src']!}',
				md5: element.parent!.querySelectorAll('a').firstWhere((x) => x.text == 'View same').attributes['href']!.split('/').last,
				spoiler: false,
				width: int.parse(fileDetailsMatch.group(3)!),
				height: int.parse(fileDetailsMatch.group(4)!),
				sizeInBytes: (double.parse(fileDetailsMatch.group(1)!) * multiplier).round(),
				threadId: threadId
			);
		}
		return null;
	}
	Future<Post> _makePost(dom.Element element, {required bool interactive}) async {
		final thisLinkMatches = _threadLinkMatcher.firstMatch(element.querySelector('.js')!.attributes['href']!)!;
		final board = thisLinkMatches.group(1)!;
		final threadId = int.parse(thisLinkMatches.group(2)!);
		final postId = int.tryParse(thisLinkMatches.group(4) ?? '');
		final textNode = element.querySelector('p')!;
		final Map<String, int> linkedPostThreadIds = {};
		for (final link in textNode.querySelectorAll('a')) {
			final linkMatches = _postLinkMatcher.firstMatch(link.attributes['href']!);
			if (linkMatches != null) {
				final response = await client.head(Uri.https(baseUrl, link.attributes['href']!).toString(), options: Options(
					validateStatus: (x) => true,
					extra: {
						kInteractive: interactive
					}
				));
				linkedPostThreadIds['${linkMatches.group(1)!}/${linkMatches.group(2)!}'] = int.parse(_threadLinkMatcher.firstMatch(response.redirects.last.location.path)!.group(2)!);
			}
		}
		final a = _makeAttachment(element.querySelector('.thumb')?.parent, threadId);
		return Post(
			board: board,
			text: textNode.innerHtml,
			name: element.querySelector('span[itemprop="name"]')!.text,
			time: DateTime.fromMillisecondsSinceEpoch(int.parse(element.querySelector('.posttime')!.attributes['title']!)),
			id: postId ?? threadId,
			threadId: threadId,
			attachments: a == null ? [] : [a],
			spanFormat: PostSpanFormat.fuuka,
			foolfuukaLinkedPostThreadIds: linkedPostThreadIds
		);
	}
	@override
	Future<Post> getPost(String board, int id, {required bool interactive}) async {		
		final response = await client.getUri(Uri.https(baseUrl, '/$board/post/$id'), options: Options(
			extra: {
				kInteractive: interactive
			}
		));
		final thread = await _makeThread(response.data, board, int.parse(_threadLinkMatcher.firstMatch(response.redirects.last.location.path)!.group(2)!), interactive: interactive);
		return thread.posts.firstWhere((t) => t.id == id);
	}
	Future<Thread> _makeThread(dom.Element document, String board, int id, {required bool interactive}) async {
		final op = document.querySelector('#p$id');
		if (op == null) {
			throw FuukaException('OP was not archived');
		}
		final replies = document.querySelectorAll('.reply:not(.subreply)');
		final posts = (await Future.wait([op, ...replies].map((d) => _makePost(d, interactive: interactive)))).toList();
		final title = document.querySelector('.filetitle')?.text;
		return Thread(
			posts_: posts,
			id: id,
			time: posts[0].time,
			isSticky: false,
			title: title == 'post' ? null : title,
			board: board,
			attachments: posts[0].attachments,
			replyCount: posts.length - 1,
			isArchived: true,
			imageCount: posts.skip(1).expand((post) => post.attachments).length
		);
	}
	Future<Thread> getThreadContainingPost(String board, int id) async {
		throw Exception('Unimplemented');
	}
	@override
	Future<Thread> getThread(ThreadIdentifier thread, {ThreadVariant? variant, required bool interactive}) async {
		if (!(await getBoards(interactive: interactive)).any((b) => b.name == thread.board)) {
			throw BoardNotFoundException(thread.board);
		}
		final response = await client.getUri(
			Uri.https(baseUrl, '/${thread.board}/thread/${thread.id}', {
				'board': thread.board,
				'num': thread.id.toString()
			}),
			options: Options(
				extra: {
					kInteractive: interactive
				}
			)
		);
		return _makeThread(parse(response.data).body!, thread.board, thread.id, interactive: interactive);
	}
	@override
	Future<List<Thread>> getCatalogImpl(String board, {CatalogVariant? variant, required bool interactive}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/$board/'), options: Options(
			validateStatus: (x) => true,
			extra: {
				kInteractive: interactive
			}
		));
		final document = parse(response.data);
		int? threadId;
		dom.Element e = dom.Element.tag('div');
		final List<Thread> threads = [];
		for (final child in document.querySelector('.content')!.children) {
			if (child.localName == 'hr') {
				threads.add(await _makeThread(e, board, threadId!, interactive: interactive));
				e = dom.Element.tag('div');
			}
			else {
				if (child.localName == 'div') {
					final match = RegExp(r'^p(\d+)$').firstMatch(child.id);
					if (match != null) {
						threadId = int.parse(match.group(1)!);
					}
				}
				e.append(child);
			}
		}
		return threads;
	}

	@override
	Future<List<ImageboardBoard>> getBoards({required bool interactive}) async {
		return boards!;
	}

	String _formatDateForSearch(DateTime d) {
		return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
	}

	@override
	Future<ImageboardArchiveSearchResultPage> search(ImageboardArchiveSearchQuery query, {required int page, ImageboardArchiveSearchResultPage? lastResult}) async {
		if (query.postTypeFilter == PostTypeFilter.onlyStickies) {
			throw UnsupportedError('"Only stickies" filtering not supported in Fuuka search');
		}
		final knownBoards = await getBoards(interactive: true);
		final unknownBoards = query.boards.where((b) => !knownBoards.any((kb) => kb.name == b));
		if (unknownBoards.isNotEmpty) {
			throw BoardNotFoundException(unknownBoards.first);
		}
		final response = await client.getUri(
			Uri.https(baseUrl, '/${query.boards.first}/', {
				'task': 'search2',
				'ghost': 'yes',
				'search_text': query.query,
				if (query.postTypeFilter == PostTypeFilter.onlyOPs) 'search_op': 'op',
				if (query.startDate != null) 'search_datefrom': _formatDateForSearch(query.startDate!),
				if (query.endDate != null) 'search_dateto': _formatDateForSearch(query.endDate!),
				'offset': (page * 24).toString(),
				if (query.deletionStatusFilter == PostDeletionStatusFilter.onlyDeleted) 'search_del': 'yes'
				else if (query.deletionStatusFilter == PostDeletionStatusFilter.onlyNonDeleted) 'search_del': 'no',
				if (query.subject != null) 'search_subject': query.subject,
				if (query.name != null) 'search_username': query.name,
				if (query.trip != null) 'search_tripcode': query.trip
		}), options: Options(
			responseType: ResponseType.plain
		));
		if (response.statusCode != 200) {
			throw HTTPStatusException(response.statusCode!);
		}
		final document = parse(response.data);
		return ImageboardArchiveSearchResultPage(
			posts: (await Future.wait(document.querySelectorAll('.reply:not(.subreply)').map((d) => _makePost(d, interactive: true)))).map((p) => ImageboardArchiveSearchResult.post(p)).toList(),
			page: page,
			maxPage: 100,
			archive: this
		);
	}

	@override
	String getWebUrl(String board, [int? threadId, int? postId]) {
		String webUrl = 'https://$baseUrl/$board/';
		if (threadId != null) {
			webUrl += 'thread/$threadId';
			if (postId != null) {
				webUrl += '#$postId';
			}
		 }
		 return webUrl;
	}

	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(String url) async {
		final pattern = RegExp(r'https?:\/\/' + baseUrl + r'\/([^\/]+)\/thread\/(\d+)(#p(\d+))?');
		final match = pattern.firstMatch(url);
		if (match != null) {
			return BoardThreadOrPostIdentifier(match.group(1)!, int.parse(match.group(2)!), int.tryParse(match.group(4) ?? ''));
		}
		return null;
	}

	FuukaArchive({
		required this.baseUrl,
		required this.name,
		this.boards
	});

	@override
	bool operator == (Object other) => (other is FuukaArchive) && (other.baseUrl == baseUrl) && (other.name == name) && listEquals(other.boards, boards);

	@override
	int get hashCode => Object.hash(baseUrl, name, boards);
}