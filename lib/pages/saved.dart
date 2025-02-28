import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:chan/main.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/gallery.dart';
import 'package:chan/pages/master_detail.dart';
import 'package:chan/pages/thread.dart';
import 'package:chan/services/apple.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/notifications.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/services/thread_watcher.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/attachment_viewer.dart';
import 'package:chan/widgets/context_menu.dart';
import 'package:chan/widgets/imageboard_scope.dart';
import 'package:chan/widgets/post_row.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:chan/widgets/saved_attachment_thumbnail.dart';
import 'package:chan/widgets/thread_row.dart';
import 'package:chan/widgets/timed_rebuilder.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mutex/mutex.dart';
import 'package:provider/provider.dart';
import 'package:unifiedpush/unifiedpush.dart';

class _PostThreadCombo {
	final Imageboard imageboard;
	final Post? post;
	final PersistentThreadState threadState;
	_PostThreadCombo({
		required this.imageboard,
		required this.post,
		required this.threadState
	});

	@override
	bool operator == (dynamic o) => (o is _PostThreadCombo) && (o.imageboard == imageboard) && (o.post?.id == post?.id) && (o.threadState.identifier == threadState.identifier);
	@override
	int get hashCode => Object.hash(imageboard, post, threadState);
}

final _watchMutex = ReadWriteMutex();
Future<List<ImageboardScoped<ThreadWatch>>> _loadWatches() => _watchMutex.protectRead(() async {
	final watches = ImageboardRegistry.instance.imageboards.expand((i) => i.persistence.browserState.threadWatches.values.map(i.scope)).toList();
	await Future.wait(watches.map((watch) async {
		await watch.imageboard.persistence.getThreadStateIfExists(watch.item.threadIdentifier)?.ensureThreadLoaded();
	}));
	final d = DateTime(2000);
	if (Persistence.settings.watchedThreadsSortingMethod == ThreadSortingMethod.lastReplyByYouTime) {
		mergeSort<ImageboardScoped<ThreadWatch>>(watches, compare: (a, b) {
			final ta = a.imageboard.persistence.getThreadStateIfExists(a.item.threadIdentifier);
			final tb = b.imageboard.persistence.getThreadStateIfExists(b.item.threadIdentifier);
			Post? pa;
			Post? pb;
			if (ta?.youIds.isNotEmpty == true) {
				pa = ta!.thread?.posts_.tryFirstWhere((p) => p.id == ta.youIds.last);
			}
			if (tb?.youIds.isNotEmpty == true) {
				pb = tb!.thread?.posts_.tryFirstWhere((p) => p.id == tb.youIds.last);
			}
			return (pb?.time ?? d).compareTo(pa?.time ?? d);
		});
	}
	else if (Persistence.settings.watchedThreadsSortingMethod == ThreadSortingMethod.lastPostTime) {
		mergeSort<ImageboardScoped<ThreadWatch>>(watches, compare: (a, b) {
			return (b.imageboard.persistence.getThreadStateIfExists(b.item.threadIdentifier)?.thread?.posts.last.time ?? d).compareTo(a.imageboard.persistence.getThreadStateIfExists(a.item.threadIdentifier)?.thread?.posts.last.time ?? d);
		});
	}
	mergeSort<ImageboardScoped<ThreadWatch>>(watches, compare: (a, b) {
		if (a.item.zombie == b.item.zombie) {
			return 0;
		}
		else if (a.item.zombie) {
			return 1;
		}
		else {
			return -1;
		}
	});
	return watches;
});

class SavedPage extends StatefulWidget {
	final bool isActive;
	final GlobalKey<MultiMasterDetailPageState>? masterDetailKey;

	const SavedPage({
		required this.isActive,
		this.masterDetailKey,
		Key? key
	}) : super(key: key);

	@override
	createState() => _SavedPageState();
}

class _SavedPageState extends State<SavedPage> {
	late final RefreshableListController<ImageboardScoped<ThreadWatch>> _watchedListController;
	late final RefreshableListController<PersistentThreadState> _threadListController;
	late final RefreshableListController<ImageboardScoped<SavedPost>> _postListController;
	late final RefreshableListController<_PostThreadCombo> _yourPostsListController;
	final _watchedThreadsListKey = GlobalKey(debugLabel: '_SavedPageState._watchedThreadsListKey');
	final _savedThreadsListKey = GlobalKey(debugLabel: '_SavedPageState._savedThreadsListKey');
	final _savedPostsListKey = GlobalKey(debugLabel: '_SavedPageState._savedPostsListKey');
	final _yourPostsListKey = GlobalKey(debugLabel: '_SavedPageState._yourPostsListKey');
	final _savedAttachmentsAnimatedBuilderKey = GlobalKey(debugLabel: '_SavedPageState._savedAttachmentsAnimatedBuilderKey');
	late final ScrollController _savedAttachmentsController;
	late final EasyListenable _removeArchivedHack;
	List<ImageboardScoped<SavedAttachment>> _savedAttachments = [];

	@override
	void initState() {
		super.initState();
		_watchedListController = RefreshableListController();
		_threadListController = RefreshableListController();
		_postListController = RefreshableListController();
		_yourPostsListController = RefreshableListController();
		_savedAttachmentsController = ScrollController();
		_removeArchivedHack = EasyListenable();
	}

	@override
	void didUpdateWidget(SavedPage oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (widget.isActive && !oldWidget.isActive) {
			_watchedListController.update();
			_threadListController.update();
			_postListController.update();
			_yourPostsListController.update();
			_removeArchivedHack.didUpdate();
		}
	}

	Widget _placeholder(String message) {
		return AdaptiveScaffold(
			body: Center(
				child: Text(message)
			)
		);
	}

	AdaptiveBar _watchedNavigationBar() {
		final settings = context.watch<EffectiveSettings>();
		return AdaptiveBar(
			title: const Text('Watched Threads'),
			actions: [
				CupertinoButton(
					padding: EdgeInsets.zero,
					child: const Icon(CupertinoIcons.sort_down),
					onPressed: () {
						showAdaptiveModalPopup<DateTime>(
							context: context,
							builder: (context) => AdaptiveActionSheet(
								title: const Text('Sort by...'),
								actions: {
									ThreadSortingMethod.lastPostTime: 'Last Reply',
									ThreadSortingMethod.lastReplyByYouTime: 'Last Reply by You',
								}.entries.map((entry) => AdaptiveActionSheetAction(
									child: Text(entry.value, style: TextStyle(
										fontWeight: entry.key == settings.watchedThreadsSortingMethod ? FontWeight.bold : null
									)),
									onPressed: () {
										settings.watchedThreadsSortingMethod = entry.key;
										Navigator.of(context, rootNavigator: true).pop();
									}
								)).toList(),
								cancelButton: AdaptiveActionSheetAction(
									child: const Text('Cancel'),
									onPressed: () => Navigator.of(context, rootNavigator: true).pop()
								)
							)
						);
					}
				)
			]
		);
	}

	AdaptiveBar _savedNavigationBar(String title) {
		final settings = context.watch<EffectiveSettings>();
		return AdaptiveBar(
			title: Text(title),
			actions: [
				CupertinoButton(
					padding: EdgeInsets.zero,
					child: const Icon(CupertinoIcons.sort_down),
					onPressed: () {
						showAdaptiveModalPopup<DateTime>(
							context: context,
							builder: (context) => AdaptiveActionSheet(
								title: const Text('Sort by...'),
								actions: {
									ThreadSortingMethod.savedTime: 'Saved Date',
									ThreadSortingMethod.lastPostTime: 'Posted Date',
								}.entries.map((entry) => AdaptiveActionSheetAction(
									child: Text(entry.value, style: TextStyle(
										fontWeight: entry.key == settings.savedThreadsSortingMethod ? FontWeight.bold : null
									)),
									onPressed: () {
										settings.savedThreadsSortingMethod = entry.key;
										Navigator.of(context, rootNavigator: true).pop();
									}
								)).toList(),
								cancelButton: AdaptiveActionSheetAction(
									child: const Text('Cancel'),
									onPressed: () => Navigator.of(context, rootNavigator: true).pop()
								)
							)
						);
					}
				)
			]
		);
	}

	@override
	Widget build(BuildContext context) {
		final settings = context.watch<EffectiveSettings>();
		final persistencesAnimation = FilteringListenable(Listenable.merge(ImageboardRegistry.instance.imageboards.map((x) => x.persistence).toList()), () => widget.isActive);
		final threadStateBoxesAnimation = FilteringListenable(Persistence.sharedThreadStateBox.listenable(), () => widget.isActive);
		final savedPostNotifiersAnimation = FilteringListenable(Listenable.merge(ImageboardRegistry.instance.imageboards.map((i) => i.persistence.savedAttachmentsListenable).toList()), () => widget.isActive);
		final savedAttachmentsNotifiersAnimation = FilteringListenable(Listenable.merge(ImageboardRegistry.instance.imageboards.map((i) => i.persistence.savedAttachmentsListenable).toList()), () => widget.isActive);
		return MultiMasterDetailPage(
			id: 'saved',
			key: widget.masterDetailKey,
			paneCreator: () => [
				MultiMasterPane<ImageboardScoped<ThreadWatch>>(
					navigationBar: _watchedNavigationBar(),
					icon: CupertinoIcons.bell_fill,
					masterBuilder: (context, selected, setter) {
						return SafeArea(
							child: Column(
								children: [
									ThreadWatcherControls(
										isActive: widget.isActive
									),
									Divider(
										thickness: 1,
										height: 0,
										color: ChanceTheme.primaryColorWithBrightness20Of(context)
									),
									Expanded(
										child: RefreshableList<ImageboardScoped<ThreadWatch>>(
											filterableAdapter: null,
											controller: _watchedListController,
											listUpdater: () async {
												final list = await _loadWatches();
												_watchedListController.waitForItemBuild(0).then((_) => _removeArchivedHack.didUpdate());
												return list;
											},
											minUpdateDuration: Duration.zero,
											updateAnimation: persistencesAnimation,
											key: _watchedThreadsListKey,
											id: 'watched',
											minCacheExtent: settings.useCatalogGrid ? settings.catalogGridHeight : 0,
											gridDelegate: settings.useCatalogGrid ? SliverGridDelegateWithMaxCrossAxisExtentWithCacheTrickery(
												maxCrossAxisExtent: settings.catalogGridWidth,
												childAspectRatio: settings.catalogGridWidth / settings.catalogGridHeight
											) : null,
											canTapFooter: false,
											itemBuilder: (itemContext, watch) {
												final isSelected = selected(itemContext, watch);
												final openInNewTabZone = context.read<OpenInNewTabZone?>();
												return ImageboardScope(
													imageboardKey: watch.imageboard.key,
													child: ContextMenu(
														maxHeight: 125,
														actions: [
															if (openInNewTabZone != null) ContextMenuAction(
																child: const Text('Open in new tab'),
																trailingIcon: CupertinoIcons.rectangle_stack_badge_plus,
																onPressed: () {
																	openInNewTabZone.onWantOpenThreadInNewTab(watch.imageboard.key, watch.item.threadIdentifier);
																}
															),
															ContextMenuAction(
																child: const Text('Unwatch'),
																onPressed: () async {
																	await watch.imageboard.notifications.removeWatch(watch.item);
																	_watchedListController.update();
																},
																trailingIcon: CupertinoIcons.xmark,
																isDestructiveAction: true
															),
															if (watch.imageboard.persistence.getThreadStateIfExists(watch.item.threadIdentifier)?.savedTime != null) ContextMenuAction(
																child: const Text('Un-save thread'),
																trailingIcon: Adaptive.icons.bookmarkFilled,
																onPressed: () {
																	final threadState = watch.imageboard.persistence.getThreadState(watch.item.threadIdentifier);
																	threadState.savedTime = null;
																	threadState.save();
																	_threadListController.update();
																}
															)
															else ContextMenuAction(
																child: const Text('Save thread'),
																trailingIcon: Adaptive.icons.bookmark,
																onPressed: () {
																	final threadState = watch.imageboard.persistence.getThreadState(watch.item.threadIdentifier);
																	threadState.savedTime = DateTime.now();
																	threadState.save();
																}
															),
														],
														child: GestureDetector(
															behavior: HitTestBehavior.opaque,
															child: AnimatedBuilder(
																animation: watch.imageboard.persistence.listenForPersistentThreadStateChanges(watch.item.threadIdentifier),
																builder: (context, child) {
																	final threadState = watch.imageboard.persistence.getThreadStateIfExists(watch.item.threadIdentifier);
																	if (threadState?.thread == null) {
																		// Make sure this isn't a newly-created thread/watch
																		if (threadState == null || DateTime.now().difference(threadState.lastOpenedTime) > const Duration(days: 30)) {
																			// Probably the thread was deleted during a cleanup
																			Future.delayed(const Duration(seconds: 1), () {
																				watch.imageboard.notifications.removeWatch(watch.item);
																			});
																		}
																		return const SizedBox.shrink();
																	}
																	else {
																		return ThreadRow(
																			thread: threadState!.thread!,
																			isSelected: isSelected,
																			contentFocus: settings.useCatalogGrid,
																			showBoardName: true,
																			showSiteIcon: true,
																			showPageNumber: true,
																			dimReadThreads: watch.item.zombie,
																			onThumbnailLoadError: (error, stackTrace) {
																				watch.imageboard.threadWatcher.fixBrokenThread(watch.item.threadIdentifier);
																			},
																			semanticParentIds: const [-4],
																			onThumbnailTap: (initialAttachment) {
																				final attachments = {
																					for (final w in _watchedListController.items)
																						for (final attachment in w.item.imageboard.persistence.getThreadStateIfExists(w.item.item.threadIdentifier)?.thread?.attachments ?? <Attachment>[])
																							attachment: w.item.imageboard.persistence.getThreadStateIfExists(w.item.item.threadIdentifier)!
																					};
																				showGallery(
																					context: context,
																					attachments: attachments.keys.toList(),
																					replyCounts: {
																						for (final item in attachments.entries) item.key: item.value.thread!.replyCount
																					},
																					initialAttachment: attachments.keys.firstWhere((a) => a.id == initialAttachment.id),
																					onChange: (attachment) {
																						final threadId = attachments.entries.firstWhere((_) => _.key.id == attachment.id).value.identifier;
																						_watchedListController.animateTo((p) => p.item.threadIdentifier == threadId);
																					},
																					semanticParentIds: [-4],
																					heroOtherEndIsBoxFitCover: settings.useCatalogGrid || settings.squareThumbnails
																				);
																			}
																		);
																	}
																}
															),
															onTap: () => setter(watch)
														)
													)
												);
											},
											filterHint: 'Search watched threads',
											footer: Padding(
												padding: const EdgeInsets.all(16),
												child: AnimatedBuilder(
													animation: _removeArchivedHack,
													builder: (context, _) => CupertinoButton(
														padding: const EdgeInsets.all(8),
														onPressed: (_watchedListController.items.any((w) => w.item.item.zombie)) ? () async {
															await _watchMutex.protectWrite(() async {
																_watchedListController.update(); // Should wait until mutex releases
																final toRemove = _watchedListController.items.where((w) => w.item.item.zombie).toList();
																for (final watch in toRemove) {
																	await watch.item.imageboard.notifications.removeWatch(watch.item.item);
																}
															});
														} : null,
														child: const Row(
															mainAxisSize: MainAxisSize.min,
															children: [
																Icon(CupertinoIcons.xmark),
																SizedBox(width: 8),
																Flexible(
																	child: Text('Remove archived', textAlign: TextAlign.center)
																)
															]
														)
													)
												)
											)
										)
									)
								]
							)
						);
					},
					detailBuilder: (selectedThread, setter, poppedOut) {
						return BuiltDetailPane(
							widget: selectedThread != null ? ImageboardScope(
								imageboardKey: selectedThread.imageboard.key,
								child: ThreadPage(
									thread: selectedThread.item.threadIdentifier,
									boardSemanticId: -4
								)
							) : _placeholder('Select a thread'),
							pageRouteBuilder: fullWidthCupertinoPageRouteBuilder
						);
					}
				),
				MultiMasterPane<ImageboardScoped<ThreadIdentifier>>(
					navigationBar: _savedNavigationBar('Saved Threads'),
					icon: CupertinoIcons.tray_full,
					masterBuilder: (context, selectedThread, threadSetter) {
						Comparator<PersistentThreadState> sortMethod = (a, b) => 0;
						final noDate = DateTime.fromMillisecondsSinceEpoch(0);
						if (settings.savedThreadsSortingMethod == ThreadSortingMethod.savedTime) {
							sortMethod = (a, b) => (b.savedTime ?? noDate).compareTo(a.savedTime ?? noDate);
						}
						else if (settings.savedThreadsSortingMethod == ThreadSortingMethod.lastPostTime) {
							sortMethod = (a, b) => (b.thread?.posts.last.time ?? noDate).compareTo(a.thread?.posts.last.time ?? noDate);
						}
						return SafeArea(
							child: Column(
								children: [
									AnimatedBuilder(
										animation: _threadListController,
										builder: (context, _) => MissingThreadsControls(
											missingThreads: _threadListController.items.expand((item) {
												if (item.item.imageboard != null && item.item.thread == null) {
													return [item.item.imageboard!.scope(item.item.identifier)];
												}
												return const <ImageboardScoped<ThreadIdentifier>>[];
											}).toList(),
											afterFix: () {
												_threadListController.state?.forceRebuildId++;
												_threadListController.update();
											},
											onFixAbandonedForThreads: (threadsToDelete) async {
												for (final thread in threadsToDelete) {
													await thread.imageboard.persistence.getThreadStateIfExists(thread.item)?.delete();
												}
											}
										)
									),
									Divider(
										thickness: 1,
										height: 0,
										color: ChanceTheme.primaryColorWithBrightness20Of(context)
									),
									Expanded(
										child: RefreshableList<PersistentThreadState>(
											filterableAdapter: (t) => t,
											controller: _threadListController,
											listUpdater: () async {
												final states = Persistence.sharedThreadStateBox.values.where((i) => i.savedTime != null && i.imageboard != null).toList();
												await Future.wait(states.map((s) => s.ensureThreadLoaded()));
												return states;
											},
											minUpdateDuration: Duration.zero,
											id: 'saved',
											sortMethods: [sortMethod],
											key: _savedThreadsListKey,
											updateAnimation: threadStateBoxesAnimation,
											minCacheExtent: settings.useCatalogGrid ? settings.catalogGridHeight : 0,
											gridDelegate: settings.useCatalogGrid ? SliverGridDelegateWithMaxCrossAxisExtentWithCacheTrickery(
												maxCrossAxisExtent: settings.catalogGridWidth,
												childAspectRatio: settings.catalogGridWidth / settings.catalogGridHeight
											) : null,
											itemBuilder: (itemContext, state) {
												final isSelected = selectedThread(itemContext, state.imageboard!.scope(state.identifier));
												final openInNewTabZone = context.read<OpenInNewTabZone?>();
												return ImageboardScope(
													imageboardKey: state.imageboardKey,
													child: ContextMenu(
														maxHeight: 125,
														actions: [
															if (openInNewTabZone != null) ContextMenuAction(
																child: const Text('Open in new tab'),
																trailingIcon: CupertinoIcons.rectangle_stack_badge_plus,
																onPressed: () {
																	openInNewTabZone.onWantOpenThreadInNewTab(state.imageboardKey, state.identifier);
																}
															),
															ContextMenuAction(
																child: const Text('Unsave'),
																onPressed: () {
																	state.savedTime = null;
																	state.save();
																	_threadListController.update();
																},
																trailingIcon: CupertinoIcons.xmark,
																isDestructiveAction: true
															)
														],
														child: GestureDetector(
															behavior: HitTestBehavior.opaque,
															child: Builder(
																builder: (context) => state.thread == null ? const SizedBox.shrink() : ThreadRow(
																	thread: state.thread!,
																	isSelected: isSelected,
																	contentFocus: settings.useCatalogGrid,
																	showBoardName: true,
																	showSiteIcon: true,
																	onThumbnailLoadError: (error, stackTrace) {
																		state.imageboard!.threadWatcher.fixBrokenThread(state.thread!.identifier);
																	},
																	semanticParentIds: const [-12],
																	onThumbnailTap: (initialAttachment) {
																		final attachments = _threadListController.items.expand((_) => _.item.thread!.attachments).toList();
																		showGallery(
																			context: context,
																			attachments: attachments,
																			replyCounts: {
																				for (final state in _threadListController.items)
																					for (final attachment in state.item.thread!.attachments)
																						attachment: state.item.thread!.replyCount
																			},
																			initialAttachment: attachments.firstWhere((a) => a.id == initialAttachment.id),
																			onChange: (attachment) {
																				_threadListController.animateTo((p) => p.thread?.attachments.any((a) => a.id == attachment.id) ?? false);
																			},
																			semanticParentIds: [-12],
																			heroOtherEndIsBoxFitCover: settings.useCatalogGrid || settings.squareThumbnails
																		);
																	}
																)
															),
															onTap: () => threadSetter(state.imageboard!.scope(state.identifier))
														)
													)
												);
											},
											filterHint: 'Search saved threads'
										)
									)
								]
							)
						);
					},
					detailBuilder: (selectedThread, setter, poppedOut) {
						return BuiltDetailPane(
							widget: selectedThread != null ? ImageboardScope(
								imageboardKey: selectedThread.imageboard.key,
								child: ThreadPage(
									thread: selectedThread.item,
									boardSemanticId: -12
								)
							) : _placeholder('Select a thread'),
							pageRouteBuilder: fullWidthCupertinoPageRouteBuilder
						);
					}
				),
				MultiMasterPane<_PostThreadCombo>(
					navigationBar: const AdaptiveBar(
						title: Text('Your Posts')
					),
					icon: CupertinoIcons.pencil,
					masterBuilder: (context, selected, setter) {
						return SafeArea(
							child: Column(
								children: [
									AnimatedBuilder(
										animation: _yourPostsListController,
										builder: (context, _) => MissingThreadsControls(
											missingThreads: _yourPostsListController.items.expand((item) {
												if (item.item.threadState.thread == null) {
													return [item.item.imageboard.scope(item.item.threadState.identifier)];
												}
												return const <ImageboardScoped<ThreadIdentifier>>[];
											}).toList(),
											afterFix: () {
												_yourPostsListController.state?.forceRebuildId++;
												_yourPostsListController.update();
											},
											onFixAbandonedForThreads: (threadsToDelete) async {
												for (final thread in threadsToDelete) {
													await thread.imageboard.persistence.getThreadStateIfExists(thread.item)?.delete();
												}
											}
										)
									),
									Divider(
										thickness: 1,
										height: 0,
										color: ChanceTheme.primaryColorWithBrightness20Of(context)
									),
									Expanded(
										child: RefreshableList<_PostThreadCombo>(
											filterableAdapter: (t) => t.post ?? EmptyFilterable(t.threadState.id),
											controller: _yourPostsListController,
											listUpdater: () async {
												final states = Persistence.sharedThreadStateBox.values.where((v) {
													return v.imageboard != null;
												}).map((v) => v.imageboard!.scope(v)).where((i) => i.item.youIds.isNotEmpty).toList();
												await Future.wait(states.map((s) => s.item.ensureThreadLoaded()));
												final replies = <_PostThreadCombo>[];
												for (final s in states) {
													if (s.item.thread != null) {
														for (final id in s.item.youIds) {
															final reply = s.item.thread!.posts.tryFirstWhere((p) => p.id == id);
															if (reply != null) {
																replies.add(_PostThreadCombo(
																	imageboard: s.imageboard,
																	post: reply,
																	threadState: s.item
																));
															}
														}
													}
													else {
														replies.add(_PostThreadCombo(
															imageboard: s.imageboard,
															post: null,
															threadState: s.item
														));
													}
												}
												return replies;
											},
											key: _yourPostsListKey,
											id: 'yourPosts',
											updateAnimation: threadStateBoxesAnimation,
											minUpdateDuration: Duration.zero,
											sortMethods: [(a, b) => (b.post?.time ?? b.threadState.lastOpenedTime).compareTo(a.post?.time ?? a.threadState.lastOpenedTime)],
											itemBuilder: (context, item) => (item.threadState.thread == null || item.post == null) ? const SizedBox.shrink() : ImageboardScope(
												imageboardKey: item.imageboard.key,
												child: ChangeNotifierProvider<PostSpanZoneData>(
													create: (context) => PostSpanRootZoneData(
														imageboard: item.imageboard,
														thread: item.threadState.thread!,
														semanticRootIds: [-8]
													),
													child: Builder(
														builder: (context) => PostRow(
															post: item.post!,
															isSelected: selected(context, item),
															onTap: () => setter(item),
															showBoardName: true,
															showSiteIcon: true,
															showYourPostBorder: false,
															onThumbnailLoadError: (e, st) async {
																await item.imageboard.threadWatcher.fixBrokenThread(item.threadState.identifier);
															},
															onThumbnailTap: (initialAttachment) {
																final attachments = _yourPostsListController.items.expand((_) => _.item.post?.attachments ?? <Attachment>[]).toList();
																showGallery(
																	context: context,
																	attachments: attachments,
																	replyCounts: {
																		for (final state in _yourPostsListController.items)
																			for (final attachment in state.item.imageboard.persistence.getThreadStateIfExists(state.item.post?.threadIdentifier)?.thread?.attachments ?? [])
																				attachment: state.item.imageboard.persistence.getThreadStateIfExists(state.item.post?.threadIdentifier)?.thread?.replyCount ?? 0
																	},
																	initialAttachment: attachments.firstWhere((a) => a.id == initialAttachment.id),
																	onChange: (attachment) {
																		_yourPostsListController.animateTo((p) => p.imageboard.persistence.getThreadStateIfExists(p.post?.threadIdentifier)?.thread?.attachments.any((a) => a.id == attachment.id) ?? false);
																	},
																	semanticParentIds: [-8],
																	heroOtherEndIsBoxFitCover: context.read<EffectiveSettings>().squareThumbnails
																);
															}
														)
													)
												)
											)
										)
									)
								]
							)
						);
					},
					detailBuilder: (selected, setter, poppedOut) => BuiltDetailPane(
						widget: selected == null ? _placeholder('Select a post') : ImageboardScope(
							imageboardKey: selected.imageboard.key,
							child: ThreadPage(
								thread: selected.threadState.identifier,
								initialPostId: selected.post?.id,
								boardSemanticId: -8
							)
						),
						pageRouteBuilder: fullWidthCupertinoPageRouteBuilder
					)
				),
				MultiMasterPane<ImageboardScoped<SavedPost>>(
					navigationBar: _savedNavigationBar('Saved Posts'),
					icon: CupertinoIcons.reply,
					masterBuilder: (context, selected, setter) {
						Comparator<ImageboardScoped<SavedPost>> sortMethod = (a, b) => 0;
						if (settings.savedThreadsSortingMethod == ThreadSortingMethod.savedTime) {
							sortMethod = (a, b) => b.item.savedTime.compareTo(a.item.savedTime);
						}
						else if (settings.savedThreadsSortingMethod == ThreadSortingMethod.lastPostTime) {
							sortMethod = (a, b) => b.item.post.time.compareTo(a.item.post.time);
						}
						return SafeArea(
							child: Column(
								children: [
									AnimatedBuilder(
										animation: _postListController,
										builder: (context, _) => MissingThreadsControls(
											missingThreads: _postListController.items.expand((item) {
												final threadState = item.item.imageboard.persistence.getThreadStateIfExists(item.item.item.post.threadIdentifier);
												if (threadState == null) {
													return [item.item.imageboard.scope(item.item.item.post.threadIdentifier)];
												}
												return const <ImageboardScoped<ThreadIdentifier>>[];
											}).toList(),
											afterFix: () {
												_postListController.state?.forceRebuildId++;
												_postListController.update();
											},
											onFixAbandonedForThreads: (threadsToDelete) async {
												for (final thread in threadsToDelete) {
													final postToDelete = thread.imageboard.persistence.savedPosts.values.tryFirstWhere((p) => p.post.threadIdentifier == thread.item);
													if (postToDelete != null) {
														thread.imageboard.persistence.unsavePost(postToDelete.post);
													}
												}
											},
										)
									),
									Divider(
										thickness: 1,
										height: 0,
										color: ChanceTheme.primaryColorWithBrightness20Of(context)
									),
									Expanded(
										child: RefreshableList<ImageboardScoped<SavedPost>>(
											filterableAdapter: (t) => t.item.post,
											controller: _postListController,
											listUpdater: () async {
												final savedPosts = ImageboardRegistry.instance.imageboards.expand((i) => i.persistence.savedPosts.values.map(i.scope)).toList();
												await Future.wait(savedPosts.map((s) async {
													await s.imageboard.persistence.getThreadStateIfExists(s.item.post.threadIdentifier)?.ensureThreadLoaded();
												}));
												return savedPosts;
											},
											id: 'saved',
											key: _savedPostsListKey,
											updateAnimation: savedPostNotifiersAnimation,
											minUpdateDuration: Duration.zero,
											sortMethods: [sortMethod],
											itemBuilder: (context, savedPost) {
												final threadState = savedPost.imageboard.persistence.getThreadStateIfExists(savedPost.item.post.threadIdentifier);
												if (threadState?.thread == null) {
													return const SizedBox.shrink();
												}
												return ImageboardScope(
													imageboardKey: savedPost.imageboard.key,
													child: ChangeNotifierProvider<PostSpanZoneData>(
														create: (context) => PostSpanRootZoneData(
															imageboard: savedPost.imageboard,
															thread: threadState!.thread!,
															semanticRootIds: [-2]
														),
														child: Builder(
															builder: (context) => PostRow(
																post: savedPost.item.post,
																isSelected: selected(context, savedPost),
																onTap: () => setter(savedPost),
																showBoardName: true,
																showSiteIcon: true,
																onThumbnailLoadError: (e, st) async {
																	final firstThread = threadState?.thread;
																	await savedPost.imageboard.threadWatcher.fixBrokenThread(savedPost.item.post.threadIdentifier);
																	if (firstThread != threadState!.thread || threadState.thread?.archiveName != null) {
																		savedPost.item.post = threadState.thread!.posts.firstWhere((p) => p.id == savedPost.item.post.id);
																		savedPost.imageboard.persistence.didUpdateSavedPost();
																	}
																},
																onThumbnailTap: (initialAttachment) {
																	final attachments = _postListController.items.expand((_) => _.item.item.post.attachments).toList();
																	showGallery(
																		context: context,
																		attachments: attachments,
																		replyCounts: {
																			for (final state in _postListController.items)
																				for (final attachment in state.item.imageboard.persistence.getThreadStateIfExists(state.item.item.post.threadIdentifier)?.thread?.attachments ?? [])
																					attachment: state.item.imageboard.persistence.getThreadStateIfExists(state.item.item.post.threadIdentifier)?.thread?.replyCount ?? 0
																		},
																		initialAttachment: attachments.firstWhere((a) => a.id == initialAttachment.id),
																		onChange: (attachment) {
																			_postListController.animateTo((p) => p.imageboard.persistence.getThreadStateIfExists(p.item.post.threadIdentifier)?.thread?.attachments.any((a) => a.id == attachment.id) ?? false);
																		},
																		semanticParentIds: [-2],
																		heroOtherEndIsBoxFitCover: context.read<EffectiveSettings>().squareThumbnails
																	);
																}
															)
														)
													)
												);
											},
											filterHint: 'Search saved threads'
										)
									)
								]
							)
						);
					},
					detailBuilder: (selected, setter, poppedOut) => BuiltDetailPane(
						widget: selected == null ? _placeholder('Select a post') : ImageboardScope(
							imageboardKey: selected.imageboard.key,
							child: ThreadPage(
								thread: selected.item.post.threadIdentifier,
								initialPostId: selected.item.post.id,
								boardSemanticId: -2
							)
						),
						pageRouteBuilder: fullWidthCupertinoPageRouteBuilder
					)
				),
				MultiMasterPane<ImageboardScoped<SavedAttachment>>(
					title: const Text('Saved Attachments'),
					icon: Adaptive.icons.photo,
					masterBuilder: (context, selected, setter) => AnimatedBuilder(
						key: _savedAttachmentsAnimatedBuilderKey,
						animation: savedAttachmentsNotifiersAnimation,
						builder: (context, child) {
							final list = ImageboardRegistry.instance.imageboards.expand((i) => i.persistence.savedAttachments.values.map(i.scope)).toList();
							list.sort((a, b) => b.item.savedTime.compareTo(a.item.savedTime));
							_savedAttachments = list;
							return CustomScrollView(
								controller: _savedAttachmentsController,
								slivers: [
									SliverGrid(
										delegate: SliverChildBuilderDelegate(
											(context, i) => Builder(
												builder: (context) => ImageboardScope(
													imageboardKey: list[i].imageboard.key,
													child: GestureDetector(
														child: Container(
															decoration: BoxDecoration(
																color: Colors.transparent,
																borderRadius: const BorderRadius.all(Radius.circular(4)),
																border: Border.all(color: selected(context, list[i]) ? ChanceTheme.primaryColorOf(context) : Colors.transparent, width: 2)
															),
															margin: const EdgeInsets.all(4),
															child: Hero(
																tag: TaggedAttachment(
																	attachment: list[i].item.attachment,
																	semanticParentIds: [-5]
																),
																child: SavedAttachmentThumbnail(
																	file: list[i].item.file,
																	fit: BoxFit.contain
																),
																flightShuttleBuilder: (context, animation, direction, fromContext, toContext) {
																	return (direction == HeroFlightDirection.push ? fromContext.widget as Hero : toContext.widget as Hero).child;
																},
																createRectTween: (startRect, endRect) {
																	if (startRect != null && endRect != null) {
																		if (list[i].item.attachment.type == AttachmentType.image) {
																			// Need to deflate the original startRect because it has inbuilt layoutInsets
																			// This SavedAttachmentThumbnail will always fill its size
																			final rootPadding = MediaQueryData.fromView(View.of(context)).padding - sumAdditionalSafeAreaInsets();
																			startRect = rootPadding.deflateRect(startRect);
																		}
																	}
																	return CurvedRectTween(curve: Curves.ease, begin: startRect, end: endRect);
																}
															)
														),
														onTap: () => setter(list[i])
													)
												)
											),
											childCount: list.length
										),
										gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
											crossAxisCount: 4
										)
									),
									SliverToBoxAdapter(
										child: Container(
											padding: const EdgeInsets.all(16),
											child: CupertinoButton(
												padding: const EdgeInsets.all(8),
												onPressed: list.isNotEmpty ? () async {
													final ok = await showAdaptiveDialog<bool>(
														context: context,
														barrierDismissible: true,
														builder: (context) => AdaptiveAlertDialog(
															title: const Text('Are you sure?'),
															content: const Text('All saved attachments will be removed.'),
															actions: [
																AdaptiveDialogAction(
																	isDestructiveAction: true,
																	onPressed: () => Navigator.pop(context, true),
																	child: const Text('Delete all')
																),
																AdaptiveDialogAction(
																	onPressed: () => Navigator.pop(context),
																	child: const Text('Cancel')
																)
															]
														)
													);
													if (ok != true || !mounted) {
														return;
													}
													for (final item in list) {
														item.imageboard.persistence.deleteSavedAttachment(item.item.attachment);
													}
												} : null,
												child: const Row(
													mainAxisSize: MainAxisSize.min,
													children: [
														Icon(CupertinoIcons.xmark),
														SizedBox(width: 8),
														Flexible(
															child: Text('Delete all', textAlign: TextAlign.center)
														)
													]
												)
											)
										)
									)
								]
							);
						}
					),
					detailBuilder: (selectedValue, setter, poppedOut) {
						Widget child;
						if (selectedValue == null) {
							child = _placeholder('Select an attachment');
						}
						else {
							final attachment = TaggedAttachment(
								attachment: selectedValue.item.attachment,
								semanticParentIds: poppedOut ? [-5] : [-6]
							);
							child = ImageboardScope(
								imageboardKey: selectedValue.imageboard.key,
								child: GalleryPage(
									initialAttachment: attachment,
									attachments: _savedAttachments.map((l) => TaggedAttachment(
										attachment: l.item.attachment,
										semanticParentIds: poppedOut ? [-5] : [-6]
									)).toList(),
									overrideSources: {
										for (final l in _savedAttachments)
											l.item.attachment: l.item.file.uri
									},
									onChange: (a) {
										final originalL = _savedAttachments.tryFirstWhere((l) => l.item.attachment == a.attachment);
										widget.masterDetailKey?.currentState?.setValue(4, originalL, updateDetailPane: false);
									},
									allowScroll: true,
									allowPop: poppedOut,
									updateOverlays: false,
									heroOtherEndIsBoxFitCover: false
								)
							);
						}
						return BuiltDetailPane(
							widget: child,
							pageRouteBuilder: transparentPageRouteBuilder
						);
					}
				)
			]
		);
	}

	@override
	void dispose() {
		super.dispose();
		_watchedListController.dispose();
		_threadListController.dispose();
		_postListController.dispose();
		_savedAttachmentsController.dispose();
		_removeArchivedHack.dispose();
	}
}

class ThreadWatcherControls extends StatefulWidget {
	final bool isActive;
	const ThreadWatcherControls({
		Key? key,
		required this.isActive
	}) : super(key: key);

	@override
	createState() => _ThreadWatcherControls();
}

class _ThreadWatcherControls extends State<ThreadWatcherControls> {
	@override
	Widget build(BuildContext context) {
		final settings = context.watch<EffectiveSettings>();
		final w = ImageboardRegistry.threadWatcherController;
		String notificationsError = '';
		if (Notifications.staticError != null) {
			notificationsError = 'Notification setup error:\n${Notifications.staticError!}';
		}
		for (final i in ImageboardRegistry.instance.imageboards) {
			if (i.notifications.error != null) {
				if (notificationsError.isNotEmpty) {
					notificationsError += '\n\n';
				}
				notificationsError += '${i.key} notifications error:\n${i.notifications.error}';
			}
		}
		return AnimatedSize(
			duration: const Duration(milliseconds: 300),
			child: Container(
				padding: const EdgeInsets.all(8),
				child: Column(
					mainAxisSize: MainAxisSize.min,
					children: [
						AnimatedBuilder(
							animation: w,
							builder: (context, _) => Row(
								children: [
									const SizedBox(width: 16),
									Expanded(
										child: Column(
											mainAxisSize: MainAxisSize.min,
											crossAxisAlignment: CrossAxisAlignment.center,
											children: [
												const Text('Local Watcher'),
												const SizedBox(height: 8),
												if (w.nextUpdate != null && w.lastUpdate != null) ClipRRect(
													borderRadius: const BorderRadius.all(Radius.circular(8)),
													child: TimedRebuilder(
														enabled: widget.isActive,
														interval: const Duration(seconds: 1),
														function: () {
															final now = DateTime.now();
															return w.updatingNow ? null : now.difference(w.lastUpdate!).inSeconds / w.nextUpdate!.difference(w.lastUpdate!).inSeconds;
														},
														builder: (context, value) {
															return LinearProgressIndicator(
																value: value,
																color: ChanceTheme.primaryColorOf(context).withOpacity(0.5),
																backgroundColor: ChanceTheme.primaryColorWithBrightness20Of(context),
																minHeight: 8
															);
														}
													)
												)
											]
										)
									),
									const SizedBox(width: 16),
									CupertinoButton(
										onPressed: w.update,
										child: const Icon(CupertinoIcons.refresh)
									),
									AdaptiveSwitch(
										value: w.active,
										onChanged: (val) {
											if (val) {
												w.update();
											}
											else {
												w.cancel();
											}
										}
									)
								]
							)
						),
						Row(
							children: [
								const SizedBox(width: 16),
								const AutoSizeText('Push Notifications'),
								const Spacer(),
								if (notificationsError.isNotEmpty) CupertinoButton(
									onPressed: () {
										alertError(context, notificationsError);
									},
									child: const Icon(CupertinoIcons.exclamationmark_triangle, color: Colors.red)
								),
								if (Platform.isAndroid && (settings.usePushNotifications ?? false)) CupertinoButton(
									onPressed: () async {
										try {
											final currentDistributor = await UnifiedPush.getDistributor();
											final distributors = await UnifiedPush.getDistributors();
											if (!mounted) return;
											final newDistributor = await showAdaptiveDialog<String>(
												context: context,
												barrierDismissible: true,
												builder: (context) => AdaptiveAlertDialog(
													title: const Text('UnifiedPush Distributor'),
													content: Column(
														mainAxisSize: MainAxisSize.min,
														children: [
															const SizedBox(height: 16),
															const Flexible(
																child: Text('Select which service will be used to deliver your push notifications.')
															),
															CupertinoButton(
																padding: EdgeInsets.zero,
																onPressed: () => openBrowser(context, Uri.https('unifiedpush.org', '/users/distributors/')),
																child: const Row(
																	mainAxisSize: MainAxisSize.min,
																	children: [
																		Text('More info', style: TextStyle(fontSize: 15)),
																		Icon(CupertinoIcons.chevron_right, size: 15)
																	]
																)
															)
														]
													),
													actions: [
														...distributors.map((distributor) => AdaptiveDialogAction(
															isDefaultAction: distributor == currentDistributor,
															onPressed: () => Navigator.pop(context, distributor),
															child: Text(distributor == 'com.moffatman.chan' ? 'Firebase (requires Google services)' : distributor)
														)),
														AdaptiveDialogAction(
															onPressed: () => Navigator.pop(context),
															child: const Text('Cancel')
														)
													]
												)
											);
											if (newDistributor != null) {
												await Notifications.tryUnifiedPushDistributor(newDistributor);
											}
										}
										catch (e) {
											if (mounted) {
												alertError(context, e.toStringDio());
											}
											Notifications.registerUnifiedPush();
										}
									},
									child: const Icon(CupertinoIcons.wrench)
								),
								const SizedBox(
									height: 60
								),
								AdaptiveSwitch(
									value: settings.usePushNotifications ?? false,
									onChanged: (val) {
										settings.usePushNotifications = val;
									}
								)
							]
						)
					]
				)
			)
		);
	}
}

class MissingThreadsControls extends StatelessWidget {
	final List<ImageboardScoped<ThreadIdentifier>> missingThreads;
	final VoidCallback afterFix;
	final Future<void> Function(List<ImageboardScoped<ThreadIdentifier>>) onFixAbandonedForThreads;

	const MissingThreadsControls({
		required this.missingThreads,
		required this.afterFix,
		required this.onFixAbandonedForThreads,
		super.key
	});

	@override
	Widget build(BuildContext context) {
		if (missingThreads.isEmpty) {
			return const SizedBox.shrink();
		}
		final errorColor = ChanceTheme.secondaryColorOf(context);
		return CupertinoButton(
			padding: const EdgeInsets.all(16),
			onPressed: () {
				modalLoad(context, 'Fetching missing threads', (controller) async {
					final threads = missingThreads.toList(); // In case it changes
					final failedThreads = <ImageboardScoped<ThreadIdentifier>>[];
					int i = 0;
					for (final thread in threads) {
						if (controller.cancelled) {
							break;
						}
						Thread? newThread;
						try {
							newThread = await thread.imageboard.site.getThread(thread.item, interactive: true);
						}
						on ThreadNotFoundException {
							try {
								newThread = await thread.imageboard.site.getThreadFromArchive(thread.item, interactive: true);
							}
							catch (e) {
								if (context.mounted) {
									showToast(
										context: context,
										icon: CupertinoIcons.exclamationmark_triangle,
										message: 'Failed to get ${thread.item} from archive: ${e.toStringDio()}'
									);
								}
							}
						}
						catch (e) {
							if (context.mounted) {
								showToast(
									context: context,
									icon: CupertinoIcons.exclamationmark_triangle,
									message: 'Failed to get ${thread.item}: ${e.toStringDio()}'
								);
							}
						}
						if (newThread != null) {
							final state = thread.imageboard.persistence.getThreadState(thread.item);
							state.thread = newThread;
						}
						else {
							failedThreads.add(thread);
						}
						controller.progress.value = (i + 1) / threads.length;
						i++;
					}
					if (failedThreads.length == threads.length && context.mounted) {
						// Only failed threads. Ask to just delete them
						final clearFailed = (await showAdaptiveDialog<bool>(
							context: context,
							barrierDismissible: true,
							builder: (context) => AdaptiveAlertDialog(
								title: const Text('Missing threads not found'),
								content: Text('''Some threads could not be re-downloaded.

They were deleted from their original website, and no archives of them could be found.

Would you like to forget about them?

${failedThreads.map((t) => '${t.imageboard.site.name}: ${t.imageboard.site.formatBoardName(t.imageboard.persistence.getBoard(t.item.board)).replaceFirst(RegExp(r'\/$'), '')}/${t.item.id}').join('\n')}'''),
								actions: [
									AdaptiveDialogAction(
										isDestructiveAction: true,
										onPressed: () {
											Navigator.of(context).pop(true);
										},
										child: const Text('Forget All')
									),
									AdaptiveDialogAction(
										child: const Text('Cancel'),
										onPressed: () {
											Navigator.of(context).pop();
										}
									)
								]
							)
						)) ?? false;
						if (clearFailed) {
							await onFixAbandonedForThreads(failedThreads);
						}
					}
					afterFix();
				}, cancellable: true);
			},
			child: Row(
				mainAxisSize: MainAxisSize.min,
				children: [
					Icon(CupertinoIcons.exclamationmark_triangle, color: errorColor),
					const SizedBox(width: 8),
					Flexible(
						child: Text('${missingThreads.length} missing threads', style: TextStyle(
							color: errorColor,
							fontWeight: FontWeight.bold
						))
					)
				]
			)
		);
	}
}
