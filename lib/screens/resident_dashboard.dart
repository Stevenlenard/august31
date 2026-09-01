import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../utils/prediction_engine.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../utils/app_theme.dart';
import 'resident_track_truck_screen.dart';
import 'resident_complaints_screen.dart';
import 'resident_settings_screen.dart';
import '../widgets/mapbox_view.dart';
import '../widgets/fade_slide_entrance.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/header_circle_painter.dart';
import '../widgets/data_management_modal.dart';

class ResidentDashboard extends StatefulWidget {
  const ResidentDashboard({super.key});

  @override
  State<ResidentDashboard> createState() => _ResidentDashboardState();
}

class _ResidentDashboardState extends State<ResidentDashboard> with TickerProviderStateMixin {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  UserData? _user;
  geo.Position? _currentPosition;
  int _activeTrucks = 0;
  int _totalTrucks = 0;
  int _unreadNotificationsCount = 0;
  int _selectedIndex = 0;
  int _complaintsRefreshCount = 0;
  bool _shouldShowDataManagement = false;
  String _etaText = "--";
  String _currentTime = "";
  Timer? _clockTimer;

  StreamSubscription? _truckSubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _totalTruckSubscription;
  StreamSubscription? _userRealtimeSubscription;
  
  // Track proximity notification timestamps to avoid spamming
  final Map<String, DateTime> _sentProximityAlerts = {};

  // Header Animation
  late AnimationController _circleController;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _startClock();
    _getCurrentLocation();
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    geo.LocationPermission permission;

    serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) return;
    }
    
    if (permission == geo.LocationPermission.deniedForever) return;

    geo.Geolocator.getPositionStream().listen((pos) {
      if (mounted) setState(() => _currentPosition = pos);
    });

    try {
      geo.Position pos = await geo.Geolocator.getCurrentPosition();
      if (mounted) setState(() => _currentPosition = pos);
    } catch (_) {}
  }

  void _startClock() {
    _updateTime();
    _clockTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      _updateTime();
    });
  }

  void _updateTime() {
    final String time = DateFormat('hh:mm:ss a').format(DateTime.now());
    if (mounted && _currentTime != time) {
      setState(() {
        _currentTime = time;
      });
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _truckSubscription?.cancel();
    _notificationSubscription?.cancel();
    _totalTruckSubscription?.cancel();
    _userRealtimeSubscription?.cancel();
    _circleController.dispose();
    super.dispose();
  }

  void _loadUser() async {
    // 1. Get from arguments for instant display
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, dynamic>) {
        _user = UserData.fromJson(args);
      } else if (args is UserData) {
        _user = args;
      }

      // 2. Refresh from session
      final sessionUser = await SessionManager.getUser();
      if (sessionUser != null) {
        _user = sessionUser;
      }

      if (_user != null) {
        _setupListeners();
      }
      if (mounted) setState(() {});
    });
  }

  void _setupListeners() {
    _userRealtimeSubscription?.cancel();
    if (_user != null) {
      _userRealtimeSubscription = _database.ref('residents/${_user!.userId}').onValue.listen((event) {
        if (event.snapshot.exists) {
          final Map data = event.snapshot.value as Map;
          if (mounted) {
            setState(() {
              _user = _user!.copyWith(
                name: data['name']?.toString(),
                purok: data['purok']?.toString(),
                email: data['email']?.toString(),
                phone: data['phone']?.toString(),
                completeAddress: data['complete_address']?.toString(),
                profilePicture: data['profile_picture']?.toString(),
              );
            });
          }
        }
      });
    }

    _truckSubscription?.cancel();
    _truckSubscription = _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        int active = 0;
        double minEta = double.infinity;

        data.forEach((key, value) {
          final val = value as Map;
          final status = (val['status'] ?? '').toString().toUpperCase();
          if (val['isOnline'] == true && (status == 'ACTIVE' || status == 'COLLECTING' || status == 'IDLE')) {
            active++;

            // Calculate dynamic ETA if possible
            if (_currentPosition != null && val['latitude'] != null && val['longitude'] != null) {
              try {
                double dist = geo.Geolocator.distanceBetween(
                  _currentPosition!.latitude, _currentPosition!.longitude,
                  (val['latitude'] as num).toDouble(), (val['longitude'] as num).toDouble()
                ) / 1000.0;
                double speed = (val['speed'] ?? 15.0).toDouble();
                double eta = PredictionEngine.estimateArrivalTime(dist, [speed > 5 ? speed : 15.0]);
                if (eta < minEta) minEta = eta;
              } catch (_) {}
            }
          }
        });

        String etaDisplay = "--";
        if (active > 0) {
          etaDisplay = minEta != double.infinity ? "${minEta.toStringAsFixed(0)} mins" : "Approaching";
          
          // --- SMART PROXIMITY MONITORING ---
          if (minEta <= 10 && _user?.purok != null) {
            final String alertKey = "${_user!.userId}_proximity_${_user!.purok}";
            final lastAlert = _sentProximityAlerts[alertKey];
            
            // Only alert once every 30 mins for the same area
            if (lastAlert == null || DateTime.now().difference(lastAlert).inMinutes > 30) {
              _sentProximityAlerts[alertKey] = DateTime.now();
              _database.ref('notifications').push().set({
                'type': 'TRUCK_PROXIMITY',
                'title': 'Truck is Arriving!',
                'message': 'A garbage truck is approximately ${minEta.toStringAsFixed(0)} minutes away from ${_user!.purok}. Please prepare your trash.',
                'purok': _user!.purok,
                'timestamp': ServerValue.timestamp,
                'isRead': false,
              });
            }
          }
        }

        if (mounted) setState(() {
          _activeTrucks = active;
          _etaText = etaDisplay;
        });
      }
    });

    _totalTruckSubscription?.cancel();
    _totalTruckSubscription = _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        if (mounted) setState(() => _totalTrucks = data.length);
      }
    });

    _notificationSubscription?.cancel();
    _notificationSubscription = _database.ref('notifications').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map; int unread = 0;
        data.forEach((key, value) {
          final val = value as Map;
          if (val['isRead'] == false) {
             final String type = (val['type'] ?? '').toString();
             final String targetPurok = (val['purok'] ?? val['area'] ?? '').toString();
             final String residentId = (val['resident_id'] ?? '').toString();

             bool isRelevant = false;
             if (type == 'TRUCK_PROXIMITY' && (targetPurok == '' || targetPurok == _user?.purok)) {
               isRelevant = true;
             } else if (type == 'COMPLAINT_RESOLVED' && residentId == _user?.userId.toString()) {
               isRelevant = true;
             }

             if (isRelevant) unread++;
          }
        });
        if (mounted) setState(() => _unreadNotificationsCount = unread);
      }
    });
  }

  void _handleLogout() {
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
                onTap: () async {
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
              _HoverZoomLink(
                onTap: () => Navigator.pop(context),
                child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _viewProfilePicture() {
    if (_user == null) return;

    final String profileUrl = (_user!.profilePicture != null && _user!.profilePicture!.isNotEmpty)
        ? _user!.profilePicture!
        : "";

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "ProfilePicture",
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return GestureDetector(
          onTap: () => Navigator.pop(context),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Material(
              color: Colors.transparent,
              child: Center(
                child: Hero(
                  tag: 'profile_pic_${_user?.userId ?? 'default'}',
                  child: Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20, spreadRadius: 5)
                      ],
                      image: profileUrl.isNotEmpty
                          ? DecorationImage(
                              image: NetworkImage(profileUrl),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: profileUrl.isEmpty
                        ? Center(
                            child: Text(
                              (_user?.name != null && _user!.name.isNotEmpty) ? _user!.name[0].toUpperCase() : "U",
                              style: const TextStyle(fontSize: 80, fontWeight: FontWeight.bold, color: Color(0xFF00695C)),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.dashboardBg,
      extendBody: true, // Allow body to scroll behind the floating nav
      body: Stack(
        children: [
          IndexedStack(
            index: _selectedIndex,
            children: [
              FadeSlideEntrance(key: const ValueKey("home"), child: _buildHomeTab()),
              FadeSlideEntrance(
                key: const ValueKey("track"), 
                child: ResidentTrackTruckScreen(isEmbedded: true, onBack: () => setState(() => _selectedIndex = 0))
              ),
              FadeSlideEntrance(
                key: ValueKey("complaints_$_complaintsRefreshCount"), 
                child: ResidentComplaintsScreen(isEmbedded: true, onBack: () => setState(() => _selectedIndex = 0))
              ),
              FadeSlideEntrance(
                key: const ValueKey("settings"), 
                child: ResidentSettingsScreen(
                  isEmbedded: true, 
                  showDataManagementOnLoad: _shouldShowDataManagement,
                  onBack: () => setState(() {
                    _selectedIndex = 0;
                    _shouldShowDataManagement = false;
                  }), 
                  onProfileUpdate: _loadUser
                )
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomNav(),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return LayoutBuilder(builder: (context, constraints) {
      double width = constraints.maxWidth;
      bool isMobile = width < 600;

      return SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(children: [
          _buildHeader(isMobile),
          const SizedBox(height: 24), // Reduced spacing to bring stat cards closer

          FadeSlideEntrance(
            delay: const Duration(milliseconds: 300),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
              Expanded(child: _buildStatCard("Active Trucks", "$_activeTrucks / $_totalTrucks", Icons.local_shipping_rounded, AppColors.statActiveBg, isLive: true)),
              const SizedBox(width: 16),
              Expanded(child: _buildStatCard("Estimated Time", _etaText, Icons.access_time_filled_rounded, AppColors.statEtaBg)),
            ])),
          ),

          FadeSlideEntrance(
            delay: const Duration(milliseconds: 400),
            child: Column(children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: AppTheme.deepPulidongShadow,
                ),
                child: Column(children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.location_on_rounded, color: Color(0xFF2196F3))
                    ),
                    title: const Text("Live Tracking", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                    subtitle: const Text("Real-time truck locations", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                    trailing: _HoverZoomLink(
                      onTap: () => setState(() => _selectedIndex = 1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(12)),
                        child: const Text("Full Map", style: TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.w900, fontSize: 13))
                      ),
                    ),
                  ),
                  Container(
                    height: 250,
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 10, offset: const Offset(0, 5))]
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: MapboxView(mode: 'dashboard', onTap: () => setState(() => _selectedIndex = 1))
                    )
                  ),
                ]),
              ),
            ]),
          ),

          FadeSlideEntrance(
            delay: const Duration(milliseconds: 500),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: Text("Quick Actions", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              ),
              _buildActionCard("File Complaint", "Report collection issues", Icons.feedback_rounded, const Color(0xFFFFF0F2), const Color(0xFFFF1744)),
              const SizedBox(height: 8),
              _buildActionCard("Settings", "Manage your account and preferences", Icons.settings_rounded, const Color(0xFFE8EAF6), const Color(0xFF3F51B5)),
            ]),
          ),

          FadeSlideEntrance(
            delay: const Duration(milliseconds: 600),
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(32),
                boxShadow: AppTheme.deepPulidongShadow,
              ),
              child: Column(children: [
                Row(children: [
                  Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.calendar_today_rounded, color: Color(0xFF3F51B5), size: 20)),
                  const SizedBox(width: 16),
                  const Text("Collection Schedule", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 24),
                _buildScheduleRow("Frequency", _getDynamicFrequency(), isBadge: true),
                const SizedBox(height: 16),
                _buildScheduleRow("Time Window", "Collecting history", isBold: true),
                const SizedBox(height: 16),
                _buildScheduleRow("Your Area", (_user?.purok != null && _user!.purok!.isNotEmpty) ? _user!.purok! : "Area", icon: Icons.location_searching_rounded),
              ]),
            ),
          ),
          const SizedBox(height: 100),
        ]),
      );
    });
  }

  Widget _buildHeader(bool isMobile) {
    double bgHeight = isMobile ? 150 : 180;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 1. Green "Satin" Background
        Container(
          width: double.infinity,
          height: bgHeight,
          decoration: const BoxDecoration(
            color: Color(0xFF00695C),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          ),
          child: Stack(
            children: [
              AnimatedBuilder(
                animation: _circleController,
                builder: (context, child) {
                  return CustomPaint(
                    size: Size(double.infinity, bgHeight),
                    painter: HeaderCirclePainter(_circleController.value),
                  );
                },
              ),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 15, 24, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Minimalist Clock (Top Left) - Restored Size
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _currentTime,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                      // Action Icons (Top Right) - Restored Size
                      Row(
                        children: [
                          _buildHeaderActionIcon(
                            Icons.notifications_outlined,
                            badgeCount: _unreadNotificationsCount > 0 ? _unreadNotificationsCount : null,
                            onTap: () => _showNotificationsModal(context),
                          ),
                          const SizedBox(width: 12),
                          _buildHeaderActionIcon(
                            Icons.logout_rounded,
                            onTap: _handleLogout,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 2. Overlapping White Card
        Padding(
          padding: EdgeInsets.only(top: bgHeight - 70, left: 20, right: 20),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: AppTheme.pulidongShadow,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: _viewProfilePicture,
                      child: Hero(
                        tag: 'profile_pic_${_user?.userId ?? 'default'}',
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF00695C), width: 2),
                            image: (_user?.profilePicture != null && _user!.profilePicture!.isNotEmpty)
                                ? DecorationImage(
                                    image: NetworkImage(_user!.profilePicture!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: (_user?.profilePicture == null || _user!.profilePicture!.isEmpty)
                              ? Center(
                                  child: Text(
                                    (_user?.name != null && _user!.name.isNotEmpty) ? _user!.name[0].toUpperCase() : "U",
                                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF00695C)),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Welcome back,",
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _user?.name != null && _user!.name.isNotEmpty ? _user!.name : "Loading...",
                            style: const TextStyle(
                              color: Color(0xFF1A1A1A),
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.location_on_rounded, color: Color(0xFF00796B), size: 14),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _user?.purok != null && _user!.purok!.isNotEmpty ? _user!.purok! : "Detecting...",
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _HoverZoomLink(
                      onTap: () {
                        if (_user == null) return;
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => DataManagementModal(
                            user: _user!,
                            onSuccess: _loadUser,
                          ),
                        );
                      },
                      child: const Text(
                        "Edit",
                        style: TextStyle(
                          color: Color(0xFF00796B),
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                HoverActionButton(
                  text: "Track Live Truck",
                  onTap: () => setState(() => _selectedIndex = 1),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderActionIcon(IconData icon, {int? badgeCount, VoidCallback? onTap}) {
    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          if (badgeCount != null)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                  color: Color(0xFFFF5252),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  "$badgeCount",
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color bgColor, {bool isLive = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Icon(icon, color: isLive ? const Color(0xFF00796B) : const Color(0xFFFBC02D), size: 24),
          if (isLive) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: const Color(0xFF00796B), borderRadius: BorderRadius.circular(20)), child: const Text("Live", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900))),
        ]),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
      ]),
    );
  }

  Widget _buildActionCard(String title, String subtitle, IconData icon, Color bgColor, Color iconColor) {
    return _HoverZoomCard(
      onTap: () {
        if (title.contains("Track")) {
          setState(() => _selectedIndex = 1);
        } else if (title.contains("Settings")) {
          setState(() => _selectedIndex = 3);
        } else if (title.contains("Complaint")) {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => AddComplaintModal(onSuccess: () {
              setState(() {
                _complaintsRefreshCount++;
              });
            }),
          );
        } else {
          Navigator.pushNamed(context, '/file_complaint');
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: AppTheme.pulidongShadow,
        ),
        child: Row(children: [
          Container(width: 52, height: 52, decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)), child: Icon(icon, color: iconColor, size: 26)),
          const SizedBox(width: 20),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: Color(0xFF1A1A1A))),
            Text(subtitle, style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
          ])),
          const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFFE0E0E0), size: 16),
        ]),
      ),
    );
  }

  Widget _buildScheduleRow(String label, String value, {bool isBadge = false, bool isBold = false, IconData? icon}) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 14)),
      if (isBadge)
        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(20)), child: Text(value, style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w800, fontSize: 12)))
      else if (icon != null)
        Row(children: [Icon(icon, size: 14, color: const Color(0xFF3F51B5)), const SizedBox(width: 6), Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF3F51B5)))])
      else
        Text(value, style: TextStyle(fontWeight: isBold ? FontWeight.w900 : FontWeight.w700, fontSize: 14, color: const Color(0xFF1A1A1A))),
    ]);
  }

  Widget _buildBottomNav() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(40),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 30,
            offset: const Offset(0, 10),
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(0, Icons.home_rounded, 'Home'),
            _buildNavItem(1, Icons.location_on_rounded, 'Track'),
            _buildNavItem(2, Icons.chat_bubble_rounded, 'Complaints'),
            _buildNavItem(3, Icons.settings_suggest_rounded, 'Settings'),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    bool isSelected = _selectedIndex == index;
    return _HoverZoomLink(
      onTap: () {
        setState(() {
          _selectedIndex = index;
          if (index != 3) _shouldShowDataManagement = false;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00796B).withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon, 
              color: isSelected ? const Color(0xFF00796B) : const Color(0xFF9E9E9E), 
              size: 28
            ),
            if (isSelected) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF00796B),
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getDynamicFrequency() {
    if (_user?.purok == null || _user!.purok!.isEmpty) return "Weekly";
    final String p = _user!.purok!;
    if (p.contains("Sentro") || p.contains("Home Subdivision") || p.contains("Tanco")) return "Daily";
    return "Weekly";
  }

  void _showNotificationsModal(BuildContext context) {
    final GlobalKey<AnimatedListState> listKey = GlobalKey<AnimatedListState>();
    List<Map> notifications = [];

    // Mark all as read when opening modal
    _database.ref('notifications').once().then((DatabaseEvent event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        data.forEach((k, v) {
          final val = v as Map;
          final String type = (val['type'] ?? '').toString();
          final String targetPurok = (val['purok'] ?? val['area'] ?? '').toString();
          final String resId = (val['resident_id'] ?? '').toString();

          bool isRelevant = false;
          if (type == 'TRUCK_PROXIMITY' && (targetPurok == '' || targetPurok == _user?.purok)) isRelevant = true;
          else if (type == 'COMPLAINT_RESOLVED' && resId == _user?.userId.toString()) isRelevant = true;

          if (isRelevant && val['isRead'] == false) {
            _database.ref('notifications/$k').update({'isRead': true});
          }
        });
      }
    });

    showDialog(context: context, builder: (context) {
      return StatefulBuilder(builder: (context, setModalState) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          child: Container(
            clipBehavior: Clip.antiAlias,
            constraints: BoxConstraints(
              maxWidth: 450,
              maxHeight: MediaQuery.of(context).size.height * 0.6, // Maximum 60% of screen height for better fit
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(32),
            ),
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 24), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Row(children: [
                  const Icon(Icons.notifications_rounded, color: AppColors.tealText, size: 28),
                  const SizedBox(width: 12),
                  const Expanded(child: Text("System Notifications", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                  const SizedBox(width: 16),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 28),
                child: Divider(height: 32),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: StreamBuilder(
                  stream: _database.ref('notifications').onValue,
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data!.snapshot.exists) {
                      final Map data = snapshot.data!.snapshot.value as Map;
                      List<Map> newList = [];
                      data.forEach((k, v) {
                        final val = v as Map;
                        final String type = (val['type'] ?? '').toString();
                        final String targetPurok = (val['purok'] ?? val['area'] ?? '').toString();
                        final String residentId = (val['resident_id'] ?? '').toString();

                        bool isRelevant = false;
                        if (type == 'TRUCK_PROXIMITY' && (targetPurok == '' || targetPurok == _user?.purok)) {
                          isRelevant = true;
                        } else if (type == 'COMPLAINT_RESOLVED' && residentId == _user?.userId.toString()) {
                          isRelevant = true;
                        }

                        if (isRelevant) {
                          val['key'] = k;
                          newList.add(val);
                        }
                      });

                      newList.sort((a, b) => (b['timestamp'] ?? 0).compareTo(a['timestamp'] ?? 0));
                      notifications = newList;
                      
                      if (notifications.isEmpty) return _buildEmptyState();

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Recently received system notifications",
                                  style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)
                                ),
                                const SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: _HoverZoomLink(
                                    onTap: () async => _handleClearAllNotifications(notifications, listKey, setModalState),
                                    child: const Text("Clear All", style: TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.w800, fontSize: 14)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          Flexible(
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.symmetric(horizontal: 28),
                              child: AnimatedList(
                                key: listKey,
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                initialItemCount: notifications.length,
                                itemBuilder: (context, index, animation) {
                                  if (index >= notifications.length) return const SizedBox();
                                  return _buildDismissibleNotification(notifications[index], index, listKey, setModalState);
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    return _buildEmptyState();
                  },
                ),
              ),
            ]),
          ),
        );
      });
    });
  }

  Widget _buildEmptyState() {
    return Column(children: [
      const SizedBox(height: 48),
      const CircleAvatar(radius: 40, backgroundColor: Color(0xFFF5F5F5), child: Icon(Icons.notifications_rounded, size: 40, color: Colors.grey)),
      const SizedBox(height: 16),
      const Text("All caught up!", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey)),
      const SizedBox(height: 48),
    ]);
  }

  Future<void> _handleClearAllNotifications(List<Map> notifications, GlobalKey<AnimatedListState> listKey, StateSetter setModalState) async {
    if (notifications.isEmpty) return;
    
    bool confirmed = await _showConfirmDialog(
      title: "Clear All Notifications?",
      message: "Are you sure you want to permanently remove all your alerts?",
      icon: Icons.delete_sweep_rounded,
      isDestructive: true,
    );
    
    if (confirmed) {
      // Create a local copy to avoid list issues during async removal
      final List<Map> toRemove = List.from(notifications);
      for (int i = toRemove.length - 1; i >= 0; i--) {
        final removedItem = toRemove[i];
        final String key = removedItem['key'].toString();
        
        // 1. Database Removal FIRST
        await _database.ref('notifications/$key').remove();
        
        // 2. UI Removal SECOND
        if (i < notifications.length) {
          notifications.removeAt(i);
          listKey.currentState?.removeItem(
            i, 
            (context, animation) => _buildNotificationItem(removedItem, animation),
            duration: const Duration(milliseconds: 200),
          );
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
      _showSnackBar("Successful cleared all notifications");
      if (mounted) setModalState(() {});
    }
  }

  Widget _buildDismissibleNotification(Map item, int index, GlobalKey<AnimatedListState> listKey, StateSetter setModalState) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Dismissible(
        key: Key(item['key'].toString()),
        direction: DismissDirection.horizontal,
        confirmDismiss: (direction) async {
          return await _showConfirmDialog(
            title: "Delete Alert?",
            message: "This notification will be permanently removed from your list.",
            icon: Icons.delete_outline_rounded,
            isDestructive: true,
          );
        },
        onDismissed: (direction) {
          final String key = item['key'].toString();
          _database.ref('notifications/$key').remove(); // Permanent delete
          _showSnackBar("Successful delete notification");
        },
        background: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          decoration: BoxDecoration(
            color: Colors.red.shade50, 
            borderRadius: BorderRadius.circular(24)
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400),
        ),
        secondaryBackground: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          decoration: BoxDecoration(
            color: Colors.red.shade50, 
            borderRadius: BorderRadius.circular(24)
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400),
        ),
        child: _buildNotificationItem(item, const AlwaysStoppedAnimation(1.0)),
      ),
    );
  }

  Future<bool> _showConfirmDialog({required String title, required String message, required IconData icon, bool isDestructive = false}) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.redAccent, size: 48),
            const SizedBox(height: 24),
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5)),
            const SizedBox(height: 32),
            HoverActionButton(
              text: "Confirm", 
              isDestructive: isDestructive,
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 16),
            _HoverZoomLink(
              onTap: () => Navigator.pop(context, false), 
              child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15))
            ),
          ]),
        ),
      ),
    ) ?? false;
  }

  Widget _buildNotificationItem(Map item, Animation<double> animation) {
    final String type = (item['type'] ?? '').toString();
    
    return FadeTransition(
      opacity: animation,
      child: SizeTransition(
        sizeFactor: animation,
        child: _HoverZoomCard(
          onTap: () {
            Navigator.pop(context); // Close modal
            if (type == 'COMPLAINT_RESOLVED') {
              setState(() => _selectedIndex = 2); // Go to Complaints
            } else if (type == 'TRUCK_PROXIMITY') {
              setState(() => _selectedIndex = 1); // Go to Tracking
            }
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(4, 0, 4, 12), // Spacing from modal edges
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.grey.shade200, width: 1.5),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2F1), 
                  borderRadius: BorderRadius.circular(16)
                ),
                child: Icon(
                  type == 'COMPLAINT_RESOLVED' ? Icons.assignment_turned_in_rounded : Icons.local_shipping_rounded,
                  color: Color(0xFF00796B), 
                  size: 24
                ),
              ),
              title: Text(item['title'] ?? 'Alert', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(item['message'] ?? '', style: const TextStyle(fontSize: 13, color: Color(0xFF666666), fontWeight: FontWeight.w500, height: 1.4)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF00897B),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
