import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/app_theme.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../api/api_service.dart';
import '../utils/custom_notification.dart';
import '../utils/app_localizations.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';
import '../widgets/legal_agreement_dialog.dart';
import '../widgets/data_management_modal.dart';

class ResidentSettingsScreen extends StatefulWidget {
  final bool isEmbedded;
  final bool showDataManagementOnLoad;
  final VoidCallback? onBack;
  final VoidCallback? onProfileUpdate;
  const ResidentSettingsScreen({
    super.key, 
    this.isEmbedded = false, 
    this.showDataManagementOnLoad = false,
    this.onBack, 
    this.onProfileUpdate
  });

  @override
  State<ResidentSettingsScreen> createState() => _ResidentSettingsScreenState();
}

class _ResidentSettingsScreenState extends State<ResidentSettingsScreen> {
  final ApiService _apiService = ApiService();
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  UserData? _user;
  bool _pushNotifications = true;
  bool _isLoading = false;
  bool _isLoggingOut = false;
  StreamSubscription? _userSubscription;

  final List<String> _puroks = [
    "Purok 1", "Purok 2", "Purok 3", "Purok 4", "Dos Riles", "Sentro",
    "San Isidro", "Paraiso", "Riverside", "Kalaw Street",
    "Home Subdivision", "Tanco Road / Ayala Highway", "Brixton Area"
  ];

  @override
  void initState() {
    super.initState();
    AppLocalizations.currentLanguage.addListener(_onLanguageChanged);
    _loadUser();
    
    if (widget.showDataManagementOnLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showDataManagementModal();
      });
    }
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  void _loadUser() async {
    _user = await SessionManager.getUser();
    if (_user != null) {
      _loadSettings();
      _setupRealtimeListener();
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ResidentSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Trigger modal if showDataManagementOnLoad becomes true
    if (widget.showDataManagementOnLoad && !oldWidget.showDataManagementOnLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showDataManagementModal();
      });
    }
  }

  void _setupRealtimeListener() {
    _userSubscription?.cancel();
    if (_user != null) {
      _userSubscription = _database.ref('residents/${_user!.userId}').onValue.listen((event) {
        if (event.snapshot.exists) {
          final Map data = event.snapshot.value as Map;
          if (mounted) {
            setState(() {
              _user = _user!.copyWith(
                name: data['name']?.toString(),
                email: data['email']?.toString(),
                phone: data['phone']?.toString(),
                purok: data['purok']?.toString(),
                completeAddress: data['complete_address']?.toString(),
              );
            });
          }
        }
      });
    }
  }

  @override
  void dispose() {
    AppLocalizations.currentLanguage.removeListener(_onLanguageChanged);
    _userSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      if (_user != null) {
        final response = await _apiService.getUserSettings(_user!.userId, _user!.role);
        if (response.data['success'] == true) {
          final data = response.data['data'];
          if (mounted) {
            setState(() {
              _pushNotifications = data['app_notifications'] ?? true;
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Error loading settings: $e");
    }
  }

  Future<void> _updatePushNotification(bool value) async {
    setState(() => _pushNotifications = value);
    try {
      if (_user != null) {
        final response = await _apiService.updateUserSettings(
          userId: _user!.userId,
          role: _user!.role,
          appNotifications: value,
        );

        if (response.data['success'] == true) {
          if (mounted) {
            CustomNotification.showTopNotification(
              context, 
              value ? "Push notifications enabled successfully." : "Push notifications disabled successfully.", 
              false
            );
          }
        } else {
          if (mounted) {
            setState(() => _pushNotifications = !value);
            CustomNotification.showTopNotification(context, response.data['message'] ?? "Failed to update notification settings");
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _pushNotifications = !value);
        CustomNotification.showTopNotification(context, "Connection Error: Unable to sync settings.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F7),
      body: FadeSlideEntrance(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Column(
                        children: [
                          _buildSectionHeader("Profile Information"),
                          _buildProfilePictureSection(),
                          const SizedBox(height: 16),
                          _buildProfileCard(),

                          const SizedBox(height: 24),
                          _buildSectionHeader("Notifications"),
                          _buildNotificationCard(),

                          const SizedBox(height: 24),
                          _buildSectionHeader("Account & Privacy"),
                          _buildAccountCard(),

                          const SizedBox(height: 24),
                          _buildSectionHeader("Help & Support"),
                          _buildHelpCard(),

                          const SizedBox(height: 24),
                          _buildAppInfoCard(),

                          const SizedBox(height: 32),
                          _buildLogoutButton(),
                          const SizedBox(height: 16),
                          _buildDeleteAccountButton(),
                          const SizedBox(height: 120),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
      ),
      child: Row(
        children: [
          _buildCircularBackButton(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Settings", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)),
                Text("Manage your preferences", style: TextStyle(fontSize: 11, color: Color(0xFF757575), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.settings_suggest_rounded, color: AppColors.tealText, size: 24)
          ),
        ],
      ),
    );
  }

  Widget _buildCircularBackButton() {
    return GestureDetector(
      onTap: widget.onBack ?? () => Navigator.pop(context),
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A1A1A), size: 18),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(_getSectionIcon(title), size: 18, color: AppColors.tealText),
            const SizedBox(width: 10),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
          ],
        ),
      ),
    );
  }

  IconData _getSectionIcon(String title) {
    switch (title) {
      case "Profile Information": return Icons.person_rounded;
      case "Notifications": return Icons.notifications_rounded;
      case "Account & Privacy": return Icons.lock_rounded;
      case "Help & Support": return Icons.help_rounded;
      default: return Icons.settings;
    }
  }

  Widget _buildProfileCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppDecorations.cardDecoration(),
      child: Column(
        children: [
          _buildProfileRow("Full Name", _user?.name ?? "---"),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Email", _user?.email ?? "---"),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Contact Number", _user?.phone ?? "---"),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Purok", _user?.purok ?? "---"),
        ],
      ),
    );
  }

  Widget _buildProfilePictureSection() {
    final String displayName = _user?.name.isNotEmpty == true ? _user!.name : "User";
    final String? profileUrl = _user?.profilePicture;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppDecorations.cardDecoration(),
      child: Row(
        children: [
          GestureDetector(
            onTap: _viewProfilePictureLarge,
            child: Stack(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.tealText.withValues(alpha: 0.2), width: 3),
                    image: profileUrl != null && profileUrl.isNotEmpty
                        ? DecorationImage(image: NetworkImage(profileUrl), fit: BoxFit.cover)
                        : null,
                  ),
                  child: profileUrl == null || profileUrl.isEmpty
                      ? Center(
                          child: Text(
                            displayName.isNotEmpty ? displayName[0].toUpperCase() : "U",
                            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: AppColors.tealText),
                          ),
                        )
                      : null,
                ),
                if (_isLoading)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(color: Colors.black26, shape: BoxShape.circle),
                      child: const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Profile Picture", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))),
                const SizedBox(height: 4),
                Text(
                  profileUrl != null && profileUrl.isNotEmpty ? "Personalize your account" : "No photo uploaded",
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _buildCompactActionBtn(
                      label: "Upload",
                      icon: Icons.camera_alt_rounded,
                      onTap: _pickAndUploadImage,
                      color: AppColors.tealText,
                    ),
                    if (profileUrl != null && profileUrl.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      _buildCompactActionBtn(
                        label: "Delete",
                        icon: Icons.delete_outline_rounded,
                        onTap: _confirmDeletePicture,
                        color: Colors.redAccent,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactActionBtn({required String label, required IconData icon, required VoidCallback onTap, required Color color}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      ),
    );
  }

  void _viewProfilePictureLarge() {
    if (_user == null) return;
    
    final String displayName = _user!.name.isNotEmpty ? _user!.name : "User";
    final String profileUrl = (_user!.profilePicture != null && _user!.profilePicture!.isNotEmpty)
        ? _user!.profilePicture!
        : "https://ui-avatars.com/api/?name=${Uri.encodeComponent(displayName)}&background=00796B&color=fff&size=512";

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                color: Colors.transparent,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(color: Colors.black.withValues(alpha: 0.2)),
                ),
              ),
            ),
          ),
          Center(
            child: Material(
              color: Colors.transparent,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(32),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 40, spreadRadius: 10)
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(32),
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 4.0,
                        child: Image.network(
                          profileUrl,
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return Container(
                              height: 300, width: 300,
                              color: Colors.white10,
                              child: const Center(child: CircularProgressIndicator(color: Colors.white70)),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.person_rounded, size: 120, color: Colors.white24),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: -12,
                    right: 12,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, 2))
                          ],
                        ),
                        child: const Icon(Icons.close_rounded, color: Color(0xFF00695C), size: 24),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadImage() async {
    if (_user == null) return;

    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);

    if (image == null) return;

    // Robust Validation: Only PNG and JPEG/JPG (Case Insensitive)
    final String fileName = image.name.toLowerCase();
    bool isValid = fileName.endsWith('.png') || 
                   fileName.endsWith('.jpg') || 
                   fileName.endsWith('.jpeg');
    
    if (!isValid) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Only PNG and JPEG images are allowed.");
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Get image bytes for web compatibility
      final bytes = await image.readAsBytes();
      
      // Local Upload via PHP API
      final response = await _apiService.uploadProfilePicture(
        userId: _user!.userId,
        role: _user!.role,
        fileName: image.name,
        imageBytes: bytes.toList(),
      );

      if (response.data['success'] == true) {
        final String profileUrl = response.data['url'];

        // Update Realtime Database (Optional, for backward compatibility)
        await _database.ref('residents/${_user!.userId}').update({'profile_picture': profileUrl});
        
        // Update Session
        final updatedUser = {..._user!.toJson(), 'profile_picture': profileUrl};
        await SessionManager.saveUser(updatedUser);
        
        _loadUser();
        if (widget.onProfileUpdate != null) widget.onProfileUpdate!();
        
        if (mounted) {
          CustomNotification.showTopNotification(context, "Profile picture updated successfully!", false);
        }
      } else {
        throw Exception(response.data['message'] ?? "Upload failed");
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Failed to upload image: $e");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _confirmDeletePicture() async {
    final confirmed = await _showConfirmActionDialog(
      title: "Delete Photo?",
      message: "Are you sure you want to remove your profile picture? This will revert to your initials.",
      confirmText: "Delete Photo",
      isDestructive: true,
    );

    if (confirmed) {
      setState(() => _isLoading = true);
      try {
        await _database.ref('residents/${_user!.userId}').update({'profile_picture': null});
        
        await _apiService.updateProfile(
          userId: _user!.userId,
          role: _user!.role,
          name: _user!.name,
          phone: _user!.phone ?? "",
          profilePicture: "", // Clear in MySQL
        );

        final updatedUser = {..._user!.toJson()};
        updatedUser.remove('profile_picture');
        await SessionManager.saveUser(updatedUser);
        
        _loadUser();
        if (widget.onProfileUpdate != null) widget.onProfileUpdate!();
        
        if (mounted) {
          CustomNotification.showTopNotification(context, "Profile picture removed.", false);
        }
      } catch (e) {
        if (mounted) CustomNotification.showTopNotification(context, "Error deleting photo: $e");
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildProfileRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNotificationCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: AppDecorations.cardDecoration(),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Push Notifications", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))),
                Text("Receive app notifications", style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          Switch(
            value: _pushNotifications,
            onChanged: _updatePushNotification,
            activeColor: AppColors.tealText,
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard() {
    return Container(
      decoration: AppDecorations.cardDecoration(),
      child: Column(
        children: [
          _buildActionRow(Icons.password_rounded, "Change Password", _showChangePasswordModal),
          const Divider(height: 1, indent: 64),
          _buildActionRow(Icons.storage_rounded, "Data Management", _showDataManagementModal),
        ],
      ),
    );
  }

  Widget _buildHelpCard() {
    return Container(
      decoration: AppDecorations.cardDecoration(),
      child: Column(
        children: [
          _buildActionRow(Icons.language_rounded, "Language", _showLanguageModal),
          const Divider(height: 1, indent: 64),
          _buildActionRow(Icons.gavel_rounded, AppLocalizations.get('terms_conditions'), () => LegalAgreementDialog.show(context, isTerms: true)),
          const Divider(height: 1, indent: 64),
          _buildActionRow(Icons.privacy_tip_rounded, AppLocalizations.get('privacy_policy'), () => LegalAgreementDialog.show(context, isTerms: false)),
          const Divider(height: 1, indent: 64),
          _buildActionRow(Icons.quiz_rounded, "FAQs", _showFAQsModal),
          const Divider(height: 1, indent: 64),
          _buildActionRow(Icons.support_agent_rounded, "Contact Support", _showContactSupportModal),
          const Divider(height: 1, indent: 64),
          _buildActionRow(Icons.info_outline_rounded, "About", _showAboutModal),
        ],
      ),
    );
  }

  Widget _buildAppInfoCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: AppDecorations.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("App Information", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))),
          const SizedBox(height: 16),
          _buildInfoRow("Version", "1.0.0"),
          const SizedBox(height: 12),
          _buildInfoRow("Last Updated", "April 2026"),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF2C3E50))),
      ],
    );
  }

  Widget _buildActionRow(IconData icon, String title, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFF3F5F7), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: AppColors.tealText),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50)))),
            Icon(Icons.chevron_right_rounded, size: 18, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _buildLogoutButton() {
    return HoverActionButton(
      text: "Logout",
      loadingText: "Logging out...",
      isLoading: _isLoggingOut,
      onTap: () => _showLogoutDialog(context),
    );
  }

  Widget _buildDeleteAccountButton() {
    return HoverActionButton(
      text: "Delete Account",
      loadingText: "Deleting Account...",
      isLoading: _isLoading,
      isDestructive: true,
      onTap: () => _showDeleteAccountConfirmation(),
    );
  }

  // --- LOGIC & MODALS ---

  Future<bool> _showConfirmActionDialog({
    required String title,
    required String message,
    String confirmText = "Confirm",
    bool isDestructive = false,
  }) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDestructive) ...[
                const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 48),
                const SizedBox(height: 24),
              ],
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5),
              ),
              const SizedBox(height: 32),
              HoverActionButton(
                text: confirmText,
                isDestructive: isDestructive,
                onTap: () => Navigator.pop(context, true),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => Navigator.pop(context, false),
                child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    ) ?? false;
  }

  void _showLanguageModal() {
    _showStyledBottomSheet(
      title: AppLocalizations.get('select_language'),
      children: [
        _buildLanguageItem(context, 'English (UK)', AppLanguage.en),
        _buildLanguageItem(context, 'Filipino', AppLanguage.fil),
        _buildLanguageItem(context, 'Bisaya', AppLanguage.bis),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildLanguageItem(BuildContext context, String label, AppLanguage lang) {
    bool isSelected = AppLocalizations.currentLanguage.value == lang;
    return ListTile(
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.inputLabel)),
      leading: Icon(Icons.language_rounded, color: isSelected ? AppColors.tealText : Colors.grey),
      trailing: isSelected 
        ? Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(color: Color(0xFF00897B), shape: BoxShape.circle),
            child: const Icon(Icons.check, color: Colors.white, size: 14),
          )
        : null,
      onTap: () {
        AppLocalizations.setLanguage(lang);
        Navigator.pop(context);
      },
    );
  }

  void _showEditProfileModal() {
    final nameController = TextEditingController(text: _user?.name);
    final emailController = TextEditingController(text: _user?.email);
    final phoneController = TextEditingController(text: _user?.phone);
    final addressController = TextEditingController(text: _user?.completeAddress);
    String selectedPurok = _user?.purok ?? "Sentro";

    _showStyledBottomSheet(
      title: "Edit Profile",
      children: [
        _buildTextField("Full Name", nameController),
        const SizedBox(height: 16),
        _buildTextField("Email Address", emailController, keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 16),
        _buildTextField("Contact Number", phoneController, keyboardType: TextInputType.phone),
        const SizedBox(height: 16),
        _buildPurokDropdown(selectedPurok, (val) => selectedPurok = val!),
        const SizedBox(height: 16),
        _buildTextField("Complete Address", addressController, maxLines: 2),
        const SizedBox(height: 24),
        _buildSaveButton(() async {
          if (nameController.text.isEmpty || phoneController.text.isEmpty || emailController.text.isEmpty) {
             CustomNotification.showTopNotification(context, "Please fill required fields");
             return;
          }

          List<String> changedFields = [];
          if (nameController.text.trim() != (_user?.name ?? "")) changedFields.add("full name");
          if (emailController.text.trim() != (_user?.email ?? "")) changedFields.add("email");
          if (phoneController.text.trim() != (_user?.phone ?? "")) changedFields.add("contact number");
          if (selectedPurok != (_user?.purok ?? "")) changedFields.add("purok");
          if (addressController.text.trim() != (_user?.completeAddress ?? "")) changedFields.add("address");

          if (changedFields.isEmpty) {
            Navigator.pop(context);
            return;
          }

          setState(() => _isLoading = true);
          try {
            final response = await _apiService.updateProfile(
              userId: _user!.userId,
              role: _user!.role,
              name: nameController.text.trim(),
              email: emailController.text.trim(),
              phone: phoneController.text.trim(),
              address: addressController.text.trim(),
              purok: selectedPurok,
            );
            
            await _database.ref('residents/${_user!.userId}').update({
              'name': nameController.text.trim(),
              'email': emailController.text.trim(),
              'phone': phoneController.text.trim(),
              'purok': selectedPurok,
              'complete_address': addressController.text.trim(),
            });

            if (response.data['success'] == true) {
               final updatedUser = {..._user!.toJson(), 
                'name': nameController.text.trim(),
                'email': emailController.text.trim(),
                'phone': phoneController.text.trim(),
                'purok': selectedPurok,
                'complete_address': addressController.text.trim(),
               };
               await SessionManager.saveUser(updatedUser);
               _loadUser();
               if (widget.onProfileUpdate != null) widget.onProfileUpdate!();
               if (mounted) {
                 Navigator.pop(context);
                 String successMsg = "Successful save changes information";
                 if (changedFields.length == 1) {
                   successMsg = "Successful save ${changedFields[0]}";
                 }
                 CustomNotification.showTopNotification(context, successMsg, false);
               }
            }
          } catch (e) {
             CustomNotification.showTopNotification(context, "Error updating profile: $e");
          } finally {
             if (mounted) setState(() => _isLoading = false);
          }
        }),
      ],
    );
  }

  void _showChangePasswordModal() {
    final oldPass = TextEditingController();
    final newPass = TextEditingController();
    final confirmPass = TextEditingController();
    
    final FocusNode oldFocus = FocusNode();
    final FocusNode newFocus = FocusNode();
    final FocusNode confirmFocus = FocusNode();

    String? oldError;
    String? newError;
    String? confirmError;
    
    bool obscureOld = true;
    bool obscureNew = true;
    bool obscureConfirm = true;

    _showStyledBottomSheet(
      title: "Change Password",
      children: [
        StatefulBuilder(builder: (context, setModalState) {
          // Inner validation functions
          Future<void> validateOld() async {
            final val = oldPass.text;
            if (val.isEmpty) {
              setModalState(() => oldError = "Current password is required");
              return;
            }
            try {
              final res = await _apiService.login(_user!.email!, val);
              if (res.data['success'] != true) {
                setModalState(() => oldError = "Wrong password");
              } else {
                setModalState(() => oldError = null);
              }
            } catch (e) {
              setModalState(() => oldError = "Error verifying password");
            }
          }

          void validateNew() {
            final val = newPass.text;
            if (val.isEmpty) {
              setModalState(() => newError = AppLocalizations.get('err_pass_new'));
              return;
            }
            if (val.length < 6) {
              setModalState(() => newError = AppLocalizations.get('err_pass_len'));
              return;
            }
            bool hasUpper = val.contains(RegExp(r'[A-Z]'));
            bool hasLower = val.contains(RegExp(r'[a-z]'));
            bool hasDigit = val.contains(RegExp(r'[0-9]'));
            bool hasSpecial = val.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));

            if (!hasUpper || !hasLower || !hasDigit || !hasSpecial) {
              setModalState(() => newError = AppLocalizations.get('err_pass_complex'));
            } else {
              setModalState(() => newError = null);
            }
          }

          void validateConfirm() {
            if (confirmPass.text != newPass.text) {
              setModalState(() => confirmError = AppLocalizations.get('err_pass_match'));
            } else {
              setModalState(() => confirmError = null);
            }
          }

          // Attach listeners only once
          if (!oldFocus.hasListeners) {
            oldFocus.addListener(() { if (!oldFocus.hasFocus) validateOld(); setModalState((){}); });
            newFocus.addListener(() { if (!newFocus.hasFocus) validateNew(); setModalState((){}); });
            confirmFocus.addListener(() { if (!confirmFocus.hasFocus) validateConfirm(); setModalState((){}); });
          }

          return Column(
            children: [
              _buildValidatedField(
                label: "Current Password",
                controller: oldPass, 
                focusNode: oldFocus, 
                error: oldError, 
                obscureText: obscureOld,
                onToggle: () => setModalState(() => obscureOld = !obscureOld)
              ),
              const SizedBox(height: 16),
              _buildValidatedField(
                label: "New Password",
                controller: newPass, 
                focusNode: newFocus, 
                error: newError, 
                obscureText: obscureNew,
                onToggle: () => setModalState(() => obscureNew = !obscureNew)
              ),
              const SizedBox(height: 16),
              _buildValidatedField(
                label: "Confirm New Password",
                controller: confirmPass, 
                focusNode: confirmFocus, 
                error: confirmError, 
                obscureText: obscureConfirm,
                onToggle: () => setModalState(() => obscureConfirm = !obscureConfirm)
              ),
              const SizedBox(height: 32),
              HoverActionButton(
                text: "Save Changes",
                loadingText: "Saving Changes...",
                isLoading: _isLoading,
                onTap: () async {
                  await validateOld();
                  validateNew();
                  validateConfirm();

                  if (oldError != null || newError != null || confirmError != null) return;

                  bool confirm = await _showConfirmActionDialog(
                    title: "Change Password?",
                    message: "Are you sure you want to update your password? You will need to use your new password the next time you log in.",
                    confirmText: "Change Password"
                  );
                  if (!confirm) return;

                  setModalState(() => _isLoading = true);
                  setState(() => _isLoading = true);
                  
                  try {
                    final res = await _apiService.changePassword(_user!.userId, _user!.role, oldPass.text, newPass.text);
                    if (res.data['success'] == true) {
                      if (mounted) {
                        Navigator.pop(context);
                        CustomNotification.showTopNotification(context, "Successful change password", false);
                      }
                    } else {
                      setModalState(() => oldError = res.data['message'] ?? "Password update failed.");
                      CustomNotification.showTopNotification(context, res.data['message'] ?? "Password update failed.");
                    }
                  } catch (e) {
                    CustomNotification.showTopNotification(context, "Error: $e");
                  } finally {
                    setModalState(() => _isLoading = false);
                    if (mounted) setState(() => _isLoading = false);
                  }
                },
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildValidatedField({
    required String label, 
    required TextEditingController controller, 
    required FocusNode focusNode, 
    String? error, 
    Color? errorColor,
    required bool obscureText, 
    required VoidCallback onToggle
  }) {
    bool hasFocus = focusNode.hasFocus;
    bool isPassword = label.toLowerCase().contains("password");
    bool isError = error != null && (errorColor == null || errorColor == Colors.redAccent);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              if (hasFocus)
                BoxShadow(color: (isError ? Colors.redAccent : AppColors.tealText).withAlpha(30), blurRadius: 12, spreadRadius: 2)
            ],
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscureText,
            cursorColor: const Color(0xFF424242),
            style: const TextStyle(fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              filled: true,
              fillColor: hasFocus ? Colors.white : const Color(0xFFF3F5F7),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isError ? Colors.redAccent : Colors.grey.shade200, width: 1.2)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isError ? Colors.redAccent : AppColors.tealText, width: 2.0)),
              suffixIcon: isPassword ? IconButton(icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: hasFocus ? (isError ? Colors.redAccent : AppColors.tealText) : Colors.grey.shade500, size: 20), onPressed: onToggle) : null,
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(error, style: TextStyle(color: errorColor ?? Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  void _showDataManagementModal() {
    if (_user == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DataManagementModal(
        user: _user!, 
        onSuccess: _loadUser
      ),
    );
  }

  void _showPurokModal(String current, ValueChanged<String?> onSelected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.get('select_purok'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.tealText)),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _puroks.length,
                  itemBuilder: (context, index) {
                    final p = _puroks[index];
                    bool isSelected = current == p;
                    return ListTile(
                      title: Text(p, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.inputLabel)),
                      leading: Icon(Icons.location_on_outlined, color: isSelected ? AppColors.tealText : Colors.grey),
                      trailing: isSelected 
                        ? Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(color: Color(0xFF00897B), shape: BoxShape.circle),
                            child: const Icon(Icons.check, color: Colors.white, size: 14),
                          )
                        : null,
                      onTap: () {
                        onSelected(p);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPurokDropdownWithValidation(String selected, ValueChanged<String?> onChanged, String? error, Color? errorColor) {
    bool isError = error != null && (errorColor == null || errorColor == Colors.redAccent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Purok / Area", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => _showPurokModal(selected, onChanged),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F5F7), 
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isError ? Colors.redAccent : Colors.transparent, width: 1.2),
            ),
            child: Row(
              children: [
                Icon(Icons.location_on_outlined, color: isError ? Colors.redAccent : const Color(0xB400796B), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    selected,
                    style: const TextStyle(color: AppColors.inputLabel, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(Icons.keyboard_arrow_down_rounded, color: isError ? Colors.redAccent : AppColors.tealText, size: 24),
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(error, style: TextStyle(color: errorColor ?? Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  void _showMyDataDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text("My Data Summary", style: TextStyle(fontWeight: FontWeight.w900)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDataText("Name", _user?.name),
              _buildDataText("Email", _user?.email),
              _buildDataText("Purok", _user?.purok),
              _buildDataText("Created At", _user?.createdAt),
              _buildDataText("Account Status", _user?.isArchived == 0 ? "Active" : "Archived"),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE")),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _showEditProfileModal();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.tealText, foregroundColor: Colors.white),
            child: const Text("EDIT INFO"),
          ),
        ],
      ),
    );
  }

  Widget _buildDataText(String label, String? val) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
          Text(val ?? "N/A", style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  void _showDeleteAccountConfirmation() {
    _showConfirmActionDialog(
      title: "Delete Account?",
      message: "This action cannot be undone. All your data including complaints and history will be permanently erased.",
      confirmText: "Delete Permanently",
      isDestructive: true
    ).then((confirmed) async {
      if (confirmed) {
        setState(() => _isLoading = true);
        try {
          final res = await _apiService.deleteUser(_user!.userId, _user!.role);
          if (res.data['success'] == true) {
             // 1. Delete from Firebase
             await _database.ref('residents/${_user!.userId}').remove();
             
             // 2. Clear Session and Logout
             await SessionManager.logout();
             if (mounted) {
               CustomNotification.showTopNotification(context, "Account deleted permanently.", false);
               Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
             }
          } else {
             if (mounted) CustomNotification.showTopNotification(context, res.data['message'] ?? "Delete failed");
          }
        } catch (e) {
          if (mounted) CustomNotification.showTopNotification(context, "Delete failed: $e");
        } finally {
          if (mounted) setState(() => _isLoading = false);
        }
      }
    });
  }

  void _showFAQsModal() {
    _showStyledBottomSheet(
      title: "FAQs",
      children: [
        _buildFAQItem("How do I track a garbage truck?", "Navigate to the 'Track' tab to see real-time locations and live route status in your registered Purok."),
        _buildFAQItem("How is the ETA calculated?", "The ETA is based on the truck's current GPS position, average speed, and road distance to your purok."),
        _buildFAQItem("Why is the truck not visible?", "A truck may be finishing its route, idle, or experiencing temporary GPS signal loss in high-density areas."),
        _buildFAQItem("How do I file a complaint?", "Go to the 'Complaints' tab and tap 'File a Complaint'. You can track our admin's response in real-time."),
      ],
    );
  }

  void _showContactSupportModal() {
    _showStyledBottomSheet(
      title: "Contact Support",
      children: [
        const Text(
          "Reach out to us if you need help or have any inquiries.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 32),
        _buildContactDetailRow(Icons.phone_rounded, "+63 912 345 6789"),
        const SizedBox(height: 16),
        _buildContactDetailRow(Icons.email_rounded, "support@garbagetracker.com"),
        const SizedBox(height: 16),
        _buildContactDetailRow(Icons.map_rounded, "Barangay Hall, Purok 2, City Center"),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildContactDetailRow(IconData icon, String value) {
    return Row(
      children: [
        Icon(icon, size: 22, color: Colors.black87),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  void _showAboutModal() {
    _showStyledBottomSheet(
      title: "About",
      children: [
        const Center(child: Icon(Icons.local_shipping_rounded, size: 64, color: AppColors.tealText)),
        const SizedBox(height: 24),
        const Text(
          "Balintawak Waste Tracker is a comprehensive garbage truck tracking and management system designed to improve waste collection efficiency in our community.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF424242), fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 16),
        const Text(
          "Our mission is to provide residents with real-time updates and an easy way to communicate with waste management services, ensuring a cleaner and greener environment for everyone.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF424242), fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 32),
        const Text("Version 1.0.0", style: TextStyle(color: Colors.grey, fontSize: 12)),
        const Text("© 2026 Balintawak Waste Tracker Project Team", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 24),
      ],
    );
  }

  // --- REUSABLE UI HELPERS ---

  void _showStyledBottomSheet({required String title, required List<Widget> children}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: EdgeInsets.fromLTRB(0, 12, 0, MediaQuery.of(context).viewInsets.bottom),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10))),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Divider(height: 32),
            ),
            Flexible(
              child: Scrollbar(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, {bool isPassword = false, bool obscureText = false, VoidCallback? onToggle, TextInputType? keyboardType, int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          maxLines: maxLines,
          cursorColor: const Color(0xFF424242),
          style: const TextStyle(fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF3F5F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            suffixIcon: isPassword ? IconButton(icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility), onPressed: onToggle) : null,
          ),
        ),
      ],
    );
  }

  Widget _buildPurokDropdown(String selected, ValueChanged<String?> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Purok / Area", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: selected,
          items: _puroks.map((p) => DropdownMenuItem(value: p, child: Text(p, style: const TextStyle(fontWeight: FontWeight.w700)))).toList(),
          onChanged: onChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF3F5F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(VoidCallback onTap) {
    return HoverActionButton(
      text: "Save Changes",
      loadingText: "Saving changes...",
      isLoading: _isLoading,
      onTap: onTap,
    );
  }

  Widget _buildModalActionRow(IconData icon, String title, VoidCallback onTap, {bool isDestructive = false}) {
    return ListTile(
      leading: Icon(icon, color: isDestructive ? Colors.red : AppColors.tealText),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: isDestructive ? Colors.red : Colors.black87)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }

  Widget _buildFAQItem(String q, String a) {
    return ExpansionTile(
      title: Text(q, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      children: [Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Text(a, style: TextStyle(color: Colors.grey.shade700, height: 1.5)))],
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.logout_rounded, color: AppColors.tealText, size: 48),
              const SizedBox(height: 24),
              const Text("Sign Out?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 16),
              const Text(
                "Are you sure you want to end your session? You will need to login again to access your dashboard.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5),
              ),
              const SizedBox(height: 32),
              HoverActionButton(
                text: "Sign Out",
                loadingText: "Logging out...",
                isLoading: _isLoggingOut,
                onTap: () async {
                  setState(() => _isLoggingOut = true);
                  await SessionManager.logout();
                  if (!mounted) return;

                  // Show Logout Message
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text("Logged out successfully.", style: TextStyle(fontWeight: FontWeight.bold)),
                      backgroundColor: const Color(0xFF00897B),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                      margin: const EdgeInsets.all(20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );

                  Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
                },
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
