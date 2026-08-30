import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

class SessionManager {
  static const String keyUserData = "user_data";
  static const String keyIsLoggedIn = "is_logged_in";
  static const String keyAppNotifications = "app_notifications_enabled";
  static const String keyLastAutoDownload = "last_auto_download_date";

  static Future<void> saveUser(Map<String, dynamic> userMap) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyUserData, jsonEncode(userMap));
    await prefs.setBool(keyIsLoggedIn, true);
  }

  static Future<UserData?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(keyUserData);
    if (userStr != null) {
      return UserData.fromJson(jsonDecode(userStr));
    }
    return null;
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyIsLoggedIn) ?? false;
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  static Future<void> setAppNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyAppNotifications, enabled);
  }

  static Future<bool> isAppNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyAppNotifications) ?? true;
  }

  static Future<void> setLastAutoDownloadDate(String date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyLastAutoDownload, date);
  }

  static Future<String?> getLastAutoDownloadDate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyLastAutoDownload);
  }
}
