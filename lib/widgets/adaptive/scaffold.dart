import 'package:chan/pages/master_detail.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/widgets/scroll_tracker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AdaptiveBar {
	final Widget? leading;
	final Widget? title;
	final List<Widget>? actions;
	final Color? backgroundColor;
	
	const AdaptiveBar({
		this.leading,
		this.title,
		this.actions,
		this.backgroundColor
	});
}

class _AppBarWithBackButtonPriority extends StatelessWidget implements PreferredSizeWidget {
	final AdaptiveBar bar;
	final VoidCallback? onDrawerButtonPressed;
	final bool autoHideOnScroll;

	const _AppBarWithBackButtonPriority({
		required this.bar,
		required this.autoHideOnScroll,
		this.onDrawerButtonPressed
	});

	@override
	Widget build(BuildContext context) {
		final Widget? leading;
		if (ModalRoute.of(context)?.canPop ?? false) {
			leading = const BackButton();
		}
		else if (onDrawerButtonPressed != null) {
			leading = DrawerButton(
				onPressed: onDrawerButtonPressed
			);
		}
		else {
			leading = bar.leading;
		}
		final child = AppBar(
			leading: leading,
			foregroundColor: ChanceTheme.primaryColorOf(context),
			//centerTitle: true,
			title: Container(
				height: 44,
				alignment: Alignment.centerLeft,
				child: bar.title
			),
			actions: bar.actions,
			backgroundColor: bar.backgroundColor
		);
		if (!autoHideOnScroll) {
			return child;
		}
		return AncestorScrollBuilder(
			builder: (context, direction) => AnimatedOpacity(
				opacity: direction == VerticalDirection.up ? 1.0 : 0.0,
				duration: const Duration(milliseconds: 350),
				curve: Curves.ease,
				child: IgnorePointer(
					ignoring: direction == VerticalDirection.down,
					child: child
				)
			)
		);
	}
	
	@override
	Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _CupertinoNavigationBar extends StatelessWidget implements ObstructingPreferredSizeWidget {
	final bool transitionBetweenRoutes;
	final Widget? leading;
	final Widget? middle;
	final Color? backgroundColor;
	final Widget? trailing;
	final bool autoHideOnScroll;

	const _CupertinoNavigationBar({
		required this.autoHideOnScroll,
		this.transitionBetweenRoutes = true,
		this.leading,
		this.middle,
		this.backgroundColor,
		this.trailing
	});

	@override
	bool shouldFullyObstruct(BuildContext context) {
		return !autoHideOnScroll;
	}

	@override
	Size get preferredSize => const Size.fromHeight(kMinInteractiveDimensionCupertino);

	@override
	Widget build(BuildContext context) {
		final child = CupertinoNavigationBar(
			transitionBetweenRoutes: transitionBetweenRoutes,
			leading: leading,
			middle: middle,
			backgroundColor: backgroundColor,
			trailing: trailing
		);
		if (!autoHideOnScroll) {
			return child;
		}
		return AncestorScrollBuilder(
			builder: (context, direction) => AnimatedOpacity(
				opacity: direction == VerticalDirection.up ? 1.0 : 0.0,
				duration: const Duration(milliseconds: 350),
				curve: Curves.ease,
				child: IgnorePointer(
					ignoring: direction == VerticalDirection.down,
					child: child
				)
			)
		);
	}
}

class _CupertinoDrawer {
	final GlobalKey<DrawerControllerState> key;
	const _CupertinoDrawer(this.key);

	@override
	bool operator == (Object other) => other is _CupertinoDrawer && other.key == key;
	@override
	int get hashCode => key.hashCode;
}

class AdaptiveScaffold extends StatelessWidget {
	final Color? backgroundColor;
	final Widget body;
	final AdaptiveBar? bar;
	final bool resizeToAvoidBottomInset;
	final Widget? drawer;
	final bool disableAutoBarHiding;

	const AdaptiveScaffold({
		required this.body,
		this.bar,
		this.backgroundColor,
		this.resizeToAvoidBottomInset = true,
		this.drawer,
		this.disableAutoBarHiding = false,
		super.key
	});

	@override
	Widget build(BuildContext context) {
		final bar_ = bar;
		final autoHideBars = !disableAutoBarHiding && context.select<EffectiveSettings, bool>((s) => s.hideBarsWhenScrollingDown);
		if (ChanceTheme.materialOf(context)) {
			VoidCallback? onDrawerButtonPressed;
			final parentScaffold = Scaffold.maybeOf(context);
			if (parentScaffold?.hasDrawer ?? false) {
				onDrawerButtonPressed = parentScaffold?.openDrawer;
			}
			if (context.read<MasterDetailHint?>()?.location.isDetail ?? false) {
				// Only show drawer on master
				onDrawerButtonPressed = null;
			}
			return Scaffold(
				drawer: drawer,
				extendBodyBehindAppBar: autoHideBars || (bar_?.backgroundColor?.opacity ?? 1) < 1,
				resizeToAvoidBottomInset: resizeToAvoidBottomInset,
				backgroundColor: backgroundColor,
				appBar: bar_ == null ? null : _AppBarWithBackButtonPriority(
					autoHideOnScroll: autoHideBars,
					bar: bar_,
					onDrawerButtonPressed: onDrawerButtonPressed
				),
				body: body,
			);
		}
		final parentDrawer = context.watch<_CupertinoDrawer?>();
		Widget? drawerButton;
		if (!(ModalRoute.of(context)?.canPop ?? false) && parentDrawer != null) {
			// Only if at root route
			drawerButton = CupertinoButton(
				onPressed: () => parentDrawer.key.currentState?.open(),
				minSize: 0,
				padding: EdgeInsets.zero,
				child: const Icon(Icons.menu)
			);
		}
		final child = CupertinoPageScaffold(
			resizeToAvoidBottomInset: resizeToAvoidBottomInset,
			backgroundColor: backgroundColor,
			navigationBar: bar_ == null ? null : _CupertinoNavigationBar(
				autoHideOnScroll: autoHideBars,
				transitionBetweenRoutes: false,
				leading: bar_.leading ?? drawerButton,
				middle: bar_.title,
				backgroundColor: bar_.backgroundColor,
				trailing: bar_.actions == null ? null : Row(
					mainAxisSize: MainAxisSize.min,
					children: bar_.actions!
				)
			),
			child: body
		);
		final drawer_ = drawer;
		if (drawer_ == null) {
			return child;
		}
		return Provider<_CupertinoDrawer>(
			create: (context) => _CupertinoDrawer(GlobalKey(debugLabel: 'AdaptiveScaffold._CupertinoDrawer')),
			builder: (context, _) => Stack(
				children: [
					child,
					DrawerController(
						key: context.watch<_CupertinoDrawer>().key,
						alignment: DrawerAlignment.start,
						child: Theme(
							data: context.watch<SavedTheme>().materialThemeData,
							child: drawer_
						)
					)
				]
			)
		);
	}
}