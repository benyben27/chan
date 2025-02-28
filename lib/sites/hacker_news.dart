import 'package:chan/models/search.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/sites/4chan.dart';
import 'dart:io';

import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

abstract class _HNObject {
	final String by;
	final List<_HNObject> children;
	final bool dead;
	final bool deleted;
	final int id;
	final int? score;
	final DateTime time;

	const _HNObject({
		required this.by,
		required this.children,
		this.dead = false,
		this.deleted = false,
		required this.id,
		required this.score,
		required this.time
	});
}

enum _HNStoryType {
	normal,
	job,
	poll
}

class _HNPollOption {
	final String text;
	final int votes;
	const _HNPollOption({
		required this.text,
		required this.votes
	});
}

class _HNStory extends _HNObject {
	final int descendants;
	final String? text;
	final String? title;
	final Uri? url;
	final _HNStoryType type;
	final List<_HNPollOption> pollOptions;
	const _HNStory({
		required super.by,
		required this.descendants,
		required super.id,
		required super.children,
		required this.pollOptions,
		required super.score,
		required this.text,
		required super.time,
		required this.title,
		required this.type,
		required this.url,
		super.dead,
		super.deleted
	});
}

class _HNComment extends _HNObject {
	final int parent;
	final int story;
	final String text;
	const _HNComment({
		required super.by,
		required super.id,
		required super.children,
		required this.parent,
		required super.score,
		required this.story,
		required this.text,
		required super.time,
		super.dead,
		super.deleted
	});
}

class SiteHackerNews extends ImageboardSite {
	final int catalogThreadsPerPage;
	SiteHackerNews({
		this.catalogThreadsPerPage = 30
	}) : super([]);
	@override
	String get baseUrl => 'news.ycombinator.com';

	Map<CatalogVariant?, List<int>> _lastCatalogIds = {};
	Map<int, int> _cachedOpIds = {};

	@override
	void migrateFromPrevious(SiteHackerNews oldSite) {
		super.migrateFromPrevious(oldSite);
		_lastCatalogIds = oldSite._lastCatalogIds;
		_cachedOpIds = oldSite._cachedOpIds;
	}

	static PostNodeSpan makeSpan(String text) {
		final body = parseFragment(text);
		Iterable<PostSpan> visit(Iterable<dom.Node> nodes) sync* {
			bool addLinebreakBefore = false;
			for (final node in nodes) {
				bool addedLinebreakBefore = addLinebreakBefore;
				if (addLinebreakBefore) {
					yield const PostLineBreakSpan();
					addLinebreakBefore = false;
				}
				if (node is dom.Element) {
					if (node.localName == 'p') {
						if (addedLinebreakBefore) {
							yield const PostLineBreakSpan();
						}
						if (node.text.startsWith('>')) {
							yield PostQuoteSpan(PostNodeSpan(visit(node.nodes).toList()));
						}
						else {
							yield* visit(node.nodes);
						}
						addLinebreakBefore = true;
					}
					else if (node.localName == 'br') {
						yield const PostLineBreakSpan();
					}
					else if (node.localName == 'a') {
						yield PostLinkSpan(node.attributes['href']!, name: node.text);
					}
					else if (node.localName == 'b') {
						yield PostBoldSpan(PostTextSpan(node.text));
					}
					else if (node.localName == 'i') {
						yield PostItalicSpan(PostTextSpan(node.text));
					}
					else if (node.localName == 'ol' || node.localName == 'ul') {
						int i = 1;
						for (final li in node.nodes) {
							if (li is dom.Element && li.localName == 'li') {
								if (addLinebreakBefore) {
									yield const PostLineBreakSpan();
									addLinebreakBefore = false;
								}
								if (node.localName == 'ol') {
									yield PostTextSpan('$i. ');
								}
								else {
									yield const PostTextSpan('• ');
								}
								yield PostTextSpan(li.text);
								addLinebreakBefore = true;
								i++;
							}
						}
					}
					else if (node.localName == 'pre') {
						yield PostCodeSpan(node.text.replaceFirst(RegExp(r'\n$'), ''));
						if (node.text.endsWith('\n')) {
							yield const PostLineBreakSpan();
						}
					}
					else {
						yield* Site4Chan.parsePlaintext(node.text);
					}
				}
				else {
					yield* Site4Chan.parsePlaintext(node.text ?? '');
				}
			}
		}
		return PostNodeSpan(visit(body.nodes).toList(growable: false));
	}

	static Attachment _makeAttachment(int threadId, Uri url) => Attachment(
		type: AttachmentType.url,
		board: '',
		id: url.toString(),
		ext: '',
		filename: '',
		url: url.toString(),
		thumbnailUrl: Uri.https('thumbs.chance.surf', '/', {
			'url': url.toString()
		}).toString(),
		md5: '',
		width: null,
		height: null,
		threadId: threadId,
		sizeInBytes: null
	);

	static int _countDescendants(_HNObject o) {
		int out = 1;
		for (final child in o.children) {
			out += _countDescendants(child);
		}
		return out;
	}

	Future<_HNObject> _makeHNObjectAlgolia(Map d) async {
		final children = await Future.wait(((d['children'] as List?)?.cast<Map>() ?? []).map(_makeHNObjectAlgolia));
		switch (d['type']) {
			case 'story':
			case 'job':
			case 'poll':
				return _HNStory(
					by: d['author'] ?? '',
					descendants: children.fold<int>(0, (count, child) => count + _countDescendants(child)), 
					id: d['id'],
					children: children,
					pollOptions: (d['options'] as List?)?.cast<Map>().map((option) => _HNPollOption(
						text: option['text'],
						votes: option['points']
					)).toList() ?? [],
					score: d['points'],
					text: d['text'],
					time: DateTime.fromMillisecondsSinceEpoch(d['created_at_i'] * 1000),
					title: d['title'],
					type: {
						'story': _HNStoryType.normal,
						'job': _HNStoryType.job,
						'poll': _HNStoryType.poll
					}[d['type']]!,
					url: d['url'] != null ? Uri.parse(d['url']) : null,
					dead: d['dead'] ?? false,
					deleted: d['deleted'] ?? false
				);
			case 'comment':
				return _HNComment(
					by: d['author'] ?? '',
					id: d['id'],
					children: children,
					parent: d['parent_id'],
					score: d['points'],
					story: d['story_id'],
					text: d['text'] ?? '',
					time: DateTime.fromMillisecondsSinceEpoch(d['created_at_i'] * 1000),
					dead: d['dead'] ?? false,
					deleted: d['deleted'] ?? false
				);
			default:
				throw Exception('Unknown HN object type "${d['type']}?"');
		}
	}

	Future<_HNObject> _getAlgolia(int id, {required bool interactive}) async {
		final response = await client.get('https://hn.algolia.com/api/v1/items/$id', options: Options(
			extra: {
				kInteractive: interactive
			}
		));
		return await _makeHNObjectAlgolia(response.data);
	}

	Future<Thread> _getThreadForCatalog(int id, {required bool interactive}) async {
		final response = await client.get('https://hacker-news.firebaseio.com/v0/item/$id.json', options: Options(
			extra: {
				kInteractive: interactive
			}
		));
		final d = response.data as Map;
		String text;
		switch (d['type']) {
			case 'story':
				text = d['text'] ?? d['url'] ?? '';
				break;
			case 'job':
				text = d['text'] ?? d['url'] ?? '';
				break;
			case 'poll':
				final responses = await Future.wait<Map>(d['parts'].map((int part) async {
					return (await client.get('https://hacker-news.firebaseio.com/v0/item/$part.json', options: Options(
						extra: {
							kInteractive: interactive
						}
					))).data;
				}));
				text = '${d['text']}<ul>${responses.map((r) => '<li>${r['text']} - ${r['score']}</li>').join('\n')}</ul>';
				break;
			default:
				throw Exception('Unexpected HN item type "${d['type']}"');
		}
		final Uri? url = d['url'] == null ? null : Uri.parse(d['url'] ?? '');
		final op = Post(
			board: '',
			text: text,
			name: d['by'],
			time: DateTime.fromMillisecondsSinceEpoch(d['time'] * 1000),
			threadId: id,
			id: id,
			spanFormat: PostSpanFormat.hackerNews,
			attachments: [
				if (url != null) _makeAttachment(id, url)
			],
			upvotes: d['score']
		);
		return Thread(
			posts_: [op],
			imageCount: 0,
			id: id,
			board: '',
			title: d['title'],
			isSticky: false,
			time: op.time,
			attachments: op.attachments,
			replyCount: d['descendants'] ?? 0
		);
	}

	Future<Post> _makePost(_HNObject item) async {
		if (item is _HNComment) {
			return Post(
				board: '',
				text: item.text,
				name: item.by,
				time: item.time,
				threadId: item.story,
				id: item.id,
				spanFormat: PostSpanFormat.hackerNews,
				attachments: [],
				upvotes: item.score,
				parentId: item.parent
			);
		}
		else if (item is _HNStory) {
			String text;
			switch (item.type) {
				case _HNStoryType.normal:
				case _HNStoryType.job:
					text = item.text ?? item.url?.toString() ?? '';
					break;
				case _HNStoryType.poll:
					text = '${item.text}<ul>${item.pollOptions.map((r) => '<li>${parseFragment(r.text).text} - ${r.votes} votes</li>').join('\n')}</ul>';
					break;
			}
			return Post(
				board: '',
				text: text,
				name: item.by,
				time: item.time,
				threadId: item.id,
				id: item.id,
				spanFormat: PostSpanFormat.hackerNews,
				attachments: [
					if (item.url != null) _makeAttachment(item.id, item.url!)
				],
				upvotes: item.score
			);
		}
		throw UnimplementedError('Converting a ${item.runtimeType} into a Post');
	}

	@override
	Future<PostReceipt> createThread({required String board, String name = '', String options = '', String subject = '', required String text, required CaptchaSolution captchaSolution, File? file, bool? spoiler, String? overrideFilename, ImageboardBoardFlag? flag}) {
		// TODO: implement createThread
		throw UnimplementedError();
	}

	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(String url) async {
		final parsed = Uri.tryParse(url);
		if (parsed != null) {
			if (parsed.host == baseUrl && parsed.path == '/item' && parsed.queryParameters.containsKey('id')) {
				int id = int.parse(parsed.queryParameters['id']!);
				return BoardThreadOrPostIdentifier('', await _cachedOpIds.putIfAbsentAsync(id, () async {
					final object = await _getAlgolia(id, interactive: true);
					return object is _HNComment ? object.story : id;
				}), id);
			}
		}
		return null;
	}

	@override
	String get defaultUsername => '';

	@override
	Future<void> deletePost(String board, int threadId, PostReceipt receipt) {
		// TODO: implement deletePost
		throw UnimplementedError();
	}

	@override
	Future<List<ImageboardBoard>> getBoards({required bool interactive}) async {
		return [ImageboardBoard(
			name: '',
			title: 'Hacker News',
			isWorksafe: true,
			webmAudioAllowed: true
		)];
	}

	@override
	Future<List<ImageboardBoard>> getBoardsForQuery(String query) async {
		return [];
	}

	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, [int? threadId]) async {
		return NoCaptchaRequest();
	}

	Future<List<int>> _getSecondChancePoolIds(int? after, {required bool interactive}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/pool', {
			if (after != null) 'next': after.toString()
		}), options: Options(
			extra: {
				kInteractive: interactive
			}
		));
		final doc = parse(response.data);
		final ids = doc.querySelectorAll('.athing').map((e) => int.parse(e.id));
		if (after != null) {
			// Avoid duplicating the "after" id
			return ids.skip(1).toList();
		}
		return ids.toList();
	}

	@override
	Future<List<Thread>> getCatalogImpl(String board, {CatalogVariant? variant, required bool interactive}) async {
		final List<int> data;
		if (variant == CatalogVariant.hackerNewsSecondChancePool) {
			data = await _getSecondChancePoolIds(null, interactive: interactive);
		}
		else {
			final name = {
				CatalogVariant.hackerNewsTop: 'topstories',
				CatalogVariant.hackerNewsNew: 'newstories',
				CatalogVariant.hackerNewsBest: 'beststories',
				CatalogVariant.hackerNewsAsk: 'askstories',
				CatalogVariant.hackerNewsShow: 'showstories',
				CatalogVariant.hackerNewsJobs: 'jobstories',
			}[variant]!;
			final response = await client.get('https://hacker-news.firebaseio.com/v0/$name.json', options: Options(
				extra: {
					kInteractive: interactive
				}
			));
			data = (response.data as List).cast<int>();
		}
		_lastCatalogIds[variant] = data;
		return await Future.wait(data.take(catalogThreadsPerPage).map((d) => _getThreadForCatalog(d, interactive: interactive)));
	}

	Future<List<Post>> _getMoreThread(_HNObject item) async {
		final posts = <Post>[];
		Future<void> dumpNode(_HNObject item2) async {
			if (item2.by.isNotEmpty) {
				posts.add(await _makePost(item2));
			}
			for (final child in item2.children) {
				await dumpNode(child);
			}
		}
		await dumpNode(item);
		return posts;
	}

	@override
	Future<List<Thread>> getMoreCatalogImpl(Thread after, {CatalogVariant? variant, required bool interactive}) async {
		if (variant == CatalogVariant.hackerNewsSecondChancePool) {
			final ids = await _getSecondChancePoolIds(after.id, interactive: interactive);
			return await Future.wait(ids.map((id) => _getThreadForCatalog(id, interactive: interactive)));
		}
		else {
			final lastCatalogIds = _lastCatalogIds[variant];
			final index = lastCatalogIds?.indexOf(after.id) ?? -1;
			if (index == -1) {
				return [];
			}
			return await Future.wait(lastCatalogIds!.skip(index + 1).take(catalogThreadsPerPage).map((id) => _getThreadForCatalog(id, interactive: interactive)));
		}
	}

	@override
	Future<Post> getPost(String board, int id, {required bool interactive}) async {
		final item = await _getAlgolia(id, interactive: interactive);
		return _makePost(item);
	}

	@override
	Uri getSpoilerImageUrl(Attachment attachment, {ThreadIdentifier? thread}) {
		// TODO: implement getSpoilerImageUrl
		throw UnimplementedError();
	}

	@override
	Future<Thread> getThreadImpl(ThreadIdentifier thread, {ThreadVariant? variant, required bool interactive}) async {
		final item = await _getAlgolia(thread.id, interactive: interactive);
		if (item is! _HNStory) {
			throw Exception('HN item ${thread.id} is not a thread');
		}
		final posts = await _getMoreThread(item);
		return Thread(
			posts_: posts,
			replyCount: item.descendants,
			imageCount: 0,
			id: item.id,
			board: '',
			title: item.title,
			isSticky: false,
			time: item.time,
			attachments: posts.first.attachments
		);
	}

	@override
	String getWebUrl(String board, [int? threadId, int? postId]) {
		return 'https://$baseUrl/item?id=${postId ?? threadId}';
	}

	@override
	Uri get iconUrl => Uri.https(baseUrl, '/favicon.ico');

	@override
	String get imageUrl => baseUrl;

	@override
	String get name => 'Hacker News';

	@override
	Future<PostReceipt> postReply({required ThreadIdentifier thread, String name = '', String options = '', required String text, required CaptchaSolution captchaSolution, File? file, bool? spoiler, String? overrideFilename, ImageboardBoardFlag? flag}) {
		// TODO: implement postReply
		throw UnimplementedError();
	}


	@override
	String get siteData => '';
	@override
	String get siteType => 'reddit';

	@override
	bool get useTree => true;
	@override
	bool get allowsArbitraryBoards => false;
	@override
	bool get classicCatalogStyle => false;
	@override
	bool get explicitIds => false;
	@override
	bool get showImageCount => false;
	@override
	ImageboardSearchOptions supportsSearch(String? board) {
		return ImageboardSearchOptions.nameAndTextOnly;
	}
	@override
	bool get supportsPosting => false;
	@override
	bool get isHackerNews => true;
	@override
	bool get supportsMultipleBoards => false;
	@override
	bool get hasPagedCatalog => true;

	@override
	Future<Thread> getThreadFromArchive(ThreadIdentifier thread, {Future<void> Function(Thread)? customValidator, required bool interactive}) => getThread(thread, interactive: interactive);

	@override
	List<CatalogVariantGroup> get catalogVariantGroups => const [
		CatalogVariantGroup(
			name: 'Top',
			variants: [CatalogVariant.hackerNewsTop]
		),
		CatalogVariantGroup(
			name: 'New',
			variants: [CatalogVariant.hackerNewsNew]
		),
		CatalogVariantGroup(
			name: 'Best',
			variants: [CatalogVariant.hackerNewsBest]
		),
		CatalogVariantGroup(
			name: 'Ask HN',
			variants: [CatalogVariant.hackerNewsAsk]
		),
		CatalogVariantGroup(
			name: 'Show HN',
			variants: [CatalogVariant.hackerNewsShow]
		),
		CatalogVariantGroup(
			name: 'Jobs',
			variants: [CatalogVariant.hackerNewsJobs]
		),
		CatalogVariantGroup(
			name: 'Second Chance',
			variants: [CatalogVariant.hackerNewsSecondChancePool]
		)
	];

	@override
	Future<ImageboardArchiveSearchResultPage> search(ImageboardArchiveSearchQuery query, {required int page, ImageboardArchiveSearchResultPage? lastResult}) async {
		final response = await client.get('https://hn.algolia.com/api/v1/search', queryParameters: {
			'query': query.query,
			'page': page - 1,
			if (query.name != null) 'tags': 'author_${query.name}'
		});
		return ImageboardArchiveSearchResultPage(
			page: response.data['page'] + 1,
			maxPage: response.data['nbPages'],
			archive: this,
			posts: (response.data['hits'] as List).map((hit) {
				final id = int.parse(hit['objectID']);
				if (hit['comment_text'] != null) {
					return ImageboardArchiveSearchResult.post(Post(
						board: '',
						text: hit['comment_text'],
						name: hit['author'],
						time: DateTime.fromMillisecondsSinceEpoch(hit['created_at_i'] * 1000),
						threadId: hit['story_id'],
						id: id,
						spanFormat: PostSpanFormat.hackerNews,
						attachments: []
					));
				}
				final op = Post(
					board: '',
					text: hit['story_text'] ?? '',
					name: hit['author'],
					time: DateTime.fromMillisecondsSinceEpoch(hit['created_at_i'] * 1000),
					threadId: id,
					id: id,
					spanFormat: PostSpanFormat.hackerNews,
					attachments: [
						if (hit['url'] != null) _makeAttachment(id, Uri.parse(hit['url']!))
					]
				);
				return ImageboardArchiveSearchResult.thread(Thread(
					posts_: [op],
					replyCount: 0,
					imageCount: 0,
					id: op.id,
					board: '',
					title: hit['title'],
					isSticky: false,
					time: op.time,
					attachments: op.attachments
				));
			}).toList()
		);
	}

	@override
	String formatBoardName(ImageboardBoard board) => name;

	@override
	int placeOrphanPost(List<Post> posts, Post post) {
		// No idea where to put it
		posts.add(post);
		return posts.length - 1;
	}

	@override
	bool get supportsUserInfo => true;

	@override
	Future<ImageboardUserInfo> getUserInfo(String username) async {
		final response = await client.get('https://hn.algolia.com/api/v1/users/$username');
		if (response.data['error'] != null) {
			throw Exception(response.data['error']);
		}
		return ImageboardUserInfo(
			username: username,
			webUrl: Uri.https('news.ycombinator.com', '/user', {
				'id': username
			}),
			createdAt: DateTime.parse(response.data['created_at']),
			totalKarma: response.data['karma']
		);
	}

	@override
	bool operator == (Object other) => (other is SiteHackerNews) && (other.catalogThreadsPerPage == catalogThreadsPerPage);

	@override
	int get hashCode => catalogThreadsPerPage.hashCode;
}
