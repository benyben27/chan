import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/widgets/cupertino_page_route.dart';
import 'package:chan/widgets/util.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart';
import 'package:provider/provider.dart';

extension CloudflareWanted on RequestOptions {
	bool get cloudflare => extra['cloudflare'] == true;
}
extension CloudflareHandled on Response {
	bool get cloudflare => extra['cloudflare'] == true;
}

dynamic _decode(String data) {
	if (data.startsWith('{')) {
		try {
			return jsonDecode(data);
		}
		on FormatException {
			// ignore
		}
	}
	return data;
}

class CloudflareInterceptor extends Interceptor {
	static bool _titleMatches(String title) {
		return title.contains('Cloudflare') || title.contains('Just a moment') || title.contains('Please wait');
	}

	static bool _responseMatches(Response response) {
		if ([403, 503].contains(response.statusCode) && response.headers.value(Headers.contentTypeHeader)!.contains('text/html')) {
			final document = parse(response.data);
			final title = document.querySelector('title')?.text ?? '';
			return _titleMatches(title);
		}
		return false;
	}

	Future<String?> _useWebview({
		bool skipHeadless = false,
		InAppWebViewInitialData? initialData,
		URLRequest? initialUrlRequest,
		required String userAgent,
		required Uri cookieUrl,
	}) async {
		assert(initialData != null || initialUrlRequest != null);
		await CookieManager.instance().deleteAllCookies();
		final initialSettings = InAppWebViewSettings(
			userAgent: userAgent,
			clearCache: true,
			clearSessionCache: true
		);
		void Function(InAppWebViewController, Uri?) buildOnLoadStop(ValueChanged<String?> callback) => (controller, uri) async {
			final title = await controller.getTitle() ?? '';
			if (!_titleMatches(title)) {
				final cookies = await CookieManager.instance().getCookies(url: WebUri.uri(uri!));
				await Persistence.currentCookies.saveFromResponse(uri, cookies.map((cookie) {
					final newCookie = io.Cookie(cookie.name, cookie.value);
					newCookie.domain = cookie.domain;
					if (cookie.expiresDate != null) {
						newCookie.expires = DateTime.fromMillisecondsSinceEpoch(cookie.expiresDate!);
					}
					newCookie.httpOnly = cookie.isHttpOnly ?? false;
					newCookie.path = cookie.path;
					newCookie.secure = cookie.isSecure ?? false;
					return newCookie;
				}).toList());
				final html = await controller.getHtml() ?? '';
				if (html.contains('<pre')) {
					// Raw JSON response, but web-view has put it within a <pre>
					final document = parse(html);
					callback(document.querySelector('pre')!.innerHtml);
				}
				else {
					callback(html);
				}
			}
		};
		HeadlessInAppWebView? headlessWebView;
		if (!skipHeadless) {
			final headlessCompleter = Completer<String?>();
			headlessWebView = HeadlessInAppWebView(
				initialSettings: initialSettings,
				initialUrlRequest: initialUrlRequest,
				initialData: initialData,
				onLoadStop: buildOnLoadStop(headlessCompleter.complete)
			);
			await headlessWebView.run();
			showToast(
				context: ImageboardRegistry.instance.context!,
				message: 'Authorizing Cloudflare',
				icon: CupertinoIcons.cloud
			);
			await Future.any([
				headlessCompleter.future,
				Future.delayed(const Duration(seconds: 7))
			]);
			if (headlessCompleter.isCompleted) {
				headlessWebView.dispose();
				return headlessCompleter.future;
			}
		}
		final ret = await Navigator.of(ImageboardRegistry.instance.context!).push<String?>(FullWidthCupertinoPageRoute(
			builder: (context) => CupertinoPageScaffold(
				navigationBar: const CupertinoNavigationBar(
					transitionBetweenRoutes: false,
					middle: Text('Cloudflare Login')
				),
				child: InAppWebView(
					headlessWebView: headlessWebView,
					initialSettings: initialSettings,
					initialUrlRequest: initialUrlRequest,
					initialData: initialData,
					onLoadStop: buildOnLoadStop(Navigator.of(context).pop)
				)
			),
			// ignore: use_build_context_synchronously
			showAnimations: ImageboardRegistry.instance.context!.read<EffectiveSettings?>()?.showAnimations ?? true
		));
		headlessWebView?.dispose();
		return ret;
	}

	@override
	void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
		if (options.cloudflare) {
			try {
				if (options.data is FormData) {
					options.headers[Headers.contentTypeHeader] =
							'multipart/form-data; boundary=${options.data.boundary}';
					options.data = await (options.data as FormData).finalize().fold<List<int>>([], (a, b) => a + b);
				}
				else if (options.data is String) {
					options.data = utf8.encode(options.data);
				}
				final data = await _useWebview(
					cookieUrl: options.uri,
					userAgent: options.headers['user-agent'] ?? Persistence.settings.userAgent,
					initialUrlRequest: URLRequest(
						url: WebUri.uri(options.uri),
						method: options.method,
						headers: {
							for (final h in options.headers.entries) h.key: h.value
						},
						body: options.data == null ? null : Uint8List.fromList(options.data)
					)
				);
				if (data != null) {
					handler.resolve(Response(
						requestOptions: options,
						data: _decode(data),
						statusCode: 200,
						extra: {
							'cloudflare': true
						}
					));
					return;
				}
			}
			catch (e) {
				handler.reject(DioError(
					requestOptions: options,
					error: e
				));
				return;
			}
		}
		handler.next(options);
	}

	@override
	void onResponse(Response response, ResponseInterceptorHandler handler) async {
		if (_responseMatches(response)) {
			final data = await _useWebview(
				cookieUrl: response.requestOptions.uri,
				userAgent: response.requestOptions.headers['user-agent'] ?? Persistence.settings.userAgent,
				initialData: InAppWebViewInitialData(
					data: response.data,
					baseUrl: WebUri.uri(response.realUri)
				)
			);
			if (data != null) {
				handler.resolve(Response(
					data: _decode(data),
					statusCode: 200,
					requestOptions: response.requestOptions,
					extra: {
						'cloudflare': true
					}
				));
				return;
			}
		}
		handler.next(response);
	}

	@override
	void onError(DioError err, ErrorInterceptorHandler handler) async {
		if (err.type == DioErrorType.response && err.response != null && _responseMatches(err.response!)) {
			final data = await _useWebview(
				cookieUrl: err.requestOptions.uri,
				userAgent: err.requestOptions.headers['user-agent'] ?? Persistence.settings.userAgent,
				initialData: InAppWebViewInitialData(
					data: err.response!.data,
					baseUrl: WebUri.uri(err.response!.realUri)
				)
			);
			if (data != null) {
				handler.resolve(Response(
					data: _decode(data),
					statusCode: 200,
					requestOptions: err.requestOptions,
					extra: {
						'cloudflare': true
					}
				));
				return;
			}
		}
		handler.next(err);
	}
}