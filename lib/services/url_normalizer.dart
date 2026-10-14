import 'hosted_api.dart';

/// Normalizes a user-typed server URL per DESIGN §7.5.
///
/// Rules:
/// - The hosted service (`nolongerevil.com`) always maps to
///   `https://nolongerevil.com:443`.
/// - Missing scheme → default `http://`.
/// - Missing port → scheme-aware default: `:8082` for `http` (a direct-LAN
///   NLE server), `:443` for `https` (a reverse proxy / Cloudflare front that
///   terminates TLS on the standard port).
/// - Strip trailing slash.
/// - Reject malformed input (empty host, bad scheme, parse failure).
class UrlNormalizationException implements Exception {
  final String message;
  const UrlNormalizationException(this.message);
  @override
  String toString() => 'UrlNormalizationException: $message';
}

String normalizeServerUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const UrlNormalizationException('Server address is required.');
  }

  // The hosted NoLongerEvil service is only reachable over https on 443 —
  // don't let the self-hosted `http://…:8082` defaults apply to it.
  final hostOnly = trimmed
      .replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '')
      .split(RegExp(r'[/:]'))
      .first;
  if (isHostedHost(hostOnly)) return hostedBaseUrl;

  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';

  final Uri uri;
  try {
    uri = Uri.parse(withScheme);
  } on FormatException catch (e) {
    throw UrlNormalizationException('Invalid URL: ${e.message}');
  }

  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw UrlNormalizationException(
      'Scheme must be http or https (got "${uri.scheme}").',
    );
  }
  if (uri.host.isEmpty) {
    throw const UrlNormalizationException('Missing hostname.');
  }
  if (uri.path.isNotEmpty && uri.path != '/') {
    throw const UrlNormalizationException(
      'Path component is not supported; enter only host[:port].',
    );
  }

  // An https URL without an explicit port is fronted by a reverse proxy or
  // Cloudflare on the standard TLS port (443); only the direct-LAN http case
  // defaults to NLE's 8082. Forcing 8082 onto https URLs was the cause of
  // "Couldn't reach server" against Cloudflare-fronted deployments.
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 8082);
  return '${uri.scheme}://${uri.host}:$port';
}
