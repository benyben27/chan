import 'package:chan/sites/lainchan_org.dart';
import 'package:flutter/foundation.dart';

class SiteSoyjak extends SiteLainchanOrg {
	SiteSoyjak({
		required super.baseUrl,
		required super.name,
		super.archives = const [],
		super.faviconPath = '/static/favicon.png',
		super.defaultUsername = 'Chud'
	});

	@override
	String? get imageThumbnailExtension => null;

	@override
	String get siteType => 'soyjak';

	@override
	bool operator ==(Object other) => (other is SiteSoyjak) && (other.baseUrl == baseUrl) && (other.name == name) && listEquals(other.archives, archives);

	@override
	int get hashCode => Object.hash(baseUrl, name, archives);

	@override
	String get res => 'thread';
}