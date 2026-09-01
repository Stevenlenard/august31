import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import '../utils/app_theme.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../api/api_service.dart';
import '../utils/custom_notification.dart';
import '../utils/app_localizations.dart';
import '../widgets/legal_agreement_dialog.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';

class DriverSettingsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  final String? currentSessionId;

  const DriverSettingsScreen({
    super.key, 
    this.isEmbedded = false, 
    this.onBack,
    this.currentSessionId,
  });

  @override
  State<DriverSettingsScreen> createState() => _DriverSettingsScreenState();
}

class _DriverSettingsScreenState extends State<DriverSettingsScreen> {
  final ApiService _apiService = ApiService();
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  UserData? _user;
  
  bool _isNavigating = false;

  // Settings values
  bool _dutyAlerts = true;
  bool _collectionNotifications = true;
  bool _maintenanceNotifications = true;
  bool _emergencyAlerts = true;
  
  // Device/App info
  String _gpsAccuracy = "Checking...";
  final String _appVersion = "1.0.0";
  String? _truckPlateNumber;

  // Controllers for edit profile
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _addressController = TextEditingController();

  // Controllers for password change
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadUser();
    _loadSettings();
    _startGpsMonitor();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _loadUser() async {
    _user = await SessionManager.getUser();
    if (_user != null) {
      _nameController.text = _user!.name;
      _phoneController.text = _user!.phone ?? "";
      _emailController.text = _user!.email;
      _addressController.text = _user!.completeAddress ?? "";
      _loadTruckDetails();
    }
    if (mounted) setState(() {});
  }

  void _loadTruckDetails() async {
    if (_user?.preferredTruck == null) return;
    final snapshot = await _database.ref('trucks/${_user!.preferredTruck}').get();
    if (snapshot.exists) {
      final data = snapshot.value as Map;
      if (mounted) setState(() => _truckPlateNumber = data['plateNumber']?.toString());
    }
  }

  void _loadSettings() async {
    if (_user == null) return;
    
    final ref = _database.ref('driver_settings/${_user!.userId}');
    final snapshot = await ref.get();
    if (snapshot.exists) {
      final data = snapshot.value as Map;
      setState(() {
        _dutyAlerts = data['dutyAlerts'] ?? true;
        _collectionNotifications = data['collectionNotifications'] ?? true;
        _maintenanceNotifications = data['maintenanceNotifications'] ?? true;
        _emergencyAlerts = data['emergencyAlerts'] ?? true;
      });
    } else {
      // Initialize with default values
      await ref.set({
        'dutyAlerts': true,
        'collectionNotifications': true,
        'maintenanceNotifications': true,
        'emergencyAlerts': true,
        'lastUpdated': ServerValue.timestamp,
      });
    }
  }

  void _startGpsMonitor() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high
      );
      if (mounted) {
        setState(() {
          _gpsAccuracy = "±${position.accuracy.toStringAsFixed(1)} meters";
        });
      }
    } catch (e) {
      if (mounted) setState(() => _gpsAccuracy = "GPS Disabled");
    }
  }

  Future<void> _updateSettings(String key, bool value) async {
    if (_user == null) return;
    
    String label = "";
    if (key == 'dutyAlerts') {
      label = "Duty Alerts";
    } else if (key == 'collectionNotifications') {
      label = "Collection Notifications";
    } else if (key == 'maintenanceNotifications') {
      label = "Maintenance Notifications";
    } else if (key == 'emergencyAlerts') {
      label = "Emergency Alerts";
    }

    try {
      await _database.ref('driver_settings/${_user!.userId}').update({
        key: value,
        'lastUpdated': ServerValue.timestamp,
      });

      if (mounted) {
        setState(() {
          if (key == 'dutyAlerts') _dutyAlerts = value;
          else if (key == 'collectionNotifications') _collectionNotifications = value;
          else if (key == 'maintenanceNotifications') _maintenanceNotifications = value;
          else if (key == 'emergencyAlerts') _emergencyAlerts = value;
        });
        CustomNotification.showTopNotification(context, "$label ${value ? 'enabled' : 'disabled'} successfully.", false);
      }
    } catch (e) {
      if (mounted) {
        CustomNotification.showTopNotification(context, "Failed to update $label. Try again.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: FadeSlideEntrance(
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _buildSectionHeader(Icons.person_rounded, "Profile Information"),
                      _buildProfileCard(),
                      const SizedBox(height: 24),

                      _buildSectionHeader(Icons.route_rounded, "Route Management"),
                      _buildRouteManagement(),
                      const SizedBox(height: 24),

                      _buildSectionHeader(Icons.local_shipping_rounded, "Truck Information"),
                      _buildTruckInformation(),
                      const SizedBox(height: 24),

                      _buildSectionHeader(Icons.notifications_rounded, "Notifications"),
                      _buildNotificationsSection(),
                      const SizedBox(height: 24),

                      _buildSectionHeader(Icons.security_rounded, "Security & Data"),
                      _buildSecurityDataSection(),
                      const SizedBox(height: 24),

                      _buildSectionHeader(Icons.help_outline_rounded, "Support & Legal"),
                      _buildSupportLegalSection(),
                      const SizedBox(height: 24),

                      _buildSectionHeader(Icons.info_outline_rounded, "App Information"),
                      _buildAppInformation(),
                      const SizedBox(height: 32),
                      
                      _buildLogoutButton(),
                      const SizedBox(height: 16),
                      _buildDeleteAccountButton(),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ],
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
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Settings", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)),
                Text("Manage your preferences", style: TextStyle(fontSize: 11, color: Color(0xFF757575), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.settings_suggest_rounded, color: AppColors.tealText, size: 24),
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

  Widget _buildSectionHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.tealText),
          const SizedBox(width: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1A1A1A),
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildProfileRow("Full Name", _user?.name ?? "Loading..."),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Email Address", _user?.email ?? "Not set"),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Contact Number", _user?.phone ?? "Not set"),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Assigned Truck", _user?.preferredTruck ?? "None"),
          const Divider(height: 32, thickness: 0.5),
          _buildProfileRow("Plate Number", _truckPlateNumber ?? "N/A"),
        ],
      ),
    );
  }

  Widget _buildProfileRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF2C3E50)),
        ),
      ],
    );
  }

  Widget _buildRouteManagement() {
    return _buildSectionCard(
      children: [
        _buildMenuAction(Icons.route_rounded, "View Daily Routes", () => _showDailyRoutes()),
        _buildDivider(),
        _buildMenuAction(Icons.analytics_rounded, "Performance Stats", () => _showPerformanceStats()),
      ],
    );
  }

  Widget _buildTruckInformation() {
    return _buildSectionCard(
      children: [
        _buildMenuAction(Icons.local_shipping_rounded, "Truck Details", () => _showTruckDetails()),
        _buildDivider(),
        _buildMenuAction(Icons.engineering_rounded, "Maintenance Schedule", () => _showMaintenanceSchedule()),
        _buildDivider(),
        _buildMenuAction(Icons.report_problem_rounded, "Report Issue", () => _showReportIssue()),
        _buildDivider(),
        _buildMenuAction(Icons.history_rounded, "Issue History", () => _showIssueHistory()),
      ],
    );
  }

  Widget _buildNotificationsSection() {
    return _buildSectionCard(
      children: [
        _buildMenuAction(Icons.notification_important_rounded, "Notification Preferences", () => _showNotificationPreferences()),
        _buildDivider(),
        _buildMenuAction(Icons.history_rounded, "Alert History", () => _showAlertHistory()),
      ],
    );
  }

  Widget _buildSecurityDataSection() {
    return _buildSectionCard(
      children: [
        _buildMenuAction(Icons.password_rounded, "Change Password", () => _showChangePasswordModal()),
        _buildDivider(),
        _buildMenuAction(Icons.data_usage_rounded, "Data Management", () => _showDataManagementModal()),
      ],
    );
  }

  Widget _buildSupportLegalSection() {
    return _buildSectionCard(
      children: [
        _buildMenuAction(Icons.language_rounded, "Language", () => _showLanguageModal()),
        _buildDivider(),
        _buildMenuAction(Icons.gavel_rounded, "Terms & Conditions", () => LegalAgreementDialog.show(context, isTerms: true)),
        _buildDivider(),
        _buildMenuAction(Icons.privacy_tip_rounded, "Privacy Policy", () => LegalAgreementDialog.show(context, isTerms: false)),
        _buildDivider(),
        _buildMenuAction(Icons.quiz_rounded, "FAQs", () => _showFAQsModal()),
        _buildDivider(),
        _buildMenuAction(Icons.contact_support_rounded, "Contact Support", () => _showContactSupportModal()),
        _buildDivider(),
        _buildMenuAction(Icons.info_rounded, "About Us", () => _showAboutUsModal()),
      ],
    );
  }

  Widget _buildAppInformation() {
    return _buildSectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      children: [
        _buildInfoRow("Version", _appVersion),
        const SizedBox(height: 16),
        _buildInfoRow("GPS Accuracy", _gpsAccuracy, valueColor: AppColors.statusGreen),
        const SizedBox(height: 16),
        _buildInfoRow("Last Updated", "April 2026"),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 15)),
        Text(value, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: valueColor ?? const Color(0xFF2C3E50))),
      ],
    );
  }

  Widget _buildSectionCard({
    required List<Widget> children,
    EdgeInsets? padding
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow,
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.fromLTRB(0, 8, 0, 8),
        child: Column(children: children),
      ),
    );
  }

  Widget _buildMenuAction(IconData icon, String title, VoidCallback onTap, {bool showIcon = true, EdgeInsets? padding, Color? textColor}) {
    return InkWell(
      onTap: () {
        if (_isNavigating) return;
        onTap();
      },
      child: Padding(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (textColor ?? AppColors.tealText).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: textColor ?? AppColors.tealText),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title, 
                style: TextStyle(
                  fontSize: 16, 
                  fontWeight: FontWeight.w600, 
                  color: textColor ?? const Color(0xFF2C3E50)
                )
              ),
            ),
            if (showIcon) Icon(Icons.chevron_right_rounded, size: 20, color: Colors.grey.shade300),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(height: 1, color: Colors.grey.shade300, indent: 24, endIndent: 24); // Darker grey
  }

  Widget _buildLogoutButton() {
    return HoverActionButton(
      text: "Logout",
      loadingText: "Logging out...",
      isLoading: _isNavigating,
      onTap: () => _showLogoutDialog(context),
    );
  }

  Widget _buildDeleteAccountButton() {
    return HoverActionButton(
      text: "Delete Account",
      loadingText: "Deleting Account...",
      isLoading: _isNavigating,
      isDestructive: true,
      onTap: () => _showDeleteAccountConfirmation(),
    );
  }

  // --- TRUCK INFORMATION METHODS ---

  void _showTruckDetails() async {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      final truckId = _user?.preferredTruck ?? "GT-001";
      final ref = _database.ref('trucks/$truckId');
      final snapshot = await ref.get();
      
      Map<String, dynamic> truckData = {};
      if (snapshot.exists) {
        truckData = Map<String, dynamic>.from(snapshot.value as Map);
      }

      final idCtrl = TextEditingController(text: truckId);
      final plateCtrl = TextEditingController(text: truckData['plateNumber'] ?? "");

      if (!context.mounted) return;

      _showModal("Truck Details", [
        _buildTextField("Truck ID", idCtrl),
        _buildTextField("Plate Number", plateCtrl),
      ], "SAVE CHANGES", () async {
        if (plateCtrl.text.isEmpty) {
          CustomNotification.showTopNotification(context, "Please fill required fields");
          return false;
        }

        await ref.update({
          'plateNumber': plateCtrl.text.trim(),
          'lastUpdatedBy': _user?.userId,
          'updatedAt': ServerValue.timestamp,
        });
        
        if (mounted) {
          _loadUser(); // Refresh to update plate number in profile card if needed
          CustomNotification.showTopNotification(context, "Truck details updated successfully.", false);
        }
        return true;
      });
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  Future<void> _initializeMaintenanceIfNeeded(String truckId) async {
    final ref = _database.ref('trucks/$truckId');
    final snapshot = await ref.get();
    
    bool needsInit = true;
    if (snapshot.exists) {
      final data = snapshot.value as Map;
      if (data.containsKey('maintenance')) {
        needsInit = false;
      }
    }

    if (needsInit) {
      await ref.update({
        'odometerKm': 0.0,
        'maintenance': {
          'oilChange': {
            'intervalKm': 5000.0,
            'remainingKm': 5000.0,
            'lastServiceAt': null,
            'status': "NORMAL"
          },
          'tireRotation': {
            'intervalKm': 10000.0,
            'remainingKm': 10000.0,
            'lastServiceAt': null,
            'status': "NORMAL"
          },
          'fullInspection': {
            'intervalKm': 20000.0,
            'remainingKm': 20000.0,
            'lastServiceAt': null,
            'status': "NORMAL"
          }
        }
      });
    }
  }

  void _showMaintenanceSchedule() async {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      final truckId = _user?.preferredTruck ?? "GT-001";
      await _initializeMaintenanceIfNeeded(truckId);

      if (!context.mounted) return;

      _showStyledBottomSheet(
        title: "Maintenance Schedule",
        children: [
          const Text("Upcoming truck service dates", style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 20),
          StreamBuilder(
            stream: _database.ref('trucks/$truckId/maintenance').onValue,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text("Error: ${snapshot.error}");
              if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
                return const Center(child: CircularProgressIndicator());
              }
              
              final Map data = snapshot.data!.snapshot.value as Map;
              
              return Column(
                children: [
                  _buildMaintenanceItem("Oil Change", data['oilChange'], "oilChange", truckId),
                  const SizedBox(height: 12),
                  _buildMaintenanceItem("Tire Rotation", data['tireRotation'], "tireRotation", truckId),
                  const SizedBox(height: 12),
                  _buildMaintenanceItem("Full Inspection", data['fullInspection'], "fullInspection", truckId),
                ],
              );
            },
          )
        ],
      );
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  Widget _buildMaintenanceItem(String title, dynamic item, String key, String truckId) {
    if (item == null) return const SizedBox.shrink();
    
    double remaining = (item['remainingKm'] ?? 0.0).toDouble();
    if (remaining < 0) remaining = 0.0;
    
    String status = (item['status'] ?? "NORMAL").toString();
    
    Color statusColor = Colors.green;
    if (status == "DUE SOON") statusColor = Colors.orange;
    if (status == "OVERDUE") statusColor = Colors.red;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
                const SizedBox(height: 4),
                Text("Remaining: ${remaining.toStringAsFixed(1)} km", style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w900, fontSize: 10)),
              ),
              const SizedBox(height: 8),
              _HoverZoomLink(
                onTap: status == "NORMAL" ? null : () => _handleMarkMaintenanceDone(truckId, key, item['intervalKm'] ?? 5000.0),
                child: Text(
                  "MARK DONE",
                  style: TextStyle(
                    color: status == "NORMAL" ? Colors.grey.shade300 : AppColors.tealText,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    letterSpacing: 0.5
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleMarkMaintenanceDone(String truckId, String key, double interval) async {
    try {
      await _database.ref('trucks/$truckId/maintenance/$key').update({
        'status': 'NORMAL',
        'remainingKm': interval,
        'lastServiceAt': ServerValue.timestamp,
      });
      if (mounted) CustomNotification.showTopNotification(context, "Maintenance task completed!", false);
    } catch (e) {
      if (mounted) CustomNotification.showTopNotification(context, "Failed to update maintenance.");
    }
  }

  void _showReportIssue() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      final descCtrl = TextEditingController();
      final typeCtrl = TextEditingController(text: "Engine");
      final urgencyCtrl = TextEditingController(text: "Medium");

      _showModal("Report Truck Issue", [
        const Text("Describe any mechanical or technical problems", style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        
        // Custom Picker for Issue Type
        StatefulBuilder(
          builder: (context, setModalState) => _buildTextField(
            "Issue Type", 
            typeCtrl, 
            readOnly: true,
            hintText: "Select issue category",
            suffixIcon: Icons.keyboard_arrow_down_rounded,
            onTap: () => _showSelectionPicker(
              title: "Select Issue Category",
              options: ["Engine", "Tires", "Brakes", "GPS", "Electrical", "Fuel", "Transmission", "Hydraulic System", "Body Damage", "Other"],
              selectedValue: typeCtrl.text,
              onSelect: (v) {
                typeCtrl.text = v;
                setModalState(() {});
              },
            ),
          ),
        ),
        
        // Custom Picker for Urgency
        StatefulBuilder(
          builder: (context, setModalState) => _buildTextField(
            "Urgency Level", 
            urgencyCtrl, 
            readOnly: true,
            hintText: "Select urgency level",
            suffixIcon: Icons.keyboard_arrow_down_rounded,
            onTap: () => _showSelectionPicker(
              title: "Select Urgency Level",
              options: ["Low", "Medium", "High", "Critical"],
              selectedValue: urgencyCtrl.text,
              onSelect: (v) {
                urgencyCtrl.text = v;
                setModalState(() {});
              },
            ),
          ),
        ),

        _buildTextField(
          "Brief Description", 
          descCtrl, 
          maxLines: 4, 
          hintText: "Enter your brief description",
        ),
      ], "Submit Report", () async {
        final description = descCtrl.text.trim();
        if (description.isEmpty) {
          CustomNotification.showTopNotification(context, "Please complete all required fields.");
          return false;
        }

        if (_user == null) {
          CustomNotification.showTopNotification(context, "User session not found. Please log in again.");
          return false;
        }

        try {
          // Check for location permissions first
          LocationPermission permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          
          // Attempt to get position with a short timeout to prevent hanging
          Position? pos;
          if (permission != LocationPermission.deniedForever) {
            try {
              pos = await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.medium,
                timeLimit: const Duration(seconds: 5),
              );
            } catch (e) {
              debugPrint("GPS Error during report: $e");
              try {
                pos = await Geolocator.getLastKnownPosition();
              } catch (_) {}
            }
          }

          final truckId = _user?.preferredTruck ?? "GT-001";
          
          final newIssueRef = _database.ref('truck_issues').push();
          final String issueId = newIssueRef.key ?? '';
          
          await newIssueRef.set({
            'driverId': _user?.userId,
            'driverName': _user?.name,
            'truckId': truckId,
            'issueType': typeCtrl.text,
            'description': description,
            'urgency': urgencyCtrl.text,
            'latitude': pos?.latitude ?? 0.0,
            'longitude': pos?.longitude ?? 0.0,
            'createdAt': ServerValue.timestamp,
            'updatedAt': ServerValue.timestamp,
            'status': 'PENDING',
            'isReadByDriver': false,
            'isReadByAdmin': false,
          });

          // TRIGGER NOTIFICATION FOR ADMIN
          await _database.ref('notifications').push().set({
            'type': 'DRIVER_ISSUE',
            'title': 'New Truck Issue Reported',
            'message': '${_user?.name} reported a ${typeCtrl.text} issue for $truckId',
            'truck_id': truckId,
            'driver_id': _user?.userId.toString(),
            'relatedId': issueId,
            'targetRole': 'admin',
            'timestamp': ServerValue.timestamp,
            'isRead': false,
          });

          if (mounted) {
            CustomNotification.showTopNotification(context, "Truck issue reported successfully.", false);
          }
          return true;
        } catch (e) {
          debugPrint("Submit Issue Error: $e");
          if (mounted) {
            CustomNotification.showTopNotification(context, "Submission failed. Please check your connection.", true);
          }
          return false;
        }
      }, loadingText: "Submitting report...");
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  void _showSelectionPicker({required String title, required List<String> options, String? selectedValue, required Function(String) onSelect}) {
    _showStyledBottomSheet(
      title: title,
      children: [
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: options.length,
          itemBuilder: (context, i) {
            bool isSelected = options[i] == selectedValue;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              title: Text(
                options[i], 
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600, 
                  color: isSelected ? AppColors.tealText : const Color(0xFF2C3E50),
                  fontSize: 16
                )
              ),
              trailing: isSelected 
                ? const Icon(Icons.check_circle_rounded, color: AppColors.tealText, size: 24)
                : Icon(Icons.circle_outlined, color: Colors.grey.shade300, size: 24),
              onTap: () {
                onSelect(options[i]);
                Navigator.pop(context);
              },
            );
          },
        ),
      ],
    );
  }

  void _showIssueHistory() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      _showStyledBottomSheet(
        title: "Issue History",
        children: [
          StreamBuilder(
            stream: _database.ref('truck_issues').orderByChild('driverId').equalTo(_user?.userId).onValue,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text("Error: ${snapshot.error}");
              if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
                return const Center(child: Padding(padding: EdgeInsets.all(40), child: Text("No previous reports.", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))));
              }
              
              final Map data = snapshot.data!.snapshot.value as Map;
              final List issues = [];
              data.forEach((k, v) => issues.add({...v as Map, 'id': k}));
              issues.sort((a, b) => (b['createdAt'] ?? 0).compareTo(a['createdAt'] ?? 0));

              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("${issues.length} Reports Found", style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
                      _HoverZoomLink(
                        onTap: () => _handleDeleteAllIssues(issues),
                        child: const Text("Delete All", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w900, fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: issues.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final issue = issues[i];
                      return _buildDismissibleIssue(issue);
                    },
                  ),
                ],
              );
            },
          )
        ],
      );
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  Widget _buildDismissibleIssue(Map issue) {
    String status = (issue['status'] ?? "PENDING").toString().toUpperCase().replaceAll('_', ' ');
    Color statusColor = Colors.orange;
    if (status == "IN PROGRESS") statusColor = Colors.blue;
    if (status == "RESOLVED") statusColor = Colors.green;
    if (status == "REJECTED") statusColor = Colors.red;

    return Dismissible(
      key: Key(issue['id']),
      direction: DismissDirection.horizontal,
      confirmDismiss: (dir) => _showConfirmActionDialog(
        title: "Delete Report?",
        message: "Are you sure you want to remove this issue report from your history?",
        confirmText: "Delete",
        isDestructive: true
      ),
      onDismissed: (dir) => _database.ref('truck_issues/${issue['id']}').remove(),
      background: _buildDismissBackground(Alignment.centerLeft),
      secondaryBackground: _buildDismissBackground(Alignment.centerRight),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white, 
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(0, 4))],
          border: Border.all(color: Colors.grey.shade100)
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  (issue['issueType'] ?? "Issue").toString().toUpperCase(), 
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Colors.grey, letterSpacing: 1.1)
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w900, fontSize: 10)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              issue['description'] ?? "", 
              style: const TextStyle(fontSize: 15, color: Color(0xFF2C3E50), fontWeight: FontWeight.w700, height: 1.4)
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.calendar_today_rounded, size: 12, color: Colors.grey.shade400),
                const SizedBox(width: 8),
                Text(
                  DateFormat('MMM dd, yyyy • hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(issue['createdAt'] ?? 0)),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (issue['adminResponse'] != null && issue['adminResponse'].toString().isNotEmpty) ...[
              const Divider(height: 32),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA), 
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade100)
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.reply_rounded, size: 12, color: AppColors.tealText),
                        SizedBox(width: 8),
                        Text("ADMIN RESPONSE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: AppColors.tealText, letterSpacing: 0.5)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      issue['adminResponse'], 
                      style: const TextStyle(fontSize: 13, color: Colors.black87, fontWeight: FontWeight.w600, height: 1.5)
                    ),
                  ],
                ),
              )
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDismissBackground(Alignment alignment) {
    return Container(
      decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(24)),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
    );
  }

  Future<void> _handleDeleteAllIssues(List issues) async {
    bool confirmed = await _showConfirmActionDialog(
      title: "Clear History?",
      message: "This will permanently remove all your reported issues.",
      confirmText: "Delete All",
      isDestructive: true
    );
    if (confirmed) {
      for (var issue in issues) {
        await _database.ref('truck_issues/${issue['id']}').remove();
      }
      if (mounted) CustomNotification.showTopNotification(context, "History cleared successfully", false);
    }
  }

  Future<bool> _showConfirmActionDialog({
    required String title, 
    required String message, 
    String confirmText = "Confirm", 
    String cancelText = "Cancel",
    bool isDestructive = false
  }) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDestructive ? Icons.delete_forever_rounded : Icons.logout_rounded, 
                color: isDestructive ? Colors.redAccent : AppColors.tealText, 
                size: 48
              ),
              const SizedBox(height: 24),
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5)),
              const SizedBox(height: 32),
              HoverActionButton(
                text: confirmText,
                isDestructive: isDestructive,
                onTap: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 16),
              _HoverZoomLink(
                onTap: () => Navigator.of(context).pop(false),
                child: Text(cancelText, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    ) ?? false;
  }

  // --- OTHER MENU MODALS ---

  void _showEditProfileModal() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);
    
    try {
      _showModal("Edit Profile", [
        _buildTextField("Full Legal Name", _nameController),
        _buildTextField("Contact Number", _phoneController),
        _buildTextField("Email Address", _emailController),
        _buildTextField("Complete Address", _addressController),
      ], "SAVE CHANGES", () async {
        return await _handleUpdateProfile(
          name: _nameController.text.trim(),
          phone: _phoneController.text.trim(),
          email: _emailController.text.trim(),
          truck: _user?.preferredTruck ?? "",
        );
      });
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  void _showChangePasswordModal() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      final oldPassNode = FocusNode();
      final newPassNode = FocusNode();
      final confirmPassNode = FocusNode();

      String? oldPassError;
      String? newPassError;
      String? confirmPassError;

      bool oldObscured = true;
      bool newObscured = true;
      bool confirmObscured = true;

      _showStyledBottomSheet(
        title: "Change Password",
        children: [
          StatefulBuilder(builder: (context, setModalState) {
            
            void validateOld() {
              if (_oldPasswordController.text.isEmpty) {
                oldPassError = "Please enter current password";
              } else {
                oldPassError = null;
              }
              setModalState(() {});
            }

            void validateNew() {
              final val = _newPasswordController.text;
              if (val.isEmpty) {
                newPassError = "Please enter new password";
              } else if (val.length < 6) {
                newPassError = "Must be at least 6 characters";
              } else if (!RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]').hasMatch(val)) {
                newPassError = "Use Upper, Lower, Number, and Special symbol";
              } else {
                newPassError = null;
              }
              setModalState(() {});
            }

            void validateConfirm() {
              if (_confirmPasswordController.text != _newPasswordController.text) {
                confirmPassError = "Passwords do not match";
              } else {
                confirmPassError = null;
              }
              setModalState(() {});
            }

            oldPassNode.addListener(() { if (!oldPassNode.hasFocus) validateOld(); });
            newPassNode.addListener(() { if (!newPassNode.hasFocus) validateNew(); });
            confirmPassNode.addListener(() { if (!confirmPassNode.hasFocus) validateConfirm(); });

            return Column(
              children: [
                _buildTextField(
                  "Current Password", 
                  _oldPasswordController, 
                  isPassword: true, 
                  isObscured: oldObscured,
                  focusNode: oldPassNode,
                  errorText: oldPassError,
                  onToggleVisibility: () => setModalState(() => oldObscured = !oldObscured),
                ),
                _buildTextField(
                  "New Password", 
                  _newPasswordController, 
                  isPassword: true, 
                  isObscured: newObscured,
                  focusNode: newPassNode,
                  errorText: newPassError,
                  onToggleVisibility: () => setModalState(() => newObscured = !newObscured),
                ),
                _buildTextField(
                  "Confirm New Password", 
                  _confirmPasswordController, 
                  isPassword: true, 
                  isObscured: confirmObscured,
                  focusNode: confirmPassNode,
                  errorText: confirmPassError,
                  onToggleVisibility: () => setModalState(() => confirmObscured = !confirmObscured),
                ),
                const SizedBox(height: 32),
                HoverActionButton(
                  text: "UPDATE PASSWORD",
                  isLoading: _isNavigating && _oldPasswordController.text.isNotEmpty, // Using existing state
                  loadingText: "Saving changes...",
                  onTap: () async {
                    validateOld(); validateNew(); validateConfirm();
                    if (oldPassError != null || newPassError != null || confirmPassError != null) return;

                    bool confirmed = await _showConfirmActionDialog(
                      title: "Update Password?",
                      message: "Are you sure you want to change your security credentials?",
                      confirmText: "Yes, Update",
                    );

                    if (confirmed) {
                      setModalState(() => _isNavigating = true);
                      await _handleUpdatePasswordInModal(setModalState);
                      if (mounted) setModalState(() => _isNavigating = false);
                    }
                  },
                ),
              ],
            );
          }),
        ],
      );
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  Future<void> _handleUpdatePasswordInModal(StateSetter setModalState) async {
    final oldPass = _oldPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();

    try {
      final res = await _apiService.changePassword(_user!.userId, _user!.role, oldPass, newPass);
      if (res.data['success'] == true) {
        if (mounted) {
          Navigator.of(context).pop();
          CustomNotification.showTopNotification(context, "Password changed successfully!", false);
          _oldPasswordController.clear(); _newPasswordController.clear(); _confirmPasswordController.clear();
        }
      } else {
        CustomNotification.showTopNotification(context, res.data['message'] ?? "Wrong current password");
      }
    } catch (e) {
      CustomNotification.showTopNotification(context, "Connection issue. Try again.");
    }
  }

  void _showNotificationPreferences() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      _showModal("Notification Preferences", [
        StatefulBuilder(
          builder: (context, setModalState) {
            return Column(
              children: [
                _buildToggle("Duty Alerts", _dutyAlerts, (v) async {
                  await _updateSettings('dutyAlerts', v);
                  setModalState(() {});
                }),
                _buildToggle("Collection Notifications", _collectionNotifications, (v) async {
                  await _updateSettings('collectionNotifications', v);
                  setModalState(() {});
                }),
                _buildToggle("Maintenance Notifications", _maintenanceNotifications, (v) async {
                  await _updateSettings('maintenanceNotifications', v);
                  setModalState(() {});
                }),
                _buildToggle("Emergency Alerts", _emergencyAlerts, (v) async {
                  await _updateSettings('emergencyAlerts', v);
                  setModalState(() {});
                }),
              ],
            );
          }
        ),
      ], null, null);
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  void _showDailyRoutes() async {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      _showStyledBottomSheet(
        title: "Daily Routes",
        children: [
          StreamBuilder(
            stream: _database.ref('driver_routes').orderByChild('driver_id').equalTo(_user?.userId).onValue,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text("Error: ${snapshot.error}");
              if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
                return const Center(child: Padding(padding: EdgeInsets.all(40), child: Text("No assigned routes found.", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))));
              }
              
              final Map data = snapshot.data!.snapshot.value as Map;
              final List routes = [];
              data.forEach((k, v) => routes.add({...v as Map, 'id': k}));
              routes.sort((a, b) => (b['created_at'] ?? 0).compareTo(a['created_at'] ?? 0));

              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: routes.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final r = routes[i];
                  String status = (r['route_status'] ?? "PENDING").toString().toUpperCase();
                  Color statusColor = status == "COMPLETED" ? Colors.green : Colors.blue;

                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white, 
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(0, 4))],
                      border: Border.all(color: Colors.grey.shade100)
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              r['route_date'] ?? "Current Route", 
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Colors.grey)
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                              child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w900, fontSize: 10)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          r['route_name'] ?? "Morning Collection", 
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.route_rounded, size: 14, color: Colors.grey),
                            const SizedBox(width: 6),
                            Text("${r['total_distance_km'] ?? '0.0'} km covered", style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          )
        ],
      );
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  void _showAboutUsModal() {
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

  void _showPerformanceStats() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      final truckId = _user?.preferredTruck ?? "GT-001";
      _showModal("Performance Stats", [
        StreamBuilder(
          stream: _database.ref('truck_locations/$truckId').onValue,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text("Error: ${snapshot.error}");
            if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final Map data = snapshot.data!.snapshot.value as Map;
            return Column(
              children: [
                _buildInfoRow("Collection Efficiency", "${(data['efficiency'] ?? 0.0).toStringAsFixed(1)}%", valueColor: AppColors.statusGreen),
                const SizedBox(height: 16),
                _buildInfoRow("Average Speed", "${(data['avg_speed'] ?? 0.0).toStringAsFixed(1)} km/h"),
                const SizedBox(height: 16),
                _buildInfoRow("Distance Covered", "${(data['distance'] ?? 0.0).toStringAsFixed(2)} km"),
              ],
            );
          }
        ),
      ], null, null);
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  void _showAlertHistory() {
    if (_isNavigating) return;
    setState(() => _isNavigating = true);

    try {
      _showModal("Alert History", [
        StreamBuilder(
          stream: _database.ref('notifications').onValue,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text("Error: ${snapshot.error}");
            if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
              return const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Text("No alerts history found.", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))));
            }
            final Map data = snapshot.data!.snapshot.value as Map;
            final List alerts = [];
            data.forEach((k, v) { 
              final val = v as Map;
              final String type = (val['type'] ?? '').toString();
              final String? truckId = val['truck_id']?.toString() ?? val['truckId']?.toString();
              
              // Basic filter matching DriverDashboard logic
              bool isRelevant = false;
              if (truckId != null && truckId.isNotEmpty && truckId == _user?.preferredTruck) {
                if (!['auto_arrival', 'auto_approach', 'manual_alert', 'COLLECTION_ALERT', 'COMPLAINT_RESOLVED'].contains(type)) {
                  isRelevant = true;
                }
              }
              if (val['targetUserId']?.toString() == _user?.userId.toString()) isRelevant = true;

              if (isRelevant) alerts.add(v); 
            });
            
            if (alerts.isEmpty) {
              return const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Text("No alerts history found.", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))));
            }

            alerts.sort((a, b) => (b['timestamp'] ?? 0).compareTo(a['timestamp'] ?? 0));
            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: alerts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final a = alerts[i];
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a['title'] ?? "Alert", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text(a['message'] ?? "", style: const TextStyle(fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                );
              },
            );
          },
        )
      ], null, null);
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  // --- HANDLERS ---

  void _showLanguageModal() {
    _showStyledBottomSheet(
      title: "Language Selection",
      children: [
        _buildLanguageItem("English", AppLanguage.en),
        _buildLanguageItem("Filipino", AppLanguage.fil),
        _buildLanguageItem("Bisaya", AppLanguage.bis),
      ],
    );
  }

  Widget _buildLanguageItem(String label, AppLanguage lang) {
    bool isSelected = AppLocalizations.currentLanguage.value == lang;
    return ListTile(
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
      leading: Icon(Icons.language_rounded, color: isSelected ? AppColors.tealText : Colors.grey),
      trailing: isSelected 
        ? Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(color: Color(0xFF00897B), shape: BoxShape.circle),
            child: const Icon(Icons.check, color: Colors.white, size: 14),
          )
        : null,
      onTap: () async {
        final nav = Navigator.of(context);
        await AppLocalizations.setLanguage(lang);
        if (mounted) setState(() {});
        nav.pop();
      },
    );
  }

  void _showFAQsModal() {
    _showStyledBottomSheet(
      title: "FAQs",
      children: [
        _buildFAQItem("How do I update my route status?", "Use the controls on your main dashboard: 'START' to begin, 'PAUSE' if you are idle, 'FULL' when the truck is at capacity, and 'DONE' when the route is finished."),
        _buildFAQItem("What if I encounter a vehicle issue?", "Go to the 'Truck Information' section in settings and use 'Report Issue' to notify the admin about vehicle problems."),
        _buildFAQItem("How is my performance calculated?", "The system tracks your route completion time, fuel efficiency (if logged), and feedback from the community."),
        _buildFAQItem("Can I change my assigned truck?", "Truck assignments are managed by the administrator. Contact support if you need to be reassigned to a different vehicle."),
        _buildFAQItem("How do I update my personal data?", "Use the 'Data Management' section in settings to update your name, email, or contact number."),
      ],
    );
  }

  Widget _buildFAQItem(String q, String a) {
    return ExpansionTile(
      shape: const RoundedRectangleBorder(side: BorderSide.none),
      collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
      title: Text(q, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF1A1A1A))),
      iconColor: AppColors.tealText,
      collapsedIconColor: Colors.grey,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text(a, style: TextStyle(color: Colors.grey.shade700, height: 1.5, fontSize: 14, fontWeight: FontWeight.w500)),
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

  void _showDataManagementModal() {
    final nameCtrl = TextEditingController(text: _user?.name);
    final emailCtrl = TextEditingController(text: _user?.email);
    final phoneCtrl = TextEditingController(text: _user?.phone);
    final truckCtrl = TextEditingController(text: _user?.preferredTruck);

    String? nameError;
    String? emailError;
    String? phoneError;

    _showStyledBottomSheet(
      title: "Data Management",
      children: [
        StatefulBuilder(
          builder: (context, setModalState) {
            void validateName(String val) {
              if (val.isEmpty) {
                setModalState(() => nameError = "Name is required");
              } else if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(val)) {
                setModalState(() => nameError = "Name must contain letters and spaces only");
              } else {
                setModalState(() => nameError = null);
              }
            }

            void validateEmail(String val) {
              if (val.isEmpty) {
                setModalState(() => emailError = "Email is required");
              } else if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(val)) {
                setModalState(() => emailError = "Invalid email format");
              } else {
                setModalState(() => emailError = null);
              }
            }

            void validatePhone(String val) {
              if (val.isEmpty) {
                setModalState(() => phoneError = "Contact number is required");
              } else if (!RegExp(r'^(09|63)\d{9}$').hasMatch(val)) {
                setModalState(() => phoneError = "Invalid phone number (11 digits required)");
              } else {
                setModalState(() => phoneError = null);
              }
            }

            return Column(
              children: [
                _buildTextField("Full Name", nameCtrl, 
                  onChanged: validateName, 
                  errorText: nameError,
                ),
                const SizedBox(height: 16),
                _buildTextField("Email Address", emailCtrl, 
                  onChanged: validateEmail, 
                  errorText: emailError,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                _buildTextField("Contact Number", phoneCtrl, 
                  onChanged: validatePhone, 
                  errorText: phoneError,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                _buildTextField("Assigned Truck", truckCtrl),
                const SizedBox(height: 24),
                HoverActionButton(
                  text: "Save Changes",
                  loadingText: "Saving changes...",
                  isLoading: _isNavigating,
                  useZoom: true,
                  onTap: () async {
                    validateName(nameCtrl.text);
                    validateEmail(emailCtrl.text);
                    validatePhone(phoneCtrl.text);

                    if (nameError != null || emailError != null || phoneError != null) {
                      return;
                    }

                    bool confirm = await _showConfirmActionDialog(
                      title: "Save Changes?",
                      message: "Are you sure you want to update your profile information?",
                      confirmText: "Yes, Save",
                      cancelText: "No",
                    );

                    if (confirm) {
                      await _handleUpdateProfile(
                        name: nameCtrl.text.trim(),
                        email: emailCtrl.text.trim(),
                        phone: phoneCtrl.text.trim(),
                        truck: truckCtrl.text.trim(),
                      );
                    }
                  },
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<bool> _handleUpdateProfile({
    required String name,
    required String email,
    required String phone,
    required String truck,
  }) async {
    setState(() => _isNavigating = true);
    try {
      final res = await _apiService.updateProfile(
        userId: _user!.userId,
        role: _user!.role,
        name: name,
        phone: phone,
        email: email,
        preferredTruck: truck,
        address: _user!.completeAddress,
      );

      if (res.data['success'] == true) {
        final updatedUser = _user!.copyWith(
          name: name,
          phone: phone,
          email: email,
          preferredTruck: truck,
        );
        await SessionManager.saveUser(updatedUser.toJson());
        _loadUser();
        if (mounted) {
          CustomNotification.showTopNotification(context, "Profile updated successfully!", false);
        }
        return true;
      } else {
        CustomNotification.showTopNotification(context, res.data['message'] ?? "Update failed");
        return false;
      }
    } catch (e) {
      CustomNotification.showTopNotification(context, "Error updating profile: $e");
      return false;
    } finally {
      if (mounted) setState(() => _isNavigating = false);
    }
  }

  Widget _buildDataText(String label, String? val) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(val ?? "N/A", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))),
      ],
    );
  }

  void _showDeleteAccountConfirmation() async {
    bool confirmed = await _showConfirmActionDialog(
      title: "Delete Account?",
      message: "This action cannot be undone. All your data including issue history and routes will be permanently erased.",
      confirmText: "Delete Permanently",
      cancelText: "No",
      isDestructive: true
    );
    if (confirmed) {
      setState(() => _isNavigating = true);
      try {
        final res = await _apiService.deleteUser(_user!.userId, _user!.role);
        if (res.data['success'] == true) {
           await SessionManager.logout();
           if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
        }
      } catch (e) {
        CustomNotification.showTopNotification(context, "Delete failed: $e");
      } finally {
        if (mounted) setState(() => _isNavigating = false);
      }
    }
  }

  Future<void> _handleUpdatePassword() async {
    final oldPass = _oldPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();
    final confirmPass = _confirmPasswordController.text.trim();

    if (oldPass.isEmpty || newPass.isEmpty || confirmPass.isEmpty) {
      CustomNotification.showTopNotification(context, "Please fill all fields"); return;
    }
    if (newPass.length < 6) {
      CustomNotification.showTopNotification(context, "New password must be at least 6 characters"); return;
    }
    if (newPass != confirmPass) {
      CustomNotification.showTopNotification(context, "Passwords do not match"); return;
    }

    try {
      final res = await _apiService.changePassword(_user!.userId, _user!.role, oldPass, newPass);
      if (res.data['success'] == true) {
        if (mounted) {
          Navigator.of(context).pop();
          CustomNotification.showTopNotification(context, "Password changed successfully!", false);
          _oldPasswordController.clear(); _newPasswordController.clear(); _confirmPasswordController.clear();
        }
      } else {
        CustomNotification.showTopNotification(context, res.data['message'] ?? "Password change failed");
      }
    } catch (e) {
      CustomNotification.showTopNotification(context, "Error: Connection issue during update");
    }
  }


  // --- UI UTILS ---

  void _showStyledBottomSheet({required String title, required List<Widget> children}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
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

  void _showModal(String title, List<Widget> body, String? btnText, Future<bool> Function()? onBtnTap, {String loadingText = "Saving changes..."}) async {
    _showStyledBottomSheet(
      title: title,
      children: [
        ...body,
        if (btnText != null) ...[
          const SizedBox(height: 32),
          StatefulBuilder(builder: (context, setModalState) {
            bool isModalLoading = false;
            return HoverActionButton(
              text: btnText,
              loadingText: loadingText,
              isLoading: isModalLoading,
              useZoom: true,
              onTap: isModalLoading ? null : () async {
                // Capture the navigator before any await
                final navigator = Navigator.of(context);
                
                bool confirmed = await _showConfirmActionDialog(
                  title: title.contains("Report") ? "Submit Report?" : "Save Changes?",
                  message: title.contains("Report") 
                    ? "Are you sure you want to submit this issue report?" 
                    : "Are you sure you want to proceed with these updates?",
                  confirmText: title.contains("Report") ? "Yes, Submit" : "Yes, Save",
                );

                if (confirmed && onBtnTap != null) {
                  setModalState(() => isModalLoading = true);
                  try {
                    bool success = await onBtnTap();
                    if (mounted) {
                      setModalState(() => isModalLoading = false);
                      if (success) {
                        // Small delay to ensure previous dialog transitions are settled
                        await Future.delayed(const Duration(milliseconds: 200));
                        if (navigator.canPop()) {
                          navigator.pop();
                        }
                      }
                    }
                  } catch (e) {
                    if (mounted) setModalState(() => isModalLoading = false);
                    debugPrint("Modal Action Error: $e");
                  }
                }
              },
            );
          }),
        ],
      ],
    );
  }

  Widget _buildInput(String label, TextEditingController controller, {bool isPassword = false}) {
    return _buildTextField(label, controller, obscureText: isPassword);
  }

  Widget _buildTextField(String label, TextEditingController controller, {
    bool obscureText = false, 
    TextInputType? keyboardType, 
    int maxLines = 1, 
    bool readOnly = false, 
    VoidCallback? onTap, 
    String? hintText, 
    IconData? suffixIcon, 
    IconData? prefixIcon, 
    bool isPassword = false, 
    bool isObscured = true, 
    VoidCallback? onToggleVisibility, 
    String? errorText, 
    FocusNode? focusNode,
    Function(String)? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A), letterSpacing: 0.2)),
          ),
          Theme(
            data: Theme.of(context).copyWith(
              textSelectionTheme: TextSelectionThemeData(
                selectionColor: AppColors.tealText.withValues(alpha: 0.2),
                selectionHandleColor: AppColors.tealText,
              ),
            ),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              obscureText: isPassword ? isObscured : obscureText,
              keyboardType: keyboardType,
              maxLines: maxLines,
              readOnly: readOnly,
              onTap: onTap,
              onChanged: onChanged,
              cursorColor: const Color(0xFF424242), // Dark grey cursor
              style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), fontSize: 15),
              decoration: InputDecoration(
                hintText: hintText ?? "Enter your ${label.toLowerCase()}",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w400),
                filled: true,
                fillColor: const Color(0xFFF7F8FA),
                prefixIcon: prefixIcon != null ? Icon(prefixIcon, color: AppColors.tealText, size: 20) : null,
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: errorText != null ? Colors.redAccent : Colors.grey.shade200, width: 1.2)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: errorText != null ? Colors.redAccent : AppColors.tealText, width: 2.0)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                suffixIcon: isPassword 
                  ? IconButton(
                      icon: Icon(isObscured ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.grey.shade400, size: 20),
                      onPressed: onToggleVisibility,
                    )
                  : (suffixIcon != null ? Icon(suffixIcon, color: Colors.grey.shade400) : null),
              ),
            ),
          ),
          if (errorText != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 6),
              child: Text(errorText, style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  Widget _buildToggle(String label, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Switch(
            value: value, 
            onChanged: (v) { onChanged(v); setState(() {}); }, 
            activeThumbColor: AppColors.tealText
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog(BuildContext context) async {
    bool confirmed = await _showConfirmActionDialog(
      title: "Sign Out?",
      message: "Are you sure you want to end your session? You will need to login again to access your dashboard.",
      confirmText: "Sign Out",
      cancelText: "Go Back",
      isDestructive: false
    );
    if (confirmed) {
      await SessionManager.logout();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/');
      }
    }
  }
}

class _HoverZoomLink extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _HoverZoomLink({required this.child, this.onTap});
  @override
  State<_HoverZoomLink> createState() => _HoverZoomLinkState();
}
class _HoverZoomLinkState extends State<_HoverZoomLink> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    bool isEnabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = isEnabled),
      onExit: (_) => setState(() => _isActive = false),
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = isEnabled),
        onTapUp: (_) => setState(() => _isActive = false),
        onTapCancel: () => setState(() => _isActive = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isActive ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}

class _HoverZoomCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  const _HoverZoomCard({required this.child, this.onTap, this.scale = 1.02});
  @override
  State<_HoverZoomCard> createState() => _HoverZoomCardState();
}
class _HoverZoomCardState extends State<_HoverZoomCard> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    bool isEnabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = isEnabled),
      onExit: (_) => setState(() => _isActive = false),
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = isEnabled),
        onTapUp: (_) => setState(() => _isActive = false),
        onTapCancel: () => setState(() => _isActive = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isActive ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}
