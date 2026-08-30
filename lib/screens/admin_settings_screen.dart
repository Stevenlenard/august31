import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/session_manager.dart';
import '../api/api_service.dart';
import '../api/api_client.dart';
import '../utils/custom_notification.dart';
import '../utils/system_logger.dart';
import '../services/admin_settings_service.dart';
import 'package:firebase_database/firebase_database.dart';

class AdminSettingsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const AdminSettingsScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  final ApiService _apiService = ApiService();
  final AdminSettingsService _adminSettingsService = AdminSettingsService();
  final FirebaseDatabase _database = FirebaseDatabase.instance;

  bool _emailNotifications = true;
  bool _appNotifications = true;
  bool _autoBackup = true;
  
  String _adminName = "Administrator";
  String _adminEmail = "Loading...";
  String _adminContact = "---";

  // Controllers for password change
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isPasswordLoading = false;
  bool _isCurrentPasswordVisible = false;
  bool _isNewPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;

  @override
  void initState() {
    super.initState();
    _adminSettingsService.startListening();
    _setupGlobalSettingsListeners();
    _loadSettings();
    _loadAdminProfile();
  }

  void _setupGlobalSettingsListeners() {
    _adminSettingsService.emailNotificationsEnabled.addListener(() {
      if (mounted) setState(() => _emailNotifications = _adminSettingsService.emailNotificationsEnabled.value);
    });
    _adminSettingsService.appNotificationsEnabled.addListener(() {
      if (mounted) {
        setState(() => _appNotifications = _adminSettingsService.appNotificationsEnabled.value);
        SessionManager.setAppNotificationsEnabled(_appNotifications);
      }
    });
  }

  Future<void> _loadAdminProfile() async {
    try {
      final user = await SessionManager.getUser();
      if (user != null && mounted) {
        setState(() {
          _adminName = user.name.isNotEmpty ? user.name : "System Admin";
          _adminEmail = user.email.isNotEmpty ? user.email : "No Email Provided";
          // If contact is not in session, you might need an API call to get full user details
          _adminContact = "Contact Lipa IT"; 
        });
      }
    } catch (e) {
      debugPrint("Error loading admin profile: $e");
    }
  }

  Future<void> _loadSettings() async {
    try {
      final user = await SessionManager.getUser();
      if (user != null) {
        final response = await _apiService.getUserSettings(user.userId, user.role);
        final resData = response.data;
        if (resData is Map && resData['success'] == true) {
          final data = resData['data'];
          if (mounted) {
            setState(() {
              _emailNotifications = data['email_notifications'] ?? true;
              _appNotifications = data['app_notifications'] ?? true;
              _autoBackup = data['auto_backup'] ?? true;
            });
            SessionManager.setAppNotificationsEnabled(_appNotifications);
          }
        }
      }
    } catch (e) {
      debugPrint("Error loading admin settings: $e");
    }
  }

  Future<void> _toggleSetting(String key, bool value) async {
    // 1. Update Global Firebase Sync for real-time admin sync
    if (key == 'email') {
      await _adminSettingsService.updateEmailNotifications(value);
    } else if (key == 'app') {
      await _adminSettingsService.updateAppNotifications(value);
    } else if (key == 'backup') {
      await _database.ref('admin_settings/auto_backup').set(value);
    }

    // Optimistic UI update
    setState(() {
      if (key == 'email') _emailNotifications = value;
      if (key == 'app') {
        _appNotifications = value;
        SessionManager.setAppNotificationsEnabled(value);
      }
      if (key == 'backup') _autoBackup = value;
    });

    try {
      final user = await SessionManager.getUser();
      if (user != null) {
        final response = await _apiService.updateUserSettings(
          userId: user.userId,
          role: user.role,
          emailNotifications: key == 'email' ? value : null,
          appNotifications: key == 'app' ? value : null,
          autoBackup: key == 'backup' ? value : null,
        );
        
        final data = response.data;
        if (data is Map && data['success'] == true) {
          // Success notification
          if (mounted) {
            final String status = value ? "Enabled" : "Disabled";
            final String settingName = key == 'email' ? "Email Notifications" : (key == 'app' ? "App Notifications" : "Auto Backup");
            CustomNotification.showTopNotification(context, "$settingName $status", false);
          }
        } else {
          // Revert on failure
          if (mounted) {
            setState(() {
              if (key == 'email') _emailNotifications = !value;
              if (key == 'app') _appNotifications = !value;
              if (key == 'backup') _autoBackup = !value;
            });
            String msg = (data is Map) ? (data['message'] ?? "Failed to update setting") : "Server error";
            CustomNotification.showTopNotification(context, msg);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (key == 'email') _emailNotifications = !value;
          if (key == 'app') _appNotifications = !value;
        });
        CustomNotification.showTopNotification(context, "Error updating setting: $e");
      }
    }
  }

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleUpdatePassword() async {
    final oldPass = _oldPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();
    final confirmPass = _confirmPasswordController.text.trim();

    if (oldPass.isEmpty || newPass.isEmpty || confirmPass.isEmpty) {
      CustomNotification.showTopNotification(context, "Please fill all password fields");
      return;
    }

    if (newPass != confirmPass) {
      CustomNotification.showTopNotification(context, "New passwords do not match");
      return;
    }

    if (newPass.length < 6) {
      CustomNotification.showTopNotification(context, "Password must be at least 6 characters");
      return;
    }

    setState(() => _isPasswordLoading = true);

    try {
      final user = await SessionManager.getUser();
      if (user == null) return;

      final response = await _apiService.changePassword(
        user.userId,
        user.role,
        oldPass,
        newPass,
      );

      final data = response.data;
      if (data is Map && data['success'] == true) {
        await SystemLogger.logEvent("UPDATE", "Updated administrator password");
        if (mounted) {
          Navigator.pop(context);
          CustomNotification.showTopNotification(context, "Password updated successfully", false);
          _oldPasswordController.clear();
          _newPasswordController.clear();
          _confirmPasswordController.clear();
        }
      } else {
        if (mounted) {
          String msg = (data is Map) ? (data['message'] ?? "Failed to update password") : "Server error";
          CustomNotification.showTopNotification(context, msg);
        }
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "An error occurred: $e");
      }
    } finally {
      if (mounted) {
        setState(() => _isPasswordLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 40),
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    _buildProfileSection(),
                    _buildNotificationSection(),
                    _buildDataManagementSection(),
                    _buildSecuritySection(),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: ElevatedButton.icon(
                        onPressed: () => _showLogoutDialog(context),
                        icon: const Icon(Icons.logout_rounded, color: Colors.white),
                        label: const Text("Sign Out from Admin Panel", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00BFA5),
                          minimumSize: const Size(double.infinity, 60),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          if (!widget.isEmbedded || widget.onBack != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFF1A1A1A)),
              onPressed: () {
                if (widget.onBack != null) {
                  widget.onBack!();
                } else {
                  Navigator.pop(context);
                }
              },
            ),
            const SizedBox(width: 8),
          ],
          const Expanded(
            child: Text("Admin Settings", style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileSection() {
    return _buildSectionCard(Icons.person_rounded, "Administrator Profile", [
      _buildProfileItem("Administrator", _adminName),
      _buildProfileItem("Email", _adminEmail),
      _buildProfileItem("Contact", _adminContact),
    ]);
  }

  Widget _buildNotificationSection() {
    return _buildSectionCard(Icons.notifications_rounded, "System Notifications", [
      _buildSwitchRow("Email Notifications", "Receive system alerts via email", _emailNotifications, (v) => _toggleSetting('email', v)),
      _buildSwitchRow("App Notifications", "System alerts and updates", _appNotifications, (v) => _toggleSetting('app', v)),
    ]);
  }

  Widget _buildDataManagementSection() {
    return _buildSectionCard(Icons.file_download_outlined, "Data Management", [
      _buildSwitchRow("Auto Backup", "Daily automatic backups", _autoBackup, (v) => _toggleSetting('backup', v)),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _handleManualBackup(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Backup Now", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E88E5))),
                  Text("Create manual backup", style: TextStyle(fontSize: 12, color: const Color(0xFF1E88E5).withAlpha(150), fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: () => _showBackupHistoryDialog(),
                child: const Text("View History", style: TextStyle(color: Color(0xFF1E88E5), fontWeight: FontWeight.w900, fontSize: 13)),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF1E88E5), size: 18),
            ],
          ),
        ],
      ),
      const SizedBox(height: 16),
      InkWell(
        onTap: () => _handleExportData(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Export Data", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF9C27B0))),
            Text("Download system data (PDF)", style: TextStyle(fontSize: 12, color: const Color(0xFF9C27B0).withAlpha(150), fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    ]);
  }

  Widget _buildSecuritySection() {
    return _buildSectionCard(Icons.lock_rounded, "Security", [
      _buildSecurityRow("Change Password", () => _showChangePasswordDialog(context)),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Divider(height: 1, color: Color(0xFFF5F5F5))),
      _buildSecurityRow("Two-Factor Authentication", () => _show2FADialog(context)),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Divider(height: 1, color: Color(0xFFF5F5F5))),
      _buildSecurityRow("Access Logs", () => _showAccessLogsDialog(context)),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Divider(height: 1, color: Color(0xFFF5F5F5))),
      _buildSecurityRow("User Permissions", () => _showPermissionsDialog(context)),
    ]);
  }

  // --- Backup Handlers ---

  Future<void> _handleManualBackup() async {
    CustomNotification.showTopNotification(context, "Initializing manual backup...", false);
    try {
      final response = await _apiService.triggerBackup();
      final data = response.data;
      
      if (data is Map && data['success'] == true) {
        final downloadUrl = data['url'];
        if (downloadUrl != null) {
          final uri = Uri.parse(downloadUrl);
          // Try direct launch - bypasses unreliable canLaunchUrl check
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (mounted) {
              CustomNotification.showTopNotification(context, "Backup created and download started!", false);
            }
          } catch (e) {
            if (mounted) {
              CustomNotification.showTopNotification(context, "Could not open download link automatically.");
            }
          }
        } else {
          if (mounted) {
            CustomNotification.showTopNotification(context, "Backup completed successfully!", false);
          }
        }
      } else {
        if (mounted) {
          String msg = (data is Map) ? (data['message'] ?? "Backup failed") : "Invalid server response";
          CustomNotification.showTopNotification(context, msg);
        }
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Error during backup: $e");
      }
    }
  }

  Future<void> _handleExportData() async {
    CustomNotification.showTopNotification(context, "Opening export link...", false);
    try {
      // Use the base URL from ApiClient instead of a hardcoded IP
      // Changed format to 'xls' to match backend PHP expectations
      final String exportUrl = "${ApiClient.baseUrl}export_report.php?format=xls";
      final uri = Uri.parse(exportUrl);
      
      // Try direct launch - bypasses unreliable canLaunchUrl check
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          CustomNotification.showTopNotification(context, "Exporting system data...", false);
        }
      } catch (e) {
        if (mounted) {
          CustomNotification.showTopNotification(context, "Failed to launch browser. Please check your internet.");
        }
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Error exporting data: $e");
      }
    }
  }

  void _showBackupHistoryDialog() {
    List<dynamic> history = [];
    bool isLoading = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isLoading) {
            _apiService.getBackupHistory().then((res) {
              final data = res.data;
              if (data is Map && data['success'] == true) {
                setDialogState(() {
                  history = data['backups'] ?? [];
                  isLoading = false;
                });
              } else {
                setDialogState(() => isLoading = false);
              }
            }).catchError((e) {
              setDialogState(() => isLoading = false);
            });
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.history_rounded, color: Color(0xFF1E88E5), size: 28),
                      SizedBox(width: 12),
                      Text("Backup History", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1E88E5))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text("View and manage your previous system backups.", style: TextStyle(color: Color(0xFF757575), fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 24),
                  isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : SizedBox(
                          height: 300,
                          child: history.isEmpty
                              ? const Center(child: Text("No backup history found"))
                              : ListView.separated(
                                  itemCount: history.length,
                                  separatorBuilder: (context, i) => const Divider(color: Color(0xFFF5F5F5)),
                                  itemBuilder: (context, i) {
                                    final item = history[i];
                                    return ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(10)),
                                        child: const Icon(Icons.storage_rounded, color: Color(0xFF1E88E5), size: 20),
                                      ),
                                      title: Text(item['filename'], style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                                      subtitle: Text(item['created_at'] ?? item['date'] ?? "", style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.download_rounded, color: Color(0xFF1E88E5), size: 20),
                                            onPressed: () async {
                                              final url = item['url'];
                                              if (url != null) {
                                                final uri = Uri.parse(url);
                                                if (await canLaunchUrl(uri)) {
                                                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                                                }
                                              }
                                            },
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                                            onPressed: () async {
                                              final res = await _apiService.deleteBackup(item['filename']);
                                              if (res.data['success']) {
                                                if (!mounted) return;
                                                setDialogState(() {
                                                  history.removeAt(i);
                                                });
                                                CustomNotification.showTopNotification(context, "Backup deleted", false);
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E88E5),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Text("CLOSE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock_outline_rounded, color: Color(0xFF2E7D32), size: 28),
                      const SizedBox(width: 12),
                      const Text("Change Password", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text("Ensure your account is using a long, random password to stay secure.", style: TextStyle(color: Color(0xFF757575), fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 32),
                  _dialogTextField(
                    "Current Password",
                    _oldPasswordController,
                    _isCurrentPasswordVisible,
                    () => setDialogState(() => _isCurrentPasswordVisible = !_isCurrentPasswordVisible),
                  ),
                  const SizedBox(height: 16),
                  _dialogTextField(
                    "New Password",
                    _newPasswordController,
                    _isNewPasswordVisible,
                    () => setDialogState(() => _isNewPasswordVisible = !_isNewPasswordVisible),
                  ),
                  const SizedBox(height: 16),
                  _dialogTextField(
                    "Confirm New Password",
                    _confirmPasswordController,
                    _isConfirmPasswordVisible,
                    () => setDialogState(() => _isConfirmPasswordVisible = !_isConfirmPasswordVisible),
                  ),
                  const SizedBox(height: 40),
                  ElevatedButton(
                    onPressed: _isPasswordLoading ? null : _handleUpdatePassword,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: _isPasswordLoading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text("Update Password", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isPasswordLoading ? null : () => Navigator.pop(context),
                    child: const Text("CANCEL", style: TextStyle(color: Color(0xFF757575), fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _show2FADialog(BuildContext context) {
    bool is2FAEnabled = false;
    bool isLoading = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isLoading) {
            SessionManager.getUser().then((user) {
              if (user != null) {
                _apiService.getAdminPermissions(user.userId).then((res) {
                  final data = res.data;
                  if (data is Map && data['success']) {
                    setDialogState(() {
                      is2FAEnabled = data['data']['two_factor_enabled'] == 1;
                      isLoading = false;
                    });
                  }
                });
              }
            });
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock_outline_rounded, color: Color(0xFF2E7D32), size: 28),
                      const SizedBox(width: 12),
                      const Text("Two-Factor Authentication", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text("Add an extra layer of security to your account.", style: TextStyle(color: Color(0xFF757575), fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 32),
                  isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(color: const Color(0xFFF1F8E9), borderRadius: BorderRadius.circular(20)),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text("Account Security", style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
                                    Text(is2FAEnabled ? "2FA is currently active" : "Enable extra verification", style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                                  ],
                                ),
                              ),
                              Switch(
                                value: is2FAEnabled,
                                onChanged: (v) async {
                                  final user = await SessionManager.getUser();
                                  if (user != null) {
                                    final res = await _apiService.toggle2FA(user.userId, v);
                                    final data = res.data;
                                    if (data is Map && data['success']) {
                                      final String status = v ? "enabled" : "disabled";
                                      await SystemLogger.logEvent("UPDATE", "${v ? 'Enabled' : 'Disabled'} Two-Factor Authentication");
                                      setDialogState(() => is2FAEnabled = v);
                                      CustomNotification.showTopNotification(context, data['message'], false);
                                    }
                                  }
                                },
                                activeColor: const Color(0xFF00BFA5),
                              ),
                            ],
                          ),
                        ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Text("CLOSE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAccessLogsDialog(BuildContext context) {
    List<dynamic> logs = [];
    bool isLoading = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isLoading) {
            _apiService.getAccessLogs().then((res) {
              final data = res.data;
              if (data is Map && data['success']) {
                setDialogState(() {
                  logs = data['logs'];
                  isLoading = false;
                });
              }
            });
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded, color: Color(0xFF2E7D32), size: 28),
                      const SizedBox(width: 12),
                      const Text("System Access Logs", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text("Recent security activity and login history", style: TextStyle(color: Color(0xFF757575), fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 32),
                  isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : SizedBox(
                          height: 300,
                          child: logs.isEmpty
                              ? const Center(child: Text("No logs available"))
                              : ListView.separated(
                                  itemCount: logs.length,
                                  separatorBuilder: (context, i) => const SizedBox(height: 16),
                                  itemBuilder: (context, i) {
                                    final log = logs[i];
                                    final bool isSuccess = log['action'].toString().contains("Successful");
                                    return _logItem(
                                      "${log['action']} from ${log['ip_address']}",
                                      log['timestamp'].toString(),
                                      isSuccess,
                                    );
                                  },
                                ),
                        ),
                  const SizedBox(height: 40),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Text("CLOSE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showPermissionsDialog(BuildContext context) {
    bool canManageDb = false;
    bool canViewAnalytics = false;
    bool isLoading = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isLoading) {
            SessionManager.getUser().then((user) {
              if (user != null) {
                _apiService.getAdminPermissions(user.userId).then((res) {
                  final data = res.data;
                  if (data is Map && data['success']) {
                    setDialogState(() {
                      canManageDb = data['data']['can_manage_db'] == 1;
                      canViewAnalytics = data['data']['can_view_analytics'] == 1;
                      isLoading = false;
                    });
                  }
                });
              }
            });
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person_outline_rounded, color: Color(0xFF2E7D32), size: 28),
                      const SizedBox(width: 12),
                      const Text("User Permissions", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text("Define what your administrator role can access.", style: TextStyle(color: Color(0xFF757575), fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 32),
                  isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : Column(
                          children: [
                            _permissionRow("Manage Database", "Full access to resident and truck data", canManageDb, (v) {
                              setDialogState(() => canManageDb = v!);
                            }),
                            const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Divider(height: 32, color: Color(0xFFF5F5F5))),
                            _permissionRow("View Analytics", "Read-only access to system reports", canViewAnalytics, (v) {
                              setDialogState(() => canViewAnalytics = v!);
                            }),
                          ],
                        ),
                  const SizedBox(height: 40),
                  ElevatedButton(
                    onPressed: isLoading
                        ? null
                        : () async {
                            final user = await SessionManager.getUser();
                            if (user != null) {
                              final res = await _apiService.updatePermissions(user.userId, canManageDb, canViewAnalytics);
                              final data = res.data;
                              if (data is Map && data['success']) {
                                await SystemLogger.logEvent("UPDATE", "Updated administrator permissions");
                                if (mounted) Navigator.pop(context);
                                CustomNotification.showTopNotification(context, data['message'], false);
                              }
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Text("Apply Changes", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(height: 12),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE", style: TextStyle(color: Color(0xFF757575), fontWeight: FontWeight.w900))),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- Helper Components ---

  Widget _buildSectionCard(IconData icon, String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 15, offset: const Offset(0, 8))]
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: const Color(0xFF1A1A1A)),
              const SizedBox(width: 12),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
            ],
          ),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }

  Widget _buildProfileItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFBDBDBD), fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
      ]),
    );
  }

  Widget _buildSwitchRow(String title, String subtitle, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFFBDBDBD), fontWeight: FontWeight.w600)),
        ])),
        Switch(value: value, onChanged: onChanged, activeColor: const Color(0xFF00BFA5)),
      ]),
    );
  }

  Widget _buildSecurityRow(String title, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15, color: Color(0xFF757575), fontWeight: FontWeight.w700))),
          const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFFD1D1D1)),
        ]),
      ),
    );
  }

  Widget _dialogTextField(String hint, TextEditingController controller, bool isVisible, VoidCallback onToggle) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(16)),
      child: TextField(
        controller: controller,
        obscureText: !isVisible,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF757575), fontWeight: FontWeight.w500),
          suffixIcon: IconButton(
            icon: Icon(isVisible ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: const Color(0xFF757575), size: 20),
            onPressed: onToggle,
          ),
        ),
      ),
    );
  }

  Widget _logItem(String msg, String time, bool isSuccess) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: isSuccess ? Colors.green : Colors.red, shape: BoxShape.circle)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(msg, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF1A1A1A))),
              Text(time, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _permissionRow(String title, String subtitle, bool value, Function(bool?) onChanged) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF757575), fontWeight: FontWeight.w500)),
            ],
          ),
        ),
        Checkbox(value: value, onChanged: onChanged, activeColor: const Color(0xFF2E7D32), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
      ],
    );
  }

  void _showLogoutDialog(BuildContext context) {
    // Already synced with Residents Dashboard in AdminDashboard refactor, re-implementing here for screen completeness
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(padding: const EdgeInsets.all(16), decoration: const BoxDecoration(color: Color(0xFFFFF0F2), shape: BoxShape.circle), child: const Icon(Icons.logout_rounded, color: Color(0xFFFF1744), size: 32)),
              const SizedBox(height: 24),
              const Text("Secure Sign Out?", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 16),
              const Text("Are you sure you want to end your current session? You'll need to re-authenticate to access your dashboard.", textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF757575), fontSize: 14, height: 1.5)),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () async {
                  await SystemLogger.logEvent("LOGOUT", "Admin session ended");
                  await SessionManager.logout();
                  if (!mounted) return;
                  Navigator.pushReplacementNamed(context, '/');
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5), minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), elevation: 0),
                child: const Text("Sign Out", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel", style: TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w900))),
            ],
          ),
        ),
      ),
    );
  }
}
