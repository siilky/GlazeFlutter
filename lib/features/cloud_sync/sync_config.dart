import 'package:flutter_dotenv/flutter_dotenv.dart';

class SyncConfig {
  static String? _dropboxAppKey;
  static String? _dropboxRedirectNative;
  static String? _gdriveClientId;
  static String? _gdriveClientSecret;
  static String? _gdriveRedirectNative;

  static Future<void> load() async {
    if (!dotenv.isInitialized) {
      await dotenv.load(fileName: '.env');
    }
    _dropboxAppKey = dotenv.env['DROPBOX_APP_KEY'];
    _dropboxRedirectNative = dotenv.env['DROPBOX_REDIRECT_NATIVE'];
    _gdriveClientId = dotenv.env['GDRIVE_CLIENT_ID'];
    _gdriveClientSecret = dotenv.env['GDRIVE_CLIENT_SECRET'];
    _gdriveRedirectNative = dotenv.env['GDRIVE_REDIRECT_NATIVE'];
  }

  static String? get dropboxAppKey => _dropboxAppKey;
  static String? get dropboxRedirectNative =>
      _dropboxRedirectNative ?? 'com.hydall.glaze://oauth/dropbox';
  static String? get gdriveClientId => _gdriveClientId;
  static String? get gdriveClientSecret => _gdriveClientSecret;
  static String? get gdriveRedirectNative =>
      _gdriveRedirectNative ?? 'com.hydall.glaze://oauth/gdrive';

  static bool canStartSyncAuth(String provider) {
    switch (provider) {
      case 'dropbox':
        return _dropboxAppKey != null && _dropboxAppKey!.isNotEmpty;
      case 'gdrive':
        return _gdriveClientId != null && _gdriveClientId!.isNotEmpty;
      default:
        return false;
    }
  }

  static bool hasAnySyncProviderConfigured() =>
      canStartSyncAuth('dropbox') || canStartSyncAuth('gdrive');
}
