

import 'package:chan/services/notifications.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/thread_watcher.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/util.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:mutex/mutex.dart';

class ImageboardNotFoundException implements Exception {
	String board;
	ImageboardNotFoundException(this.board);
	@override
	String toString() => 'Imageboard not found: $board';
}

class Imageboard extends ChangeNotifier {
	final EffectiveSettings settings;
	dynamic siteData;
	late ImageboardSite site;
	late final Persistence persistence;
	late final ThreadWatcher threadWatcher;
	late final Notifications notifications;
	String? setupErrorMessage;
	String? boardFetchErrorMessage;
	bool boardsLoading = false;
	bool initialized = false;
	final String key;

	Imageboard({
		required this.key,
		required this.settings,
		required this.siteData
	});
	
	void updateSiteData(dynamic siteData) {
		try {
			final oldSite = site;
			site = makeSite(siteData);
			site.persistence = persistence;
			if (site != oldSite) {
				notifyListeners();
			}
		}
		catch (e) {
			setupErrorMessage = e.toStringDio();
			notifyListeners();
		}
	}

	Future<void> initialize({
		Duration threadWatcherInterval = const Duration(seconds: 90),
		List<String> threadWatcherWatchForStickyOnBoards = const []
	}) async {
		try {
			print('Initializing $key');
			site = makeSite(siteData);
			persistence = Persistence(key);
			await persistence.initialize();
			site.persistence = persistence;
			notifications = Notifications(
				persistence: persistence,
				site: site
			);
			await notifications.initialize();
			threadWatcher = ThreadWatcher(
				imageboardKey: key,
				site: site,
				persistence: persistence,
				settings: settings,
				notifications: notifications,
				interval: threadWatcherInterval,
				watchForStickyOnBoards: threadWatcherWatchForStickyOnBoards
			);
			notifications.localWatcher = threadWatcher;
			setupBoards(); // don't await
			print('Initialization complete $key');
			initialized = true;
		}
		catch (e) {
			setupErrorMessage = e.toStringDio();
		}
		notifyListeners();
	}

	Future<void> setupBoards() async {
		try {
			boardsLoading = true;
			boardFetchErrorMessage = null;
			notifyListeners();
			final freshBoards = await site.getBoards();
			await persistence.reinitializeBoards(freshBoards);
		}
		catch (error, st) {
			print(error);
			print(st);
			boardFetchErrorMessage = error.toStringDio();
		}
		boardsLoading = false;
		notifyListeners();
	}

	@override
	void dispose() {
		super.dispose();
		threadWatcher.dispose();
		persistence.dispose();
	}
}

class ImageboardRegistry extends ChangeNotifier {
	static ImageboardRegistry? _instance;
	static ImageboardRegistry get instance {
		_instance ??= ImageboardRegistry._();
		return _instance!;
	}

	ImageboardRegistry._();
	
	String? setupError;
	String? setupStackTrace;
	final Map<String, Imageboard> _sites = {};
	int get count => _sites.length;
	Iterable<Imageboard> get imageboards => _sites.values;
	bool initialized = false;
	BuildContext? context;
	final _mutex = Mutex();

	Future<void> handleSites({
		required EffectiveSettings settings,
		required Map<String, dynamic> data,
		required BuildContext context
	}) {
		return _mutex.protect(() async {
			initialized = false;
			context = context;
			setupError = null;
			try {
				final siteKeysToRemove = _sites.keys.toList();
				for (final entry in data.entries) {
					siteKeysToRemove.remove(entry.key);
					if (_sites.containsKey(entry.key)) {
						// Site not changed
						_sites[entry.key]?.updateSiteData(entry.value);
					}
					else {
						_sites[entry.key] = Imageboard(
							settings: settings,
							siteData: entry.value,
							key: entry.key
						);
						await _sites[entry.key]?.initialize();
					}
					// Only try to reauth on wifi
					Future.microtask(() async {
						final site = _sites[entry.key]!.site;
						final savedFields = await site.getSavedLoginFields();
						if (savedFields != null && settings.connectivity == ConnectivityResult.wifi) {
							try {
								await site.login(savedFields);
								print('Auto-logged in');
							}
							catch (e) {
								showToast(
									context: context,
									icon: CupertinoIcons.exclamationmark_triangle,
									message: 'Failed to log in to ${site.getLoginSystemName()}'
								);
								print('Problem auto-logging in: $e');
							}
						}
					});
				}
				_sites.removeWhere((k, v) => siteKeysToRemove.contains(k));
			}
			catch (e, st) {
				setupError = 'Fatal setup error\n${e.toStringDio()}';
				setupStackTrace = st.toStringDio();
				print(e);
				print(st);
			}
			initialized = true;
			notifyListeners();
		});
	}

	Imageboard? getImageboard(String key) {
		if (_sites[key]?.initialized == true) {
			return _sites[key];
		}
		return null;
	}

	Imageboard? getImageboardUnsafe(String key) {
		return _sites[key];
	}
}

class ImageboardScoped<T> {
	final Imageboard imageboard;
	final T item;

	ImageboardScoped({
		required this.imageboard,
		required this.item
	});

	@override
	bool operator == (dynamic other) => (other is ImageboardScoped) && (other.imageboard == imageboard) && (other.item == item);
	@override
	int get hashCode => Object.hash(imageboard, item);
}