import 'dart:math';

import 'package:chan/widgets/injecting_navigator.dart';
import 'package:chan/widgets/util.dart';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:chan/widgets/cupertino_page_route.dart';
import 'package:provider/provider.dart';

PageRoute fullWidthCupertinoPageRouteBuilder(WidgetBuilder builder) => FullWidthCupertinoPageRoute(builder: builder);
PageRoute transparentPageRouteBuilder(WidgetBuilder builder) => TransparentRoute(builder: builder);

class BuiltDetailPane {
	final Widget widget;
	final PageRoute Function(WidgetBuilder builder) pageRouteBuilder;

	BuiltDetailPane({
		required this.widget,
		required this.pageRouteBuilder
	});

	PageRoute get pageRoute => pageRouteBuilder((context) => widget);
}

class MasterDetailPage<T> extends StatelessWidget {
	final Object? id;
	final double? twoPaneBreakpoint;
	final Widget Function(BuildContext context, T? selectedValue, ValueChanged<T?> valueSetter) masterBuilder;
	final BuiltDetailPane Function(T? selectedValue, bool poppedOut) detailBuilder;
	final T? initialValue;
	final ValueChanged<T?>? onValueChanged;
	const MasterDetailPage({
		required this.id,
		required this.masterBuilder,
		required this.detailBuilder,
		this.twoPaneBreakpoint,
		this.initialValue,
		this.onValueChanged,
		Key? key
	}) : super(key: key);
	@override
	Widget build(BuildContext context) {
		return MultiMasterDetailPage(
			showChrome: false,
			id: id,
			paneCreator: () => [
				MultiMasterPane<T>(
					masterBuilder: masterBuilder,
					detailBuilder: detailBuilder,
					initialValue: initialValue,
					onValueChanged: onValueChanged
				)
			]
		);
	}
}

class MultiMasterPane<T> {
	final Widget? title;
	final ObstructingPreferredSizeWidget? navigationBar;
	final IconData? icon;
	final Widget Function(BuildContext context, T? selectedValue, ValueChanged<T?> valueSetter) masterBuilder;
	final BuiltDetailPane Function(T? selectedValue, bool poppedOut) detailBuilder;
	T? currentValue;
	final ValueChanged<T?>? onValueChanged;

	MultiMasterPane({
		required this.masterBuilder,
		required this.detailBuilder,
		this.title,
		this.navigationBar,
		this.icon,
		T? initialValue,
		this.onValueChanged
	}) : currentValue = initialValue;

	Widget buildMaster(BuildContext context, VoidCallback onNewValue, bool provideCurrentValue) {
		return masterBuilder(context, provideCurrentValue ? currentValue : null, (newValue) {
			currentValue = newValue;
			onValueChanged?.call(newValue);
			onNewValue();
		});
	}

	void onPushReturn(dynamic value) {
		if (value != false) {
			// it was a user-initiated pop
			currentValue = null;
			onValueChanged?.call(null);
		}
	}

	Widget buildDetail() {
		return detailBuilder(currentValue, false).widget;
	}

	PageRoute buildDetailRoute() {
		return detailBuilder(currentValue, true).pageRoute;
	}
}

class MultiMasterDetailPage extends StatefulWidget {
	final double twoPaneBreakpoint;
	final Object? id;
	final List<MultiMasterPane> Function() paneCreator;
	final bool showChrome;

	const MultiMasterDetailPage({
		required this.paneCreator,
		this.id,
		this.twoPaneBreakpoint = 700,
		this.showChrome = true,
		Key? key
	}) : super(key: key);

	@override
	createState() => _MultiMasterDetailPageState();
}

class _MultiMasterDetailPageState extends State<MultiMasterDetailPage> with TickerProviderStateMixin {
	late TabController _tabController;
	final _masterKey = GlobalKey<NavigatorState>();
	final _detailKey = GlobalKey<NavigatorState>();
	final _masterContentKey = GlobalKey();
	final _detailContentKey = GlobalKey();
	List<MultiMasterPane> panes = [];
 	bool? lastOnePane;
	late bool onePane;

	void _onPaneChanged() {
		setState(() {});
	}

	@override
	void initState() {
		super.initState();
		panes = widget.paneCreator();
		_tabController = TabController(length: panes.length, vsync: this);
		_tabController.addListener(_onPaneChanged);
		Future.delayed(const Duration(milliseconds: 100), () {
			if (panes[_tabController.index].currentValue != null) {
				_onNewValue(panes[_tabController.index]);
			}
		});
	}

	@override
	void didUpdateWidget(MultiMasterDetailPage old) {
		super.didUpdateWidget(old);
		if (old.id != widget.id) {
			int newIndex = _tabController.index;
			panes = widget.paneCreator();
			if (_tabController.index >= panes.length) {
				newIndex = max(0, panes.length - 1);
			}
			_tabController.removeListener(_onPaneChanged);
			_tabController = TabController(
				initialIndex: newIndex,
				length: panes.length,
				vsync: this
			);
			_tabController.addListener(_onPaneChanged);
		}
	}

	void _onNewValue<T> (MultiMasterPane<T> pane) {
		if (onePane) {
			_masterKey.currentState!.push(pane.buildDetailRoute()).then(pane.onPushReturn);
		}
		else {
			_detailKey.currentState?.popUntil((route) => route.isFirst);
		}
		setState(() {});
	}

	@override
	Widget build(BuildContext context) {
		onePane = MediaQuery.of(context).size.width < widget.twoPaneBreakpoint;
		final masterNavigator = Provider.value(
			value: _masterKey,
			child: ClipRect(
				child: PrimaryScrollControllerInjectingNavigator(
					navigatorKey: _masterKey,
					observers: [HeroController()],
					buildRoot: (context) {
							Widget child = TabBarView(
								controller: _tabController,
								physics: panes.length > 1 ? const AlwaysScrollableScrollPhysics() : const NeverScrollableScrollPhysics(),
								children: panes.map((pane) => pane.buildMaster(context, () => _onNewValue(pane), !onePane)).toList()
							);
							if (widget.showChrome) {
								child = CupertinoPageScaffold(
									resizeToAvoidBottomInset: false,
									navigationBar: panes[_tabController.index].navigationBar ?? CupertinoNavigationBar(
										transitionBetweenRoutes: false,
										middle: panes[_tabController.index].title
									),
									child: Column(
										children: [
											SafeArea(
												bottom: false,
												child: Material(
													color: CupertinoTheme.of(context).scaffoldBackgroundColor,
													child: TabBar(
														controller: _tabController,
														tabs: panes.map((pane) => Tab(
															icon: Icon(
																pane.icon,
																color: CupertinoTheme.of(context).primaryColor
															)
														)).toList()
													)
												)
											),
											MediaQuery(
												data: MediaQuery.of(context).removePadding(removeTop: true),
												child: Expanded(
													child: child
												)
											)
										]
									)
								);
							}
							child = KeyedSubtree(
								key: _masterContentKey,
								child: child
							);
							return child;
						}
				)
			)
		);
		final detailNavigator = Provider.value(
			value: _detailKey,
			child: ClipRect(
				child: PrimaryScrollControllerInjectingNavigator(
					navigatorKey: _detailKey,
					buildRoot: (context) => KeyedSubtree(
						key: _detailContentKey,
						child: panes[_tabController.index].buildDetail()
					)
				)
			)
		);
		if (lastOnePane != null && lastOnePane != onePane) {
			final pane = panes[_tabController.index];
			if (onePane && pane.currentValue != null) {
				_masterKey.currentState!.push(pane.buildDetailRoute()).then(pane.onPushReturn);
			}
			else {
				while (_masterKey.currentState?.canPop() ?? false) {
					_masterKey.currentState?.pop(false);
				}
				while (_detailKey.currentState?.canPop() ?? false) {
					_detailKey.currentState?.pop(false);
				}
			}
		}
		lastOnePane = onePane;
		if (onePane) {
			return masterNavigator;
		}
		else {
			return Row(
				children: [
					Flexible(
						flex: 1,
						child: PrimaryScrollController.none(
							child: masterNavigator
						)
					),
					VerticalDivider(
						width: 0,
						color: CupertinoTheme.of(context).primaryColor.withBrightness(0.2)
					),
					Flexible(
						flex: 3,
						child: detailNavigator
					)
				]
			);
		}
	}
}