import 'dart:convert';
import 'package:http/http.dart' as http;

class VuplusApi {
  final String host; // e.g. http://192.168.1.100
  final String? username;
  final String? password;

  VuplusApi({required this.host, this.username, this.password});

  Uri _buildUri(String path, [Map<String, String>? params]) {
    final uri = Uri.parse('$host$path');
    if (params == null || params.isEmpty) return uri;
    return uri.replace(queryParameters: params);
  }

  Map<String, String> _authHeader() {
    if (username != null && password != null) {
      final basicAuth =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
      return {'Authorization': basicAuth};
    }
    return {};
  }

  Future<dynamic> get(String path, [Map<String, String>? params]) async {
    final uri = _buildUri(path, params);
    final response = await http.get(uri, headers: _authHeader());
    if (response.statusCode != 200) {
      throw Exception('VU+ GET $path failed: ${response.statusCode}');
    }
    return response.body;
  }

  Future<dynamic> post(String path, Map<String, String> body) async {
    final uri = _buildUri(path);
    final response = await http.post(uri, headers: _authHeader(), body: body);
    if (response.statusCode != 200) {
      throw Exception('VU+ POST $path failed: ${response.statusCode}');
    }
    return response.body;
  }

  // Fetch channel list (services or bouquets)
  Future<String> fetchChannels({String? serviceRef}) async {
    // serviceRef can be a bouquet ref (1:7:...) or null for root.
    final params = serviceRef != null ? {'sRef': serviceRef} : null;
    return await get('/web/getservices', params);
  }

  // Fetch EPG for a service
  Future<String> fetchEpg(String serviceRef) async {
    return await get('/web/epgservice', {'sRef': serviceRef});
  }

  // Fetch timers
  Future<String> fetchTimers() async {
    return await get('/web/timerlist');
  }

  // Add timer
  Future<String> addTimer(Map<String, String> params) async {
    return await get('/web/timeradd', params);
  }

  // Delete timer
  Future<String> deleteTimer(String begin, String serviceRef) async {
    return await get('/web/timerdelete', {'begin': begin, 'sRef': serviceRef});
  }

  // Fetch picon (returns image URL)
  String piconUrl(String serviceRef) {
    return '$host/web/getpicon?sRef=${Uri.encodeQueryComponent(serviceRef)}';
  }
}
