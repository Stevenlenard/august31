import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../api/api_service.dart';
import '../utils/session_manager.dart';
import '../utils/app_theme.dart';
import '../utils/system_logger.dart';
import '../utils/responsive.dart';
import 'analytics_screen.dart';
import 'track_trucks_screen.dart';
import 'complaints_screen.dart';
import 'admin_settings_screen.dart';
import 'data_management_screen.dart';
import 'user_management_screen.dart';
import '../widgets/mapbox_view.dart';
import '../services/admin_settings_service.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  final AdminSettingsService _adminSettingsService = AdminSettingsService();

  double _averageSpeed = 0.0;
  int _activeHotspots = 0;
  int _totalRoutesToday = 0;
  int _completedRoutesToday = 0;
  int _resolvedComplaints = 0;
  int _totalComplaints = 0;
  int _activeTrucks = 0;
  int _pendingComplaints = 0;
  int _inProgressComplaints = 0;
  int _residentsCount = 0;
  int _unreadNotificationsCount = 0;
  double _coveragePercent = 0.0;
  int _selectedIndex = 0;
  bool _isSidebarExtended = true;

  List<Map<dynamic, dynamic>> _fleetStatus = [];
  List<Map<dynamic, dynamic>> _recentLogs = [];

  @override
  void initState() {
    super.initState();
    _adminSettingsService.startListening();
    _setupListeners();
    _refreshAllStats();
    _checkAutoBackupDownload();
    _setupLogsListener();
  }

  void _setupLogsListener() {
    _database.ref('system_logs').limitToLast(10).onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map? data = event.snapshot.value as Map?;
        if (data == null) return;
        final List<Map<dynamic, dynamic>> logs = [];
        data.forEach((key, value) {
          if (value is Map) logs.add(Map<dynamic, dynamic>.from(value));
        });
        logs.sort((a, b) => (b['timestamp'] ?? 0).toString().compareTo((a['timestamp'] ?? 0).toString()));
        if (mounted) setState(() => _recentLogs = logs);
      }
    });
  }

  Future<void> _checkAutoBackupDownload() async {
    try {
      final user = await SessionManager.getUser();
      if (user == null || user.role != 'admin') return;
      final settingsRes = await _apiService.getUserSettings(user.userId, user.role);
      final settingsData = settingsRes.data;
      if (settingsData is Map && settingsData['success'] == true && settingsData['data'] != null && settingsData['data']['auto_backup'] == true) {
        final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
        final lastDownload = await SessionManager.getLastAutoDownloadDate();
        if (lastDownload != today) {
          final response = await _apiService.triggerAutoBackupChecker();
          final data = response.data;
          if (data is Map && data['success'] == true && data['url'] != null) {
            final uri = Uri.parse(data['url']);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              await SessionManager.setLastAutoDownloadDate(today);
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Daily auto-backup downloaded: ${data['filename']}")));
            }
          }
        }
      }
    } catch (e) { debugPrint("Auto-backup check error: $e"); }
  }

  void _refreshAllStats() {
    _fetchComplaints();
    _fetchUserCounts();
  }

  Future<void> _fetchUserCounts() async {
    try {
      final response = await _apiService.getUsers();
      if (response.data['success'] == true) {
        final List residents = response.data['residents'] ?? [];
        if (mounted) setState(() => _residentsCount = residents.length);
      }
    } catch (e) { debugPrint("Error fetching user counts: $e"); }
  }

  void _setupListeners() {
    _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map? data = event.snapshot.value as Map?;
        if (data == null) return;
        final List<Map<dynamic, dynamic>> trucks = [];
        double totalSpeed = 0.0;
        int activeWithSpeed = 0;
        data.forEach((key, value) {
          if (value != null) {
            final truckMap = Map<dynamic, dynamic>.from(value as Map);
            trucks.add(truckMap);
            if (truckMap['isOnline'] == true) {
              final speed = double.tryParse(truckMap['speed']?.toString() ?? '0') ?? 0.0;
              if (speed > 0) { totalSpeed += speed; activeWithSpeed++; }
            }
          }
        });
        if (mounted) {
          setState(() {
            _activeTrucks = trucks.where((t) => t['isOnline'] == true).length;
            _fleetStatus = trucks;
            _averageSpeed = activeWithSpeed > 0 ? totalSpeed / activeWithSpeed : 0.0;
          });
        }
      }
    });

    _database.ref('driver_routes').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map? data = event.snapshot.value as Map?;
        if (data == null) return;
        int total = 0;
        int completed = 0;
        final String today = DateFormat('yyyy-MM-dd').format(DateTime.now());
        data.forEach((key, value) {
          if (value != null && value is Map) {
            total++;
            if (value['route_status'] == 'COMPLETED' || value['status'] == 'COMPLETED') completed++;
          }
        });
        if (mounted) {
          setState(() {
            _totalRoutesToday = total;
            _completedRoutesToday = completed;
            _coveragePercent = total > 0 ? (completed / total) * 100 : 0.0;
          });
        }
      }
    });

    _database.ref('complaints').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map? data = event.snapshot.value as Map?;
        if (data == null) return;
        int pending = 0; int inProgress = 0; int resolved = 0; int total = 0;
        String normalize(dynamic s) {
          if (s == null) return 'PENDING';
          String str = s.toString().toLowerCase().trim();
          if (str == 'in_progress' || (str.contains('in') && str.contains('progress'))) return 'IN_PROGRESS';
          if (str == 'resolved' || str == 'completed') return 'RESOLVED';
          return 'PENDING';
        }
        final Map<String, int> areaComplaints = {};
        data.forEach((key, value) {
          if (value != null && value is Map) {
            total++;
            final status = normalize(value['status']);
            if (status == 'PENDING') {
              pending++;
              if (value['purok'] != null) {
                final area = value['purok'].toString();
                areaComplaints[area] = (areaComplaints[area] ?? 0) + 1;
              }
            } else if (status == 'IN_PROGRESS') inProgress++;
            else if (status == 'RESOLVED') resolved++;
          }
        });
        if (mounted) {
          setState(() {
            _totalComplaints = total; _resolvedComplaints = resolved;
            _pendingComplaints = pending; _inProgressComplaints = inProgress;
            _activeHotspots = areaComplaints.values.where((count) => count > 3).length;
          });
        }
      }
    });

    _database.ref('notification_logs').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map? data = event.snapshot.value as Map?;
        if (data == null) return;
        int unread = 0;
        data.forEach((key, value) {
          if (value != null && value is Map && value['isRead'] == false) unread++;
        });
        if (mounted) setState(() => _unreadNotificationsCount = unread);
      } else { if (mounted) setState(() => _unreadNotificationsCount = 0); }
    });

    _database.ref('notification_logs').onChildAdded.listen((event) async {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = event.snapshot.value as Map?;
        if (data == null) return;
        final bool isGlobalEnabled = _adminSettingsService.appNotificationsEnabled.value;
        final bool isLocalEnabled = await SessionManager.isAppNotificationsEnabled();
        if (isGlobalEnabled && isLocalEnabled && mounted) {
          if (data['type'] == 'DRIVER_ISSUE' || data['type'] == 'RESIDENT_COMPLAINT') {
            final String title = data['title'] ?? 'System Alert';
            final String message = data['message'] ?? '';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.bold)), Text(message, style: const TextStyle(fontSize: 12))]),
              backgroundColor: data['type'] == 'DRIVER_ISSUE' ? const Color(0xFFFF1744) : const Color(0xFF1E88E5),
              behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 5),
            ));
          }
        }
      }
    });
  }

  Future<void> _fetchComplaints() async {
    try {
      final response = await _apiService.getComplaints();
      if (response.data['success'] == true) {
        final List complaints = response.data['data'] ?? [];
        String normalize(dynamic s) {
          if (s == null) return 'PENDING';
          String str = s.toString().toLowerCase().trim();
          if (str == 'in_progress' || (str.contains('in') && str.contains('progress'))) return 'IN_PROGRESS';
          if (str == 'resolved' || str == 'completed') return 'RESOLVED';
          return 'PENDING';
        }
        if (mounted) {
          setState(() {
            _totalComplaints = complaints.length;
            _resolvedComplaints = complaints.where((c) => normalize(c['status']) == 'RESOLVED').length;
            _pendingComplaints = complaints.where((c) => normalize(c['status']) == 'PENDING').length;
            _inProgressComplaints = complaints.where((c) => normalize(c['status']) == 'IN_PROGRESS').length;
            final Map<String, int> areaComplaints = {};
            for (var c in complaints) {
              if (normalize(c['status']) == 'PENDING' && c['purok'] != null) {
                final area = c['purok'].toString();
                areaComplaints[area] = (areaComplaints[area] ?? 0) + 1;
              }
            }
            _activeHotspots = areaComplaints.values.where((count) => count > 3).length;
          });
        }
      }
    } catch (e) { debugPrint("Error fetching complaints: $e"); }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobile = constraints.maxWidth < 600;
        bool isTablet = constraints.maxWidth >= 600 && constraints.maxWidth < 1024;
        bool isDesktop = constraints.maxWidth >= 1024;

        return Scaffold(
          backgroundColor: const Color(0xFFF0F2F5),
          drawer: (isMobile || isTablet) ? _buildMobileDrawer() : null,
          appBar: (isMobile || isTablet) ? AppBar(
            backgroundColor: Colors.white, elevation: 0,
            title: const Text("G-Tracker Admin", style: TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w900)),
            centerTitle: true, iconTheme: const IconThemeData(color: Color(0xFF1A1A1A)),
            actions: [
               _buildHeaderIconButton(Icons.notifications_none_rounded, badgeCount: _unreadNotificationsCount > 0 ? _unreadNotificationsCount : null, onTap: () => _showNotificationsModal(context), isInAppBar: true),
               const SizedBox(width: 8),
            ],
          ) : null,
          body: Row(
            children: [
              if (isDesktop) _buildSidebar(),
              Expanded(
                child: IndexedStack(
                  index: _selectedIndex,
                  children: [
                    _buildMainDashboard(isMobile, isTablet),
                    TrackTrucksScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                    AnalyticsScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                    ComplaintsScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                    UserManagementScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                    DataManagementScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                    AdminSettingsScreen(isEmbedded: true, onBack: () { _refreshAllStats(); if (mounted) setState(() => _selectedIndex = 0); }),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: (isMobile || isTablet) ? _buildBottomNav() : null,
        );
      },
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: _isSidebarExtended ? 260 : 80,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(5, 0))]),
      child: Column(children: [
        const SizedBox(height: 24),
        _isSidebarExtended ? Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.local_shipping_rounded, color: AppColors.tealText)), const SizedBox(width: 12), const Text("G-Tracker", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: AppColors.tealText))])) : const Icon(Icons.local_shipping_rounded, color: AppColors.tealText, size: 32),
        const SizedBox(height: 32),
        Expanded(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          _buildSidebarItem(Icons.dashboard_rounded, "Dashboard", 0), _buildSidebarItem(Icons.map_rounded, "Track Trucks", 1), _buildSidebarItem(Icons.analytics_rounded, "Analytics", 2), _buildSidebarItem(Icons.chat_bubble_rounded, "Complaints", 3), _buildSidebarItem(Icons.people_outline_rounded, "Users", 4), _buildSidebarItem(Icons.storage_rounded, "Data Management", 5), _buildSidebarItem(Icons.settings_suggest_rounded, "Settings", 6),
        ])),
        IconButton(icon: Icon(_isSidebarExtended ? Icons.arrow_back_ios_rounded : Icons.arrow_forward_ios_rounded, size: 16), onPressed: () => setState(() => _isSidebarExtended = !_isSidebarExtended)),
        const SizedBox(height: 16),
        Padding(padding: const EdgeInsets.only(bottom: 24), child: _buildSidebarItem(Icons.logout_rounded, "Logout", -1, isLogout: true)),
      ]),
    );
  }

  Widget _buildSidebarItem(IconData icon, String label, int index, {bool isLogout = false}) {
    final bool isSelected = _selectedIndex == index;
    return InkWell(
      onTap: () { if (isLogout) _showLogoutDialog(context); else { if (index == 0) _refreshAllStats(); setState(() => _selectedIndex = index); } },
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: isSelected ? BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(12)) : null,
        child: Row(children: [
          Icon(icon, color: isLogout ? Colors.red : (isSelected ? AppColors.tealText : Colors.grey.shade600)),
          if (_isSidebarExtended) ...[const SizedBox(width: 16), Text(label, style: TextStyle(color: isLogout ? Colors.red : (isSelected ? AppColors.tealText : Colors.grey.shade700), fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600, fontSize: 15))],
        ]),
      ),
    );
  }

  Widget _buildMobileDrawer() {
    return Drawer(child: Column(children: [
      UserAccountsDrawerHeader(
        decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF00BFA5), Color(0xFF009688)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        accountName: const Text("System Admin", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)), accountEmail: const Text("Barangay Balintawak, Lipa City"),
        currentAccountPicture: CircleAvatar(backgroundColor: Colors.white, child: const Icon(Icons.person, color: AppColors.tealText, size: 40)),
      ),
      _buildDrawerItem(Icons.person_add_alt_1_rounded, "User Management", () { Navigator.pop(context); setState(() => _selectedIndex = 4); }, color: const Color(0xFF9C27B0)),
      const Divider(), const Spacer(),
      _buildDrawerItem(Icons.logout_rounded, "Logout", () { Navigator.pop(context); _showLogoutDialog(context); }, color: Colors.red),
      const SizedBox(height: 20),
    ]));
  }

  Widget _buildDrawerItem(IconData icon, String title, VoidCallback onTap, {Color? color}) {
    return ListTile(leading: Icon(icon, color: color ?? Colors.grey.shade700), title: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color ?? Colors.grey.shade800)), onTap: onTap);
  }

  Widget _buildMainDashboard(bool isMobile, bool isTablet) {
    return RefreshIndicator(
      onRefresh: () async => _refreshAllStats(), color: const Color(0xFF00BFA5),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24), physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 1200), padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(isMobile ? "Admin Dashboard" : "Welcome Back, Admin", style: TextStyle(fontSize: isMobile ? 24 : 28, fontWeight: FontWeight.w900, color: const Color(0xFF1A1A1A), letterSpacing: -0.5)),
                  Text("Overview of Barangay Balintawak G-Tracker", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
                ])),
                if (!isMobile && !isTablet) Row(children: [
                  _buildHeaderIconButton(Icons.notifications_none_rounded, badgeCount: _unreadNotificationsCount > 0 ? _unreadNotificationsCount : null, onTap: () => _showNotificationsModal(context), isInAppBar: true),
                  const SizedBox(width: 12), const CircleAvatar(radius: 22, backgroundColor: Color(0xFFE0F2F1), child: Icon(Icons.person, color: AppColors.tealText)),
                ]),
              ]),
              const SizedBox(height: 32),
              _buildStatGrid(isMobile, isTablet),
              const SizedBox(height: 32),
              LayoutBuilder(builder: (context, c) {
                if (isMobile || isTablet) {
                  return Column(children: [_buildMapWidget(true), const SizedBox(height: 24), _buildSummarySection(), const SizedBox(height: 24), _buildFleetSection(), const SizedBox(height: 24), _buildActivityLogSection()]);
                } else {
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 2, child: Column(children: [_buildMapWidget(false), const SizedBox(height: 24), _buildAdminActionsGrid(false)])),
                    const SizedBox(width: 24),
                    Expanded(flex: 1, child: Column(children: [_buildSummarySection(), const SizedBox(height: 24), _buildActivityLogSection(), const SizedBox(height: 24), _buildFleetSection()])),
                  ]);
                }
              }),
              if (isMobile || isTablet) ...[const SizedBox(height: 24), _buildAdminActionsGrid(true)],
              const SizedBox(height: 48),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildStatGrid(bool isMobile, bool isTablet) {
    return GridView.count(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: (isMobile || isTablet) ? 2 : 4, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: (isMobile || isTablet) ? 1.2 : 1.5,
      children: [
        _buildModernStatCard("Active Trucks", "$_activeTrucks", Icons.local_shipping_rounded, const Color(0xFF43A047)),
        _buildModernStatCard("Pending Issues", "$_pendingComplaints", Icons.warning_amber_rounded, const Color(0xFFE53935), badge: _pendingComplaints > 0 ? "$_pendingComplaints" : null),
        _buildModernStatCard("Route Coverage", "${_coveragePercent.toInt()}%", Icons.map_rounded, const Color(0xFFFB8C00)),
        _buildModernStatCard("Total Residents", "$_residentsCount", Icons.people_alt_rounded, const Color(0xFF8E24AA)),
      ],
    );
  }

  Widget _buildModernStatCard(String title, String value, IconData icon, Color color, {String? badge}) {
    return Container(
      padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 15, offset: const Offset(0, 5))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 24)),
          if (badge != null) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: color.withAlpha(30), borderRadius: BorderRadius.circular(8)), child: Text(badge, style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 12))),
        ]),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }

  Widget _buildMapWidget(bool isMobile) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 20, offset: const Offset(0, 10))]),
      child: Column(children: [
        Padding(padding: const EdgeInsets.all(24), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [Container(width: 12, height: 12, decoration: const BoxDecoration(color: Color(0xFF00C853), shape: BoxShape.circle)), const SizedBox(width: 12), const Text("Live Fleet Monitoring", style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), fontSize: 18))]),
          TextButton.icon(onPressed: () => setState(() => _selectedIndex = 1), icon: const Icon(Icons.open_in_new_rounded, size: 16), label: const Text("FULL MAP", style: TextStyle(fontWeight: FontWeight.w900)), style: TextButton.styleFrom(foregroundColor: const Color(0xFF00BFA5), backgroundColor: const Color(0xFFE0F2F1), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
        ])),
        Container(height: isMobile ? 240 : 400, width: double.infinity, margin: const EdgeInsets.fromLTRB(24, 0, 24, 24), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: const Color(0xFFF8F9FA), border: Border.all(color: Colors.grey.shade200)), child: ClipRRect(borderRadius: BorderRadius.circular(20), child: MapboxView(mode: 'dashboard', onTap: () => setState(() => _selectedIndex = 1)))),
        Padding(padding: const EdgeInsets.only(bottom: 24), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [_buildModernLegendItem(const Color(0xFF00C853), "Active"), const SizedBox(width: 24), _buildModernLegendItem(const Color(0xFFFFAB00), "Idle"), const SizedBox(width: 24), _buildModernLegendItem(const Color(0xFF9E9E9E), "Offline")])),
      ]),
    );
  }

  Widget _buildModernLegendItem(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))), const SizedBox(width: 8), Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.grey.shade700))]);
  }

  Widget _buildActivityLogSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 20, offset: const Offset(0, 10))]),
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.history_rounded, color: Colors.orange, size: 24), SizedBox(width: 12), Text("Recent Activity", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))]),
        const SizedBox(height: 20),
        if (_recentLogs.isEmpty) const Center(child: Text("No recent activity logs", style: TextStyle(color: Colors.grey, fontSize: 13)))
        else Column(children: _recentLogs.take(5).map((log) => _buildRecentActivityItem(log)).toList()),
      ]),
    );
  }

  Widget _buildRecentActivityItem(Map<dynamic, dynamic> log) {
    final String type = (log['type'] ?? 'OTHER').toString().toUpperCase();
    final String message = (log['message'] ?? "System Event").toString();
    final String date = (log['date'] ?? "Just now").toString();
    IconData icon = Icons.info_outline_rounded; Color color = Colors.grey;
    switch (type) {
      case 'LOGIN': icon = Icons.login_rounded; color = const Color(0xFF4CAF50); break;
      case 'LOGOUT': icon = Icons.logout_rounded; color = const Color(0xFFF44336); break;
      case 'EXPORT': icon = Icons.download_rounded; color = const Color(0xFF2196F3); break;
      case 'UPDATE': icon = Icons.settings_rounded; color = const Color(0xFFFF9800); break;
    }
    return Padding(padding: const EdgeInsets.only(bottom: 16), child: Row(children: [
      Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color.withAlpha(20), shape: BoxShape.circle), child: Icon(icon, color: color, size: 14)),
      const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(message, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50)), maxLines: 1, overflow: TextOverflow.ellipsis), Text(date, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500))])),
    ]));
  }

  Widget _buildFleetSection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 20, offset: const Offset(0, 10))]),
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.local_shipping_rounded, color: Color(0xFF1976D2), size: 24), SizedBox(width: 12), Text("Fleet Overview", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))]),
        const SizedBox(height: 20),
        if (_fleetStatus.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Center(child: Text("No active fleet data", style: TextStyle(color: Colors.grey))))
        else Column(children: _fleetStatus.where((t) => t['isOnline'] == true).take(3).map((truck) => _buildModernFleetItem(truck)).toList()),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: TextButton(onPressed: () => setState(() => _selectedIndex = 1), child: const Text("VIEW ALL FLEET", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1)))),
      ]),
    );
  }

  Widget _buildModernFleetItem(Map<dynamic, dynamic> truck) {
    final String id = (truck['truck_id'] ?? "GT-001").toString();
    final String status = (truck['status'] ?? "Idle").toString().toUpperCase();
    final Color statusColor = status == 'ACTIVE' ? const Color(0xFF4CAF50) : const Color(0xFFFFAB00);
    return Container(
      margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade100)),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: statusColor.withAlpha(20), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.local_shipping_rounded, color: statusColor, size: 20)),
        const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(id, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))), Text(status, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w800))])),
        const Icon(Icons.chevron_right_rounded, color: Colors.grey),
      ]),
    );
  }

  Widget _buildSummarySection() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 20, offset: const Offset(0, 10))]),
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.insights_rounded, color: Color(0xFF009688), size: 24), SizedBox(width: 12), Text("Performance", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))]),
        const SizedBox(height: 24),
        _buildModernSummaryRow("Collection Progress", "$_completedRoutesToday / $_totalRoutesToday", _totalRoutesToday > 0 ? _completedRoutesToday / _totalRoutesToday : 0.0, const Color(0xFF1E88E5)),
        const SizedBox(height: 20),
        _buildModernSummaryRow("Complaint Resolution", "$_resolvedComplaints / $_totalComplaints", _totalComplaints > 0 ? _resolvedComplaints / _totalComplaints : 0.0, const Color(0xFF4CAF50)),
        const SizedBox(height: 24), const Divider(), const SizedBox(height: 12),
        _buildModernInfoRow("Average Speed", "${_averageSpeed.toStringAsFixed(1)} km/h"),
        const SizedBox(height: 12), _buildModernInfoRow("Active Hotspots", "$_activeHotspots Areas"),
      ]),
    );
  }

  Widget _buildModernSummaryRow(String label, String value, double progress, Color color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontWeight: FontWeight.w700)), Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13))]),
      const SizedBox(height: 10),
      ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: progress, backgroundColor: Colors.grey.shade100, valueColor: AlwaysStoppedAnimation<Color>(color), minHeight: 8)),
    ]);
  }

  Widget _buildModernInfoRow(String label, String value) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontWeight: FontWeight.w700)), Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14))]);
  }

  Widget _buildAdminActionsGrid(bool isMobile) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.only(left: 4, bottom: 16), child: Text("Quick Actions", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))),
      GridView.count(
        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: isMobile ? 2 : 3, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 1.1,
        children: [
          _buildModernActionCard("Analytics", Icons.bar_chart_rounded, const Color(0xFFE3F2FD), const Color(0xFF1E88E5), onTap: () => setState(() => _selectedIndex = 2)),
          _buildModernActionCard("Users", Icons.people_outline_rounded, const Color(0xFFF3E5F5), const Color(0xFF8E24AA), onTap: () => setState(() => _selectedIndex = 4)),
          _buildModernActionCard("Settings", Icons.settings_rounded, const Color(0xFFE8F5E9), const Color(0xFF43A047), onTap: () => setState(() => _selectedIndex = 6)),
        ],
      ),
    ]);
  }

  Widget _buildModernActionCard(String label, IconData icon, Color bgColor, Color iconColor, {VoidCallback? onTap}) {
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(24), child: Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 15, offset: const Offset(0, 5))]),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle), child: Icon(icon, color: iconColor, size: 28)),
        const SizedBox(height: 12), Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
      ]),
    ));
  }

  Widget _buildHeaderIconButton(IconData icon, {int? badgeCount, VoidCallback? onTap, bool isInAppBar = false}) {
    return GestureDetector(onTap: onTap, child: Stack(clipBehavior: Clip.none, children: [
      Container(width: 44, height: 44, decoration: BoxDecoration(color: isInAppBar ? Colors.white : Colors.white.withAlpha(180), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)), child: Icon(icon, color: const Color(0xFF1A1A1A), size: 22)),
      if (badgeCount != null) Positioned(right: -4, top: -4, child: Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Color(0xFFFF1744), shape: BoxShape.circle), child: Text("$badgeCount", style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)))),
    ]));
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 25, offset: const Offset(0, -5))]),
      child: BottomNavigationBar(
        currentIndex: _selectedIndex, type: BottomNavigationBarType.fixed, backgroundColor: Colors.white, selectedItemColor: const Color(0xFF00BFA5), unselectedItemColor: Colors.grey.shade500,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12), unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11), elevation: 0,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_rounded), label: 'Home'), BottomNavigationBarItem(icon: Icon(Icons.map_rounded), label: 'Track'), BottomNavigationBarItem(icon: Icon(Icons.analytics_rounded), label: 'Analytics'), BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_rounded), label: 'Issues'), BottomNavigationBarItem(icon: Icon(Icons.people_outline_rounded), label: 'Users'), BottomNavigationBarItem(icon: Icon(Icons.storage_rounded), label: 'Data'), BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
        onTap: (index) { if (index == 0) _refreshAllStats(); setState(() => _selectedIndex = index); },
      ),
    );
  }

  void _showNotificationsModal(BuildContext context) {
    showDialog(context: context, builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      child: Container(constraints: const BoxConstraints(maxWidth: 600), padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [const Icon(Icons.notifications_active_outlined, color: Color(0xFF00BFA5), size: 28), const SizedBox(width: 12), const Expanded(child: Text("Notifications", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))), TextButton(onPressed: () async { await _database.ref('notification_logs').remove(); if (mounted) Navigator.pop(context); }, child: const Text("Clear All", style: TextStyle(color: Color(0xFF00BFA5), fontWeight: FontWeight.w900)))]),
        const SizedBox(height: 24),
        Flexible(child: StreamBuilder(stream: _database.ref('notification_logs').onValue, builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data!.snapshot.exists) {
            final Map? data = snapshot.data!.snapshot.value as Map?;
            if (data == null) return const Center(child: Text("No notifications"));
            final List list = []; data.forEach((k, v) => list.add({...v as Map, 'id': k}));
            list.sort((a, b) => (b['timestamp'] ?? 0).compareTo(a['timestamp'] ?? 0));
            return ListView.separated(shrinkWrap: true, itemCount: list.length, separatorBuilder: (c, i) => const SizedBox(height: 12), itemBuilder: (c, i) => _buildNotificationItem(list[i]));
          }
          return const Center(child: Padding(padding: EdgeInsets.all(40), child: Text("All caught up!", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600))));
        })),
        const SizedBox(height: 32),
        ElevatedButton(onPressed: () => Navigator.pop(context), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A1A1A), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), child: const Text("CLOSE", style: TextStyle(fontWeight: FontWeight.w900))),
      ])),
    ));
  }

  Widget _buildNotificationItem(Map item) {
    final bool isRead = item['isRead'] ?? false;
    return InkWell(onTap: () => _database.ref('notification_logs/${item['id']}').update({'isRead': true}), child: Container(
      padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: isRead ? Colors.white : const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(16), border: Border.all(color: isRead ? Colors.grey.shade100 : const Color(0xFFDCFCE7))),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)), child: Icon(item['type'] == 'DRIVER_ISSUE' ? Icons.error_rounded : Icons.notifications_rounded, color: item['type'] == 'DRIVER_ISSUE' ? Colors.red : Colors.teal, size: 20)),
        const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item['title'] ?? 'Alert', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)), Text(item['message'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey.shade600))])),
        if (!isRead) Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
      ]),
    ));
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      child: Container(constraints: const BoxConstraints(maxWidth: 400), padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.logout_rounded, color: Colors.red, size: 48), const SizedBox(height: 24), const Text("Sign Out?", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)), const SizedBox(height: 12), Text("Are you sure you want to exit?", style: TextStyle(color: Colors.grey.shade600)), const SizedBox(height: 32),
        ElevatedButton(onPressed: () async { await SystemLogger.logEvent("LOGOUT", "Admin session ended"); await SessionManager.logout(); if (mounted) Navigator.pushReplacementNamed(context, '/'); }, style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), child: const Text("Sign Out", style: TextStyle(fontWeight: FontWeight.w900))),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel", style: TextStyle(color: Colors.black))),
      ])),
    ));
  }
}
