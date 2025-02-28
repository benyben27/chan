import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/widgets/cupertino_thin_button.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AdaptiveFilledButton extends StatelessWidget {
	final Widget child;
	final VoidCallback? onPressed;
	final EdgeInsets? padding;
	final BorderRadius? borderRadius;
	final double? minSize;
	final Alignment alignment;
	final Color? color;
	final Color? disabledColor;

	const AdaptiveFilledButton({
		required this.child,
		required this.onPressed,
		this.padding,
		this.borderRadius,
		this.minSize,
		this.alignment = Alignment.center,
		this.color,
		this.disabledColor,
		super.key
	});

	@override
	Widget build(BuildContext context) {
		if (ChanceTheme.materialOf(context)) {
			return FilledButton(
				onPressed: onPressed,
				style: ButtonStyle(
					padding: padding == null ? null : MaterialStatePropertyAll(padding),
					backgroundColor: (color == null && disabledColor == null) ? null : MaterialStateProperty.resolveWith((states) {
						if (states.contains(MaterialState.disabled)) {
							return disabledColor;
						}
						if (states.contains(MaterialState.pressed)) {
							return color?.towardsGrey(0.2);
						}
						if (states.contains(MaterialState.hovered)) {
							return color?.towardsGrey(0.4);
						}
						return color;
					}),
					alignment: alignment,
					minimumSize: MaterialStateProperty.all(minSize.asSquare),
					tapTargetSize: MaterialTapTargetSize.shrinkWrap,
					shape: MaterialStateProperty.all(RoundedRectangleBorder(
						borderRadius: borderRadius ?? const BorderRadius.all(Radius.circular(4.0))
					))
				),
				child: child
			);
		}
		return CupertinoButton(
			onPressed: onPressed,
			padding: padding,
			color: color ?? ChanceTheme.primaryColorOf(context),
			borderRadius: borderRadius ?? const BorderRadius.all(Radius.circular(8.0)),
			minSize: minSize,
			alignment: alignment,
			disabledColor: disabledColor ?? CupertinoColors.quaternarySystemFill,
			child: child
		);
	}
}

class AdaptiveThinButton extends StatelessWidget {
	final Widget child;
	final VoidCallback onPressed;
	final EdgeInsets padding;
	final bool filled;

	const AdaptiveThinButton({
		required this.child,
		required this.onPressed,
		this.padding = const EdgeInsets.all(16),
		this.filled = false,
		super.key
	});

	@override
	Widget build(BuildContext context) {
		if (ChanceTheme.materialOf(context)) {
			final theme = context.watch<SavedTheme>();
			return OutlinedButton(
				onPressed: onPressed,
				style: ButtonStyle(
					foregroundColor: filled ? MaterialStateProperty.all(theme.backgroundColor) : null,
					backgroundColor: filled ? MaterialStateProperty.resolveWith((s) {
						if (s.contains(MaterialState.pressed)) {
							return theme.primaryColorWithBrightness(0.6);
						}
						if (s.contains(MaterialState.hovered)) {
							return theme.primaryColorWithBrightness(0.8);
						}
						return theme.primaryColor;
					}) : null
				),
				child: child
			);
		}
		return CupertinoThinButton(
			onPressed: onPressed,
			padding: padding,
			filled: filled,
			child: child
		);
	}
}

extension _AsSquare on double? {
	Size? get asSquare {
		if (this == null) {
			return null;
		}
		return Size.square(this!);
	}
}

class AdaptiveIconButton extends StatelessWidget {
	final Widget icon;
	final VoidCallback? onPressed;
	final double minSize;
	final EdgeInsets padding;
	final bool dimWhenDisabled;

	const AdaptiveIconButton({
		required this.icon,
		required this.onPressed,
		this.minSize = 44,
		this.padding = EdgeInsets.zero,
		this.dimWhenDisabled = true,
		super.key
	});

	@override
	Widget build(BuildContext context) {
		if (ChanceTheme.materialOf(context)) {
			return IconButton(
				padding: padding,
				style: ButtonStyle(
					minimumSize: MaterialStateProperty.all(minSize.asSquare),
					tapTargetSize: MaterialTapTargetSize.shrinkWrap
				),
				onPressed: onPressed,
				icon: (dimWhenDisabled && onPressed == null) ? Opacity(opacity: 0.5, child: icon) : icon
			);
		}
		return CupertinoButton(
			onPressed: onPressed,
			padding: padding,
			minSize: minSize,
			child: (dimWhenDisabled || onPressed != null) ? icon : DefaultTextStyle.merge(
				style: TextStyle(color: ChanceTheme.primaryColorOf(context)),
				child: IconTheme.merge(
					data: IconThemeData(color: ChanceTheme.primaryColorOf(context)),
					child: icon
				)
			)
		);
	}
}

class AdaptiveButton extends StatelessWidget {
	final Widget child;
	final VoidCallback? onPressed;
	final EdgeInsets? padding;

	const AdaptiveButton({
		required this.child,
		required this.onPressed,
		this.padding,
		super.key
	});

	@override
	Widget build(BuildContext context) {
		if (ChanceTheme.materialOf(context)) {
			return TextButton(
				onPressed: onPressed,
				style: ButtonStyle(
					padding: MaterialStateProperty.all(padding),
					shape: MaterialStateProperty.all(RoundedRectangleBorder(
						borderRadius: BorderRadius.circular(4)
					))
				),
				child: child
			);
		}
		return CupertinoButton(
			onPressed: onPressed,
			padding: padding,
			child: child
		);
	}
}