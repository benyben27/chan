import 'dart:io';

import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _platform = MethodChannel('com.moffatman.chan/statusBar');

Future<void> showStatusBar() async {
	if (Platform.isIOS) {
		await _platform.invokeMethod('showStatusBar');
	}
	else {
		if (EffectiveSettings.featureStatusBarWorkaround && Persistence.settings.useStatusBarWorkaround == true) {
			await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
		}
		else {
			_guessWorkaround();
			await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
		}
	}
}

Future<void> hideStatusBar() async {
	if (Platform.isIOS) {
		await _platform.invokeMethod('hideStatusBar');
	}
	else {
		if (EffectiveSettings.featureStatusBarWorkaround && Persistence.settings.useStatusBarWorkaround == true) {
			await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
		}
		else {
			_guessWorkaround();
			await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
		}
	}
}

Size? _lastSize;

void _guessWorkaround() {
	final currentSize = MediaQueryData.fromView(PlatformDispatcher.instance.views.first).size;
	if (currentSize != _lastSize && _lastSize != null) {
		final previousValue = Persistence.settings.useStatusBarWorkaround;
		Persistence.settings.useStatusBarWorkaround ??= true;
		if (Persistence.settings.useStatusBarWorkaround != previousValue) {
			Persistence.settings.save();
		}
	}
	_lastSize = currentSize;
}