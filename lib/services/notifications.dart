import 'dart:convert';
import 'dart:io';

import 'package:chan/main.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/thread_watcher.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/version.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:chan/firebase_options.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';

abstract class PushNotification {
	final ThreadIdentifier thread;
	final int? postId;
	const PushNotification({
		required this.thread,
		required this.postId
	});
	BoardThreadOrPostIdentifier get target => BoardThreadOrPostIdentifier(thread.board, thread.id, postId);
	bool get isThread => postId == null || thread.id == postId;
}

class ThreadWatchNotification extends PushNotification {
	const ThreadWatchNotification({
		required super.thread,
		required super.postId
	});
}

class BoardWatchNotification extends PushNotification {
	final String filter;

	const BoardWatchNotification({
		required super.thread,
		required super.postId,
		required this.filter
	});
}

const _platform = MethodChannel('com.moffatman.chan/notifications');

Future<void> promptForPushNotificationsIfNeeded(BuildContext context) async {
	final settings = context.read<EffectiveSettings>();
	if (settings.usePushNotifications == null) {
		final choice = await showCupertinoDialog<bool>(
			context: context,
			builder: (context) => CupertinoAlertDialog(
				title: const Text('Use push notifications?'),
				content: const Text('Notifications for (You)s will be sent while the app is closed.\nFor this to work, the thread IDs you want to be notified about will be sent to a notification server.'),
				actions: [
					CupertinoDialogAction(
						child: const Text('No'),
						onPressed: () {
							Navigator.of(context).pop(false);
						}
					),
					CupertinoDialogAction(
						child: const Text('Yes'),
						onPressed: () {
							Navigator.of(context).pop(true);
						}
					)
				]
			)
		);
		if (choice != null) {
			settings.usePushNotifications = choice;
		}
	}
}

Future<void> clearNotifications(Notifications notifications, Watch watch) async {
	await _platform.invokeMethod('clearNotificationsWithProperties', {
		'userId': notifications.id,
		'type': watch.type,
		if (watch is BoardWatch) ...{
			'board': watch.board
		}
		else if (watch is ThreadWatch) ...{
			'board': watch.board,
			'threadId': watch.threadId.toString()
		}
	});
}

Future<void> updateNotificationsBadgeCount() async {
	if (!Platform.isIOS) {
		return;
	}
	try {
		await _platform.invokeMethod('updateBadge');
	}
	catch (e, st) {
		print(e);
		print(st);
	}
}

const _notificationSettingsApiRoot = 'https://push.chance.surf';

class Notifications {
	static String? staticError;
	String? error;
	static final Map<String, Notifications> _children = {};
	final tapStream = BehaviorSubject<BoardThreadOrPostIdentifier>();
	final foregroundStream = BehaviorSubject<PushNotification>();
	final Persistence persistence;
	ThreadWatcher? localWatcher;
	final String siteType;
	final String siteData;
	String get id => persistence.browserState.notificationsId;
	List<ThreadWatch> get threadWatches => persistence.browserState.threadWatches;
	List<BoardWatch> get boardWatches => persistence.browserState.boardWatches;
	static final Map<String, List<RemoteMessage>> _unrecognizedByUserId = {};
	static final _client = Dio(BaseOptions(
		headers: {
			HttpHeaders.userAgentHeader: 'Chance/$kChanceVersion'
		}
	));

	Notifications({
		required ImageboardSite site,
		required this.persistence
	}) : siteType = site.siteType,
		siteData = site.siteData;

	@override
	String toString() => 'Notifications(siteType: $siteType, id: $id, tapStream: $tapStream)';

	static void _onMessageOpenedApp(RemoteMessage message) {
		print('onMessageOpenedApp');
		print(message.data);
		Future.delayed(const Duration(seconds: 1), updateNotificationsBadgeCount);
		final child = _children[message.data['userId']];
		if (child == null) {
			print('Opened via message with unknown userId: ${message.data}');
			_unrecognizedByUserId.update(message.data['userId'], (list) => list..add(message), ifAbsent: () => [message]);
			return;
		}
		if (message.data['type'] == 'thread' || message.data['type'] == 'board') {
			child.tapStream.add(BoardThreadOrPostIdentifier(
				message.data['board'],
				int.parse(message.data['threadId']),
				int.tryParse(message.data['postId'] ?? '')
			));
		}
	}

	static _onTokenRefresh(String newToken) {
		print('newToken $newToken');
	}

	static Future<void> initializeStatic() async {
		try {
			await Firebase.initializeApp(
				options: DefaultFirebaseOptions.currentPlatform,
			);
			FirebaseMessaging messaging = FirebaseMessaging.instance;
			messaging.onTokenRefresh.listen(_onTokenRefresh);
			//print('Token: ${await messaging.getToken()}');
			if (Persistence.settings.usePushNotifications == true) {
				await messaging.requestPermission();
			}
			final initialMessage = await messaging.getInitialMessage();
			if (initialMessage != null) {
				_onMessageOpenedApp(initialMessage);
			}
			FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
				if (message.data.containsKey('threadId') && message.data.containsKey('userId')) {
					final child = _children[message.data['userId']];
					if (child == null) {
						print('Opened via message with unknown userId: ${message.data}');
						return;
					}
					PushNotification notification;
					if (message.data['type'] == 'thread') {
						notification = ThreadWatchNotification(
							thread: ThreadIdentifier(message.data['board'], int.parse(message.data['threadId'])),
							postId: int.tryParse(message.data['postId'] ?? '')
						);
					}
					else if (message.data['type'] == 'board') {
						notification = BoardWatchNotification(
							thread: ThreadIdentifier(message.data['board'], int.parse(message.data['threadId'])),
							postId: int.tryParse(message.data['postId'] ?? ''),
							filter: message.data['filter']
						);
					}
					else {
						throw Exception('Unknown notification type ${message.data['type']}');
					}
					await child.localWatcher?.updateThread(notification.thread);
					if (child.getThreadWatch(notification.thread)?.foregroundMuted != true) {
						child.foregroundStream.add(notification);
					}
				}
			});
			FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);
			staticError = null;
		}
		catch (e) {
			print('Error initializing notifications: $e');
			staticError = e.toStringDio();
		}
	}

	static Future<void> didUpdateUsePushNotificationsSetting() async {
		if (Persistence.settings.usePushNotifications == true) {
			await FirebaseMessaging.instance.requestPermission();
		}
		await Future.wait(_children.values.map((c) => c.initialize()));
	}

	static Future<void> didUpdateFilter() async {
		if (Persistence.settings.usePushNotifications == true) {
			await Future.wait(_children.values.map((c) => c.initialize()));
		}
	}

	static Future<String?> getToken() {
		return FirebaseMessaging.instance.getToken();
	}

	String _calculateDigest() {
		final boards = [
			...threadWatches.where((w) => !w.zombie).map((w) => w.board),
			...boardWatches.map((w) => w.board)
		];
		boards.sort((a, b) => a.compareTo(b));
		return base64Encode(md5.convert(boards.join(',').codeUnits).bytes);
	}

	Future<void> deleteAllNotificationsFromServer() async {
		final response = await _client.patch('$_notificationSettingsApiRoot/user/$id', data: jsonEncode({
			'token': await Notifications.getToken(),
			'siteType': siteType,
			'siteData': siteData,
			'filters': ''
		}));
		final String digest = response.data['digest'];
		final emptyDigest = base64Encode(md5.convert(''.codeUnits).bytes);
		if (digest != emptyDigest) {
			print('Need to resync notifications $id');
			await _client.put('$_notificationSettingsApiRoot/user/$id', data: jsonEncode({
				'watches': []
			}));
		}
	}

	Future<void> initialize() async {
		_children[id] = this;
		try {
			if (Persistence.settings.usePushNotifications == true) {
				final response = await _client.patch('$_notificationSettingsApiRoot/user/$id', data: jsonEncode({
					'token': await Notifications.getToken(),
					'siteType': siteType,
					'siteData': siteData,
					'filters': settings.filterConfiguration
				}));
				final String digest = response.data['digest'];
				if (digest != _calculateDigest()) {
					print('Need to resync notifications $id');
					await _client.put('$_notificationSettingsApiRoot/user/$id', data: jsonEncode({
						'watches': [
							...threadWatches.where((w) => !w.zombie),
							...boardWatches
						].map((w) => w.toMap()).toList()
					}));
				}
			}
			else {
				await deleteAllNotificationsFromServer();
			}
			if (_unrecognizedByUserId.containsKey(id)) {
				_unrecognizedByUserId[id]?.forEach(_onMessageOpenedApp);
				_unrecognizedByUserId[id]?.clear();
			}
			error = null;
		}
		catch (e) {
			print('Error initializing notifications: $e');
			error = e.toStringDio();
		}
	}

	ThreadWatch? getThreadWatch(ThreadIdentifier thread) {
		return threadWatches.tryFirstWhere((w) => w.board == thread.board && w.threadId == thread.id);
	}
	
	BoardWatch? getBoardWatch(String boardName) {
		return boardWatches.tryFirstWhere((w) => w.board == boardName);
	}

	void subscribeToThread({
		required ThreadIdentifier thread,
		required int lastSeenId,
		required bool localYousOnly,
		required bool pushYousOnly,
		required bool push,
		required List<int> youIds
	}) {
		final existingWatch = threadWatches.tryFirstWhere((w) => w.threadIdentifier == thread);
		if (existingWatch != null) {
			existingWatch.youIds = youIds;
			existingWatch.lastSeenId = lastSeenId;
			didUpdateWatch(existingWatch);
		}
		else {
			final watch = ThreadWatch(
				board: thread.board,
				threadId: thread.id,
				lastSeenId: lastSeenId,
				localYousOnly: localYousOnly,
				pushYousOnly: pushYousOnly,
				youIds: youIds,
				push: push
			);
			threadWatches.add(watch);
			if (Persistence.settings.usePushNotifications == true && watch.push) {
				_create(watch);
			}
			localWatcher?.onWatchUpdated(watch);
			persistence.didUpdateBrowserState();
		}
	}

void subscribeToBoard({
		required String boardName,
		required bool threadsOnly
	}) {
		final existingWatch = getBoardWatch(boardName);
		if (existingWatch != null) {
			existingWatch.threadsOnly = threadsOnly;
			didUpdateWatch(existingWatch);
		}
		else {
			final watch = BoardWatch(
				board: boardName,
				threadsOnly: threadsOnly
			);
			boardWatches.add(watch);
			if (Persistence.settings.usePushNotifications == true && watch.push) {
				_create(watch);
			}
			localWatcher?.onWatchUpdated(watch);
			persistence.didUpdateBrowserState();
		}
	}

	void unsubscribeFromThread(ThreadIdentifier thread) {
		final watch = getThreadWatch(thread);
		if (watch != null) {
			removeWatch(watch);
		}
	}

	void unsubscribeFromBoard(String boardName) {
		final watch = getBoardWatch(boardName);
		if (watch != null) {
			removeWatch(watch);
		}
	}

	void foregroundMuteThread(ThreadIdentifier thread) {
		final watch = getThreadWatch(thread);
		if (watch != null) {
			watch.foregroundMuted = true;
			localWatcher?.onWatchUpdated(watch);
			persistence.didUpdateBrowserState();
		}
	}

	void foregroundUnmuteThread(ThreadIdentifier thread) {
		final watch = getThreadWatch(thread);
		if (watch != null) {
			watch.foregroundMuted = false;
			localWatcher?.onWatchUpdated(watch);
			persistence.didUpdateBrowserState();
		}
	}

	void didUpdateWatch(Watch watch, {bool possiblyDisabledPush = false}) {
		if (Persistence.settings.usePushNotifications == true && watch.push) {
			_replace(watch);
		}
		else if (possiblyDisabledPush) {
			_delete(watch);
		}
		localWatcher?.onWatchUpdated(watch);
		persistence.didUpdateBrowserState();
	}

	void zombifyThreadWatch(ThreadWatch watch) {
		if (Persistence.settings.usePushNotifications == true && watch.push) {
			_delete(watch);
		}
		watch.zombie = true;
		localWatcher?.onWatchUpdated(watch);
		persistence.didUpdateBrowserState();
	}

	void removeWatch(Watch watch) async {
		if (Persistence.settings.usePushNotifications == true && watch.push) {
			_delete(watch);
		}
		if (watch is ThreadWatch) {
			threadWatches.remove(watch);
		}
		else if (watch is BoardWatch) {
			boardWatches.remove(watch);
		}
		localWatcher?.onWatchRemoved(watch);
		persistence.didUpdateBrowserState();
		await clearNotifications(this, watch);
		clearOverlayNotifications(this, watch);
		await updateNotificationsBadgeCount();
	}

	Future<void> updateLastKnownId(ThreadWatch watch, int lastKnownId, {bool foreground = false}) async {
		print('$foreground ${WidgetsBinding.instance.lifecycleState}');
		if (foreground && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
			await clearNotifications(this, watch);
			clearOverlayNotifications(this, watch);
			await updateNotificationsBadgeCount();
		}
		final couldUpdate = watch.lastSeenId != lastKnownId;
		watch.lastSeenId = lastKnownId;
		if (couldUpdate && Persistence.settings.usePushNotifications == true && watch.push) {
			_update(watch);
		}
	}

	Future<void> _create(Watch watch) async {
		await _client.post(
			'$_notificationSettingsApiRoot/user/$id/watch',
			data: jsonEncode(watch.toMap())
		);
	}

	Future<void> _replace(Watch watch) async {
		if (watch.push) {
			await _client.put(
				'$_notificationSettingsApiRoot/user/$id/watch',
				data: jsonEncode(watch.toMap())
			);
		}
		else {
			await _delete(watch);
		}
	}

	Future<void> _update(Watch watch) async {
		await _client.patch(
			'$_notificationSettingsApiRoot/user/$id/watch',
			data: jsonEncode(watch.toMap())
		);
	}

	Future<void> _delete(Watch watch) async {
		await _client.delete(
			'$_notificationSettingsApiRoot/user/$id/watch',
			data: jsonEncode(watch.toMap())
		);
	}

	void dispose() {
		tapStream.close();
		foregroundStream.close();
	}
}