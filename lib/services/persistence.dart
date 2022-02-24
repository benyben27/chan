import 'dart:io';
import 'dart:math';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/services/settings.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:extended_image_library/extended_image_library.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
part 'persistence.g.dart';

class UriAdapter extends TypeAdapter<Uri> {
	@override
	final typeId = 12;

	@override
	Uri read(BinaryReader reader) {
		var str = reader.readString();
		return Uri.parse(str);
	}

	@override
	void write(BinaryWriter writer, Uri obj) {
		writer.writeString(obj.toString());
	}
}

const _savedAttachmentThumbnailsDir = 'saved_attachments_thumbs';
const _savedAttachmentsDir = 'saved_attachments';
const _maxAutosavedIdsPerBoard = 250;
const _maxHiddenIdsPerBoard = 1000;

class Persistence {
	final String id;
	Persistence(this.id);
	late final Box<PersistentThreadState> threadStateBox;
	Map<String, ImageboardBoard> get boards => settings.boardsBySite[id]!;
	Map<String, SavedAttachment> get savedAttachments => settings.savedAttachmentsBySite[id]!;
	Map<String, SavedPost> get savedPosts => settings.savedPostsBySite[id]!;
	PersistentRecentSearches get recentSearches => settings.recentSearchesBySite[id]!;
	PersistentBrowserState get browserState => settings.browserStateBySite[id]!;
	final savedAttachmentsNotifier = PublishSubject<void>();
	final savedPostsNotifier = PublishSubject<void>();
	static late final SavedSettings settings;
	static late final Directory temporaryDirectory;
	static late final Directory documentsDirectory;
	static late final PersistCookieJar cookies;

	static Future<void> initializeStatic() async {
		await Hive.initFlutter();
		Hive.registerAdapter(ColorAdapter());
		Hive.registerAdapter(SavedThemeAdapter());
		Hive.registerAdapter(TristateSystemSettingAdapter());
		Hive.registerAdapter(AutoloadAttachmentsSettingAdapter());
		Hive.registerAdapter(ThreadSortingMethodAdapter());
		Hive.registerAdapter(ContentSettingsAdapter());
		Hive.registerAdapter(SavedSettingsAdapter());
		Hive.registerAdapter(UriAdapter());
		Hive.registerAdapter(AttachmentTypeAdapter());
		Hive.registerAdapter(AttachmentAdapter());
		Hive.registerAdapter(ImageboardFlagAdapter());
		Hive.registerAdapter(PostSpanFormatAdapter());
		Hive.registerAdapter(PostAdapter());
		Hive.registerAdapter(ThreadAdapter());
		Hive.registerAdapter(ImageboardBoardAdapter());
		Hive.registerAdapter(PostReceiptAdapter());
		Hive.registerAdapter(PersistentThreadStateAdapter());
		Hive.registerAdapter(ImageboardArchiveSearchQueryAdapter());
		Hive.registerAdapter(PostTypeFilterAdapter());
		Hive.registerAdapter(MediaFilterAdapter());
		Hive.registerAdapter(PersistentRecentSearchesAdapter());
		Hive.registerAdapter(SavedAttachmentAdapter());
		Hive.registerAdapter(SavedPostAdapter());
		Hive.registerAdapter(ThreadIdentifierAdapter());
		Hive.registerAdapter(PersistentBrowserTabAdapter());
		Hive.registerAdapter(PersistentBrowserStateAdapter());
		temporaryDirectory = await getTemporaryDirectory();
		documentsDirectory = await getApplicationDocumentsDirectory();
		cookies = PersistCookieJar(
			storage: FileStorage(temporaryDirectory.path)
		);
		await Directory('${documentsDirectory.path}/$_savedAttachmentsDir').create(recursive: true);
		await Directory('${documentsDirectory.path}/$_savedAttachmentThumbnailsDir').create(recursive: true);
		final settingsBox = await Hive.openBox<SavedSettings>('settings');
		settings = settingsBox.get('settings', defaultValue: SavedSettings())!;
	}

	Future<void> initialize() async {
		threadStateBox = await Hive.openBox<PersistentThreadState>('threadStates_$id');
		if (await Hive.boxExists('searches_$id')) {
			print('Migrating searches box');
			final searchesBox = await Hive.openBox<PersistentRecentSearches>('searches_$id');
			final existingRecentSearches = searchesBox.get('recentSearches');
			if (existingRecentSearches != null) {
				settings.recentSearchesBySite[id] = existingRecentSearches;
			}
			await searchesBox.deleteFromDisk();
		}
		settings.recentSearchesBySite.putIfAbsent(id, () => PersistentRecentSearches());
		if (await Hive.boxExists('browserStates_$id')) {
			print('Migrating browser states box');
			final browserStateBox = await Hive.openBox<PersistentBrowserState>('browserStates_$id');
			final existingBrowserState = browserStateBox.get('browserState');
			if (existingBrowserState != null) {
				settings.browserStateBySite[id] = existingBrowserState;
			}
			await browserStateBox.deleteFromDisk();
		}
		settings.browserStateBySite.putIfAbsent(id, () => PersistentBrowserState(
			tabs: [PersistentBrowserTab(board: null)],
			hiddenIds: {},
			favouriteBoards: [],
			autosavedIds: {},
			hiddenImageMD5s: []
		));
		if (await Hive.boxExists('boards_$id')) {
			print('Migrating boards box');
			final boardBox = await Hive.openBox<ImageboardBoard>('boards_$id');
			settings.boardsBySite[id] = {
				for (final key in boardBox.keys) key.toString(): boardBox.get(key)!
			};
			await boardBox.deleteFromDisk();
		}
		settings.boardsBySite.putIfAbsent(id, () => {});
		if (await Hive.boxExists('savedAttachments_$id')) {
			print('Migrating saved attachments box');
			final savedAttachmentsBox = await Hive.openBox<SavedAttachment>('savedAttachments_$id');
			settings.savedAttachmentsBySite[id] = {
				for (final key in savedAttachmentsBox.keys) key.toString(): savedAttachmentsBox.get(key)!
			};
			await savedAttachmentsBox.deleteFromDisk();
		}
		settings.savedAttachmentsBySite.putIfAbsent(id, () => {});
		if (await Hive.boxExists('savedPosts_$id')) {
			print('Migrating saved posts box');
			final savedPostsBox = await Hive.openBox<SavedPost>('savedPosts_$id');
			settings.savedPostsBySite[id] = {
				for (final key in savedPostsBox.keys) key.toString(): savedPostsBox.get(key)!
			};
			await savedPostsBox.deleteFromDisk();
		}
		settings.savedPostsBySite.putIfAbsent(id, () => {});
		// Cleanup expanding lists
		for (final browserState in settings.browserStateBySite.values) {
			for (final list in browserState.autosavedIds.values) {
				list.removeRange(0, max(0, list.length - _maxAutosavedIdsPerBoard));
			}
			for (final list in browserState.hiddenIds.values) {
				list.removeRange(0, max(0, list.length - _maxHiddenIdsPerBoard));
			}
		}
		await settings.save();
	}

	PersistentThreadState? getThreadStateIfExists(ThreadIdentifier thread) {
		return threadStateBox.get('${thread.board}/${thread.id}');
	}

	PersistentThreadState getThreadState(ThreadIdentifier thread, {bool updateOpenedTime = false}) {
		final existingState = threadStateBox.get('${thread.board}/${thread.id}');
		if (existingState != null) {
			if (updateOpenedTime) {
				existingState.lastOpenedTime = DateTime.now();
				existingState.save();
			}
			return existingState;
		}
		else {
			final newState = PersistentThreadState();
			threadStateBox.put('${thread.board}/${thread.id}', newState);
			return newState;
		}
	}

	ImageboardBoard getBoard(String boardName) {
		final board = boards[boardName];
		if (board != null) {
			return board;
		}
		else {
			return ImageboardBoard(
				title: boardName,
				name: boardName,
				webmAudioAllowed: false,
				isWorksafe: true
			);
		}
	}

	SavedAttachment? getSavedAttachment(Attachment attachment) {
		return savedAttachments[attachment.globalId];
	}

	void saveAttachment(Attachment attachment, File fullResolutionFile) {
		final newSavedAttachment = SavedAttachment(attachment: attachment, savedTime: DateTime.now());
		savedAttachments[attachment.globalId] = newSavedAttachment;
		fullResolutionFile.copy(newSavedAttachment.file.path);
		getCachedImageFile(attachment.thumbnailUrl.toString()).then((file) {
			if (file != null) {
				file.copy(newSavedAttachment.thumbnailFile.path);
			}
			else {
				print('Failed to find cached copy of ${attachment.thumbnailUrl.toString()}');
			}
		});
		settings.save();
		savedAttachmentsNotifier.add(null);
	}

	void deleteSavedAttachment(Attachment attachment) {
		final removed = savedAttachments.remove(attachment.globalId);
		if (removed != null) {
			removed.deleteFiles();
		}
		settings.save();
		savedAttachmentsNotifier.add(null);
	}

	SavedPost? getSavedPost(Post post) {
		return savedPosts[post.globalId];
	}

	void savePost(Post post, Thread thread) {
		savedPosts[post.globalId] = SavedPost(post: post, savedTime: DateTime.now(), thread: thread);
		settings.save();
		// Likely will force the widget to rebuild
		getThreadStateIfExists(post.threadIdentifier)?.save();
		savedPostsNotifier.add(null);
	}

	void unsavePost(Post post) {
		savedPosts.remove(post.globalId);
		settings.save();
		// Likely will force the widget to rebuild
		getThreadStateIfExists(post.threadIdentifier)?.save();
		savedPostsNotifier.add(null);
	}

	String get currentBoardName => browserState.tabs[browserState.currentTab].board?.name ?? 'tv';

	ValueListenable<Box<PersistentThreadState>> listenForPersistentThreadStateChanges(ThreadIdentifier thread) {
		return threadStateBox.listenable(keys: ['${thread.board}/${thread.id}']);
	}

	Future<void> reinitializeBoards(List<ImageboardBoard> newBoards) async {
		boards.clear();
		boards.addAll({
			for (final board in newBoards) board.name: board
		});
	}

	Future<void> didUpdateBrowserState() async {
		await settings.save();
	}

	Future<void> didUpdateRecentSearches() async {
		await settings.save();
	}

	Future<void> didUpdateSavedPost() async {
		await settings.save();
		savedPostsNotifier.add(null);
	}
}

const _maxRecentItems = 50;
@HiveType(typeId: 8)
class PersistentRecentSearches {
	@HiveField(0)
	List<ImageboardArchiveSearchQuery> entries = [];

	void add(ImageboardArchiveSearchQuery entry) {
		entries = [entry, ...entries.take(_maxRecentItems)];
	}

	void bump(ImageboardArchiveSearchQuery entry) {
		entries = [entry, ...entries.where((e) => e != entry)];
	}

	void remove(ImageboardArchiveSearchQuery entry) {
		entries = [...entries.where((e) => e != entry)];
	}

	PersistentRecentSearches();
}

@HiveType(typeId: 3)
class PersistentThreadState extends HiveObject implements Filterable {
	@HiveField(0)
	int? lastSeenPostId;
	@HiveField(1)
	DateTime lastOpenedTime;
	@HiveField(6)
	DateTime? savedTime;
	@HiveField(3)
	List<PostReceipt> receipts = [];
	@HiveField(4)
	Thread? thread;
	@HiveField(5)
	bool useArchive = false;
	@HiveField(7, defaultValue: [])
	List<int> postsMarkedAsYou = [];
	@HiveField(8, defaultValue: [])
	List<int> hiddenPostIds = [];
	@HiveField(9, defaultValue: '')
	String draftReply = '';
	// Don't persist this
	final lastSeenPostIdNotifier = ValueNotifier<int?>(null);

	PersistentThreadState() : lastOpenedTime = DateTime.now();

	List<int> get youIds => receipts.map((receipt) => receipt.id).followedBy(postsMarkedAsYou).toList();
	List<int>? replyIdsToYou(Filter filter) {
		final _filter = FilterGroup([filter, IDFilter(hiddenPostIds)]);
		final _youIds = youIds;
		return thread?.posts.where((p) {
			return (_filter.filter(p)?.type != FilterResultType.hide) &&
						 p.span.referencedPostIds(thread!.board).any((id) => _youIds.contains(id));
		}).map((p) => p.id).toList();
	}
	List<int>? unseenReplyIdsToYou(Filter filter) => replyIdsToYou(filter)?.where((id) => id > lastSeenPostId!).toList();
	int? unseenReplyCount(Filter filter) {
		if (lastSeenPostId != null) {
			final _filter = FilterGroup([filter, IDFilter(hiddenPostIds)]);
			return thread?.posts.where((p) {
				return (p.id > lastSeenPostId!) &&
							 _filter.filter(p)?.type != FilterResultType.hide;
			}).length;
		}
		return null;
	}
	int? unseenImageCount(Filter filter) {
		if (lastSeenPostId != null) {
			final _filter = FilterGroup([filter, IDFilter(hiddenPostIds)]);
			return thread?.posts.where((p) {
				return (p.id > lastSeenPostId!) &&
							 (p.attachment != null) &&
							 (_filter.filter(p)?.type != FilterResultType.hide);
			}).length;
		}
		return null;
	}

	@override
	String toString() => 'PersistentThreadState(lastSeenPostId: $lastSeenPostId, receipts: $receipts, lastOpenedTime: $lastOpenedTime, savedTime: $savedTime, useArchive: $useArchive)';

	@override
	String get board => thread?.board ?? '';
	@override
	int get id => thread?.id ?? 0;
	@override
	String? getFilterFieldText(String fieldName) => thread?.getFilterFieldText(fieldName);
	@override
	bool get hasFile => thread?.hasFile ?? false;
	@override
	bool get isThread => true;

	Filter get threadFilter => IDFilter(hiddenPostIds);
	void hidePost(int id) => hiddenPostIds.add(id);
	void unHidePost(int id) => hiddenPostIds.remove(id);

	ThreadIdentifier get identifier => ThreadIdentifier(board: board, id: id);
}

@HiveType(typeId: 4)
class PostReceipt {
	@HiveField(0)
	final String password;
	@HiveField(1)
	final int id;
	PostReceipt({
		required this.password,
		required this.id
	});
	@override
	String toString() => 'PostReceipt(id: $id, password: $password)';
}

@HiveType(typeId: 18)
class SavedAttachment {
	@HiveField(0)
	final Attachment attachment;
	@HiveField(1)
	final DateTime savedTime;
	@HiveField(2)
	final List<int> tags;
	SavedAttachment({
		required this.attachment,
		required this.savedTime,
		List<int>? tags
	}) : tags = tags ?? [];

	Future<void> deleteFiles() async {
		await thumbnailFile.delete();
		await file.delete();
	}

	File get thumbnailFile => File('${Persistence.documentsDirectory.path}/$_savedAttachmentThumbnailsDir/${attachment.globalId}.jpg');
	File get file => File('${Persistence.documentsDirectory.path}/$_savedAttachmentsDir/${attachment.globalId}${attachment.ext == '.webm' ? '.mp4' : attachment.ext}');
}

@HiveType(typeId: 19)
class SavedPost implements Filterable {
	@HiveField(0)
	Post post;
	@HiveField(1)
	final DateTime savedTime;
	@HiveField(2)
	Thread thread;

	SavedPost({
		required this.post,
		required this.savedTime,
		required this.thread
	});

	@override
	String get board => post.board;
	@override
	int get id => post.id;
	@override
	String? getFilterFieldText(String fieldName) => post.getFilterFieldText(fieldName);
	@override
	bool get hasFile => post.hasFile;
	@override
	bool get isThread => false;
}

@HiveType(typeId: 21)
class PersistentBrowserTab {
	@HiveField(0)
	ImageboardBoard? board;
	@HiveField(1)
	ThreadIdentifier? thread;
	@HiveField(2, defaultValue: '')
	String draftThread;
	@HiveField(3, defaultValue: '')
	String draftSubject;
	PersistentBrowserTab({
		this.board,
		this.thread,
		this.draftThread = '',
		this.draftSubject = ''
	});
}

@HiveType(typeId: 22)
class PersistentBrowserState {
	@HiveField(0)
	List<PersistentBrowserTab> tabs;
	@HiveField(1)
	int currentTab;
	@HiveField(2, defaultValue: {})
	final Map<String, List<int>> hiddenIds;
	@HiveField(3, defaultValue: [])
	final List<String> favouriteBoards;
	@HiveField(5, defaultValue: {})
	final Map<String, List<int>> autosavedIds;
	@HiveField(6, defaultValue: [])
	final Set<String> hiddenImageMD5s;
	
	PersistentBrowserState({
		required this.tabs,
		this.currentTab = 0,
		required this.hiddenIds,
		required this.favouriteBoards,
		required this.autosavedIds,
		required List<String> hiddenImageMD5s
	}) : hiddenImageMD5s = hiddenImageMD5s.toSet();

	Filter getCatalogFilter(String board) {
		return FilterGroup([
			IDFilter(hiddenIds[board] ?? []),
			imageMD5Filter
		]);
	}
	
	bool isThreadHidden(String board, int id) {
		return hiddenIds[board]?.contains(id) ?? false;
	}

	void hideThread(String board, int id) {
		hiddenIds.putIfAbsent(board, () => []).add(id);
	}

	void unHideThread(String board, int id) {
		hiddenIds[board]?.remove(id);
	}

	bool isMD5Hidden(String? md5) {
		if (md5 == null) return false;
		return hiddenImageMD5s.contains(md5);
	}

	void hideByMD5(String md5) {
		hiddenImageMD5s.add(md5);
	}

	void unHideByMD5(String md5) {
		hiddenImageMD5s.remove(md5);
	}

	Filter get imageMD5Filter => MD5Filter(hiddenImageMD5s);
}