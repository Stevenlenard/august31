import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../utils/app_theme.dart';
import 'driver_settings_screen.dart';
import 'driver_track_truck_screen.dart';

import '../widgets/header_circle_painter.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';

class DriverDashboard extends StatefulWidget {
  const DriverDashboard({super.key});

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> with TickerProviderStateMixin {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  UserData? _user;
  String _status = "OFFLINE";
  String _startTime = "--:--";
  DateTime? _startDateTime;
  double _distance = 0.0;
  int _completedCount = 0;
  final int _totalPuroks = 13;
  int _selectedIndex = 0;
  bool _isPuroksExpanded = false;
  int _unreadNotifications = 0;
  bool _isSimulationMode = false;
  Timer? _simulationTimer;
  bool _isDebugPanelExpanded = false; // Collapsible Debug Panel
  String _currentTime = "";
  Timer? _clockTimer;
  Map<String, dynamic> _maintenanceData = {};
  String? _truckPlateNumber;
  StreamSubscription? _truckSubscription;
  StreamSubscription? _userSubscription;

  // Header Animation
  late AnimationController _circleController;

  // DEVELOPER TEST OVERRIDE
  String _testStatusOverride = "AUTO"; // AUTO, FORCE ACTIVE, FORCE IDLE, FORCE FULL

  final List<Map<String, dynamic>> _purokConfigs = [
    {"name": "Purok 1", "lat": 13.9450, "lng": 121.1650},
    {"name": "Purok 2", "lat": 13.9440, "lng": 121.1640},
    {"name": "Purok 3", "lat": 13.9430, "lng": 121.1630},
    {"name": "Purok 4", "lat": 13.9420, "lng": 121.1620},
    {"name": "Dos Riles", "lat": 13.9410, "lng": 121.1610},
    {"name": "Sentro", "lat": 13.9400, "lng": 121.1600},
    {"name": "San Isidro", "lat": 13.9390, "lng": 121.1590},
    {"name": "Paraiso", "lat": 13.9380, "lng": 121.1580},
    {"name": "Riverside", "lat": 13.9370, "lng": 121.1570},
    {"name": "Kalaw Street", "lat": 13.9360, "lng": 121.1560},
    {"name": "Home Subdivision", "lat": 13.9350, "lng": 121.1550},
    {"name": "Tanco Road / Ayala Highway", "lat": 13.9340, "lng": 121.1540},
    {"name": "Brixton Area", "lat": 13.9330, "lng": 121.1530},
  ];

  Map<String, dynamic> _purokStatus = {};

  // Tracking & Session
  StreamSubscription<Position>? _positionSubscription;
  Position? _currentPosition;
  String? _sessionId;
  DateTime? _lastGpsUpdateTime;
  Timer? _idleDetectionTimer;
  bool _isInitializing = true;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _purokStatusSubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _routePointsSubscription;

  List<Map> _tripRoutePoints = [];
  List<Map>? _debugTestRoute; // NEW: For web testing

  @override
  void initState() {
    super.initState();
    _loadUser();
    _startClock();
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();
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
    _userSubscription?.cancel();
    _truckSubscription?.cancel();
    _clockTimer?.cancel();
    _simulationTimer?.cancel();
    _positionSubscription?.cancel();
    _idleDetectionTimer?.cancel();
    _statusSubscription?.cancel();
    _purokStatusSubscription?.cancel();
    _notificationSubscription?.cancel();
    _routePointsSubscription?.cancel();
    _circleController.dispose();
    super.dispose();
  }

  bool _isRestoringSession = false;

  void _loadUser() async {
    if (!mounted) return;
    
    debugPrint("========== LOGIN SUCCESS AT: ${DateTime.now()} ==========");

    // 1. Resolve Driver ID immediately from session (Fastest)
    _user = await SessionManager.getUser();
    if (_user == null) {
       debugPrint("ERROR: No user found in SessionManager");
       return;
    }
    
    final String driverIdStr = _user!.userId.toString();
    final String truckId = _user?.preferredTruck ?? "Unknown";
    debugPrint("DRIVER RESOLVED AT: ${DateTime.now()} (ID: $driverIdStr, Truck: $truckId)");

    if (mounted) {
      setState(() {
        _isInitializing = true;
        _isRestoringSession = true;
        _startTime = "Restoring...";
        _status = "ACTIVE"; // Immediate operational status
      });
    }

    // 2. Update online presence in Firebase IMMEDIATELY
    // This ensures the status listener (started in step 3) sees ACTIVE, not a stale IDLE.
    await _database.ref('truck_locations').child(truckId).update({
      'isOnline': true,
      'status': 'ACTIVE',
      'lastSeen': ServerValue.timestamp,
      'driver_id': _user?.userId,
      'driver_name': _user?.name,
    });
    debugPrint("ACTIVE STATUS WRITTEN AT: ${DateTime.now()}");

    // 3. Start essential listeners
    _setupUserListener();
    _loadMaintenanceData(truckId);
    _setupTruckListener();
    _setupListeners();
    
    // 4. Start GPS acquisition in the background
    _startTracking();
    debugPrint("GPS INIT START: ${DateTime.now()}");

    // 5. Restore unfinished trip if it exists (AWAIT THIS)
    await _restoreTripSession(truckId, driverIdStr);
    
    if (mounted) {
      setState(() {
        _isInitializing = false;
        _isRestoringSession = false;
      });
    }
    debugPrint("========== INITIALIZATION COMPLETE AT: ${DateTime.now()} ==========");
  }

  Future<void> _restoreTripSession(String truckId, String driverIdStr) async {
    debugPrint("[SESSION] UNFINISHED TRIP QUERY START: ${DateTime.now()}");
    
    String? existingSessionId;
    Map? activeRouteData;

    // 1. Check Driver document first (Most reliable persistent reference)
    try {
      final userSnap = await _database.ref('users/$driverIdStr').get();
      if (userSnap.exists && userSnap.value != null) {
        final uData = userSnap.value as Map;
        if (uData['current_trip_id'] != null) {
          final String pointerId = uData['current_trip_id'].toString();
          debugPrint("[SESSION] Found current_trip_id in user doc: $pointerId");
          
          final routeSnap = await _database.ref('driver_routes/$pointerId').get();
          if (routeSnap.exists && routeSnap.value != null) {
            final rData = routeSnap.value as Map;
            
            // SECURITY: Ensure this session belongs to THIS driver
            final String sessionDriverId = (rData['driver_id'] ?? '').toString();
            bool isMySession = (sessionDriverId == driverIdStr || rData['driver_id'] == _user?.userId);

            // Check if it's actually ACTIVE
            bool isActive = rData['route_status'] == 'ACTIVE' || (rData['isFinished'] == false && rData['finishTime'] == null);
            
            if (isMySession && isActive) {
              existingSessionId = pointerId;
              activeRouteData = rData;
              debugPrint("[SESSION] Driver doc recovery successful: $existingSessionId (FIREBASE START TIME: ${activeRouteData['start_time']})");
            }
          }
        }
      }
    } catch (e) {
      debugPrint("[SESSION] Driver doc recovery error: $e");
    }

    // 2. Check truck_locations second (Direct path, NO INDEX NEEDED)
    if (existingSessionId == null) {
      try {
        final locSnap = await _database.ref('truck_locations/$truckId').get();
        if (locSnap.exists && locSnap.value != null) {
          final lData = locSnap.value as Map;
          if (lData['current_session'] != null) {
            final String pointerId = lData['current_session'].toString();
            debugPrint("[SESSION] Found current_session pointer: $pointerId");
            
            final routeSnap = await _database.ref('driver_routes/$pointerId').get();
            if (routeSnap.exists && routeSnap.value != null) {
              final rData = routeSnap.value as Map;
              
              // SECURITY: Ensure this session belongs to THIS driver
              final String sessionDriverId = (rData['driver_id'] ?? '').toString();
              bool isMySession = (sessionDriverId == driverIdStr || rData['driver_id'] == _user?.userId);

              // Check if it's actually ACTIVE
              bool isActive = rData['route_status'] == 'ACTIVE' || (rData['isFinished'] != true && rData['finishTime'] == null);
              
              if (isMySession && isActive) {
                existingSessionId = pointerId;
                activeRouteData = rData;
                debugPrint("[SESSION] Primary recovery successful: $existingSessionId (FIREBASE START TIME: ${activeRouteData['start_time']})");
              }
            }
          }
        }
      } catch (e) {
        debugPrint("[SESSION] Primary recovery error: $e");
      }
    }

    // 3. Fallback: Query driver_routes for ANY ACTIVE trip for this driver
    if (existingSessionId == null) {
      try {
        debugPrint("[SESSION] Falling back to query driver_routes...");
        final routesRef = _database.ref('driver_routes');
        
        // Try both integer and string IDs (Firebase is type-sensitive)
        final List<DataSnapshot> snapshots = [];
        snapshots.add(await routesRef.orderByChild('driver_id').equalTo(_user?.userId).get());
        snapshots.add(await routesRef.orderByChild('driver_id').equalTo(driverIdStr).get());
        
        int latestTimestamp = 0;
        for (var snapshot in snapshots) {
          if (snapshot.exists && snapshot.value != null) {
            final Map routes = snapshot.value as Map;
            routes.forEach((key, value) {
              final String status = (value['route_status'] ?? '').toString();
              final bool isFinished = value['isFinished'] == true || value['finishTime'] != null;

              if (status == 'ACTIVE' && !isFinished) {
                int ts = (value['server_start_time'] ?? value['timestamp'] ?? 0) as int;
                if (ts > latestTimestamp) {
                  latestTimestamp = ts;
                  existingSessionId = key.toString();
                  activeRouteData = value as Map;
                }
              }
            });
          }
        }
      } catch (e) {
        debugPrint("[SESSION] Fallback query failed: $e");
      }
    }

    debugPrint("[SESSION] UNFINISHED TRIP QUERY END: ${DateTime.now()}");
    debugPrint("TRIP FOUND: ${existingSessionId != null}");

    if (existingSessionId != null) {
      _sessionId = existingSessionId;
      if (activeRouteData != null && mounted) {
        final String restoredStartTime = activeRouteData!['start_time'] ?? "--:--";
        debugPrint("LOCAL RESTORED START TIME: $restoredStartTime");
        
        setState(() {
          _startTime = restoredStartTime;
          _distance = (activeRouteData!['total_distance'] ?? 0.0).toDouble();
          
          if (activeRouteData!['server_start_time'] != null) {
            _startDateTime = DateTime.fromMillisecondsSinceEpoch(activeRouteData!['server_start_time'] as int);
          } else if (activeRouteData!['timestamp'] != null) {
            _startDateTime = DateTime.fromMillisecondsSinceEpoch(activeRouteData!['timestamp'] as int);
          }
        });
        debugPrint("FINAL UI START TIME: $_startTime");
      }
      
      // Force sync the CORRECT original Start Time to the live node and user doc
      await _database.ref('users/$driverIdStr').update({'current_trip_id': _sessionId});
      await _database.ref('truck_locations').child(truckId).update({
        'current_session': _sessionId,
        'start_time': _startTime,
        'distance': _distance,
      });

      _setupPurokListener();
      _setupRoutePointsListener();
      _startIdleDetection();
    } else {
      debugPrint("[LIFECYCLE] No unfinished trip found. Creating new trip to ensure ACTIVE status.");
      // Auto-start new trip if none found - Satisfies Test 5 requirement
      await _startTripSession();
    }
  }

  void _loadMaintenanceData(String truckId) async {
    final ref = _database.ref('trucks/$truckId/maintenance');
    // We listen to it live so we have the latest flags and values
    ref.onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        if (mounted) {
          setState(() {
            _maintenanceData = Map<String, dynamic>.from(event.snapshot.value as Map);
          });
        }
      }
    });
  }

  void _setupUserListener() {
    if (_user == null) return;
    _userSubscription?.cancel();
    
    // Using current user ID
    _userSubscription = _database.ref('users/${_user!.userId}').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        
        if (mounted) {
          setState(() {
            // Merge Firebase data with current user object to avoid losing fields
            final Map<String, dynamic> currentData = _user!.toJson();
            data.forEach((k, v) => currentData[k] = v);
            final updatedUser = UserData.fromJson(currentData);
            
            // Update local state and restart truck listener if truck ID changed
            if (_user?.preferredTruck != updatedUser.preferredTruck) {
              _user = updatedUser;
              _setupTruckListener();
              _setupListeners();
            } else {
              _user = updatedUser;
            }
          });
        }
      }
    });
  }

  void _setupTruckListener() {
    _truckSubscription?.cancel();
    final truckId = _user?.preferredTruck ?? "Unknown";

    _truckSubscription = _database.ref('trucks/$truckId').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = event.snapshot.value as Map;
        if (mounted) {
          setState(() {
            _truckPlateNumber = data['plateNumber']?.toString() ?? "N/A";
          });
        }
      }
    });
  }

  void _setupListeners() {
    final truckId = _user?.preferredTruck ?? "Unknown";
    _statusSubscription?.cancel();
    _statusSubscription = _database.ref('truck_locations').child(truckId).onValue.listen((event) {
      if (event.snapshot.exists) {
        final data = event.snapshot.value as Map;
        final String remoteStatus = data['status']?.toString().toUpperCase() ?? "OFFLINE";
        
        if (mounted) {
          debugPrint("STATUS UPDATE FROM FIREBASE: $remoteStatus (Current Local: $_status)");
          
          // During initialization, don't let a stale OFFLINE or IDLE from Firebase 
          // overwrite our local ACTIVE status.
          if (_isInitializing && (remoteStatus == "OFFLINE" || remoteStatus == "IDLE")) {
             debugPrint("   -> IGNORING STALE STATUS DURING INITIALIZATION");
             return;
          }

          setState(() {
            _status = remoteStatus;
            // AUTHORITATIVE: Distance and Start Time are managed by the Driver app locally
            // and synced TO Firebase history, avoiding overwriting with stale data on re-login.
          });
        }
      }
    });

    _notificationSubscription?.cancel();
    
    // Track dashboard load time to avoid showing historical alerts as real-time popups
    final int dashboardLoadTime = DateTime.now().millisecondsSinceEpoch;

    _notificationSubscription = _database.ref('notifications').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        int unread = 0;
        
        // Debug counters
        int matched = 0;
        int adminExcluded = 0;
        int residentExcluded = 0;
        int otherDriverExcluded = 0;

        data.forEach((k, v) {
          final val = v as Map;
          bool forMe = _isNotificationForMe(val);
          
          if (forMe) {
            matched++;
            if (val['isRead'] == false) {
              unread++;
              
              // NEW: Trigger real-time SnackBar if it's a NEW notification while dashboard is open
              final int ts = (val['timestamp'] ?? 0) as int;
              if (ts > dashboardLoadTime && val['realtimeTriggered'] != true) {
                // Mark locally as triggered to avoid duplicates in the same session
                val['realtimeTriggered'] = true; 
                _showSnackBar("${val['title']}: ${val['message']}");
              }
            }
          } else {
            // Determine exclusion reason for debug
            final String type = (val['type'] ?? '').toString();
            if (['REGISTRATION', 'NEW_REGISTRATION', 'RESIDENT_COMPLAINT'].contains(type)) {
              adminExcluded++;
            } else if (['auto_arrival', 'auto_approach', 'manual_alert', 'COLLECTION_ALERT', 'COMPLAINT_RESOLVED'].contains(type)) {
              residentExcluded++;
            } else {
              otherDriverExcluded++;
            }
          }
        });

        debugPrint("--- DRIVER NOTIFICATION DEBUG ---");
        debugPrint("CURRENT DRIVER ID: ${_user?.userId}");
        debugPrint("ASSIGNED TRUCK: ${_user?.preferredTruck}");
        debugPrint("RAW NOTIFICATIONS: ${data.length}");
        debugPrint("DRIVER MATCHED: $matched");
        debugPrint("EXCLUDED ADMIN: $adminExcluded");
        debugPrint("EXCLUDED RESIDENT: $residentExcluded");
        debugPrint("EXCLUDED OTHER DRIVER: $otherDriverExcluded");
        debugPrint("FINAL DRIVER ALERT COUNT: $matched (Unread: $unread)");
        debugPrint("---------------------------------");

        if (mounted) {
          setState(() => _unreadNotifications = unread);
        }
      }
    });

    // --- NEW: CONNECTION RECOVERY LOGIC ---
    _database.ref('.info/connected').onValue.listen((event) {
      final bool isConnected = event.snapshot.value == true;
      if (isConnected && _sessionId != null && _user != null) {
        debugPrint("[CONNECTION] Reconnected. Restoring active status...");
        // If we have an active session, ensure we are ACTIVE and Online
        _database.ref('truck_locations').child(_user?.preferredTruck ?? "Unknown").update({
           'isOnline': true,
           'status': (_status.contains("LOST") || _status == "OFFLINE") ? "ACTIVE" : _status,
           'updatedAt': DateTime.now().toIso8601String(),
        });
        if (mounted) {
          setState(() {
            if (_status.contains("LOST") || _status == "OFFLINE") {
              _status = "ACTIVE";
            }
          });
        }
      } else if (!isConnected && _status != "OFFLINE") {
        debugPrint("[CONNECTION] Lost. Setting local status to IDLE.");
        if (mounted) setState(() => _status = "IDLE (LOST)");
      }
    });
  }

  void _setupRoutePointsListener() {
    if (_sessionId == null) {
      return;
    }
    _routePointsSubscription?.cancel();
    _routePointsSubscription = _database.ref('driver_routes/$_sessionId/route').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List<Map> list = [];
        data.forEach((k, v) => list.add(v as Map));
        list.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
        
        debugPrint("[LIFECYCLE] RESTORED ROUTE POINT COUNT: ${list.length}");
        
        if (mounted) setState(() => _tripRoutePoints = list);
      }
    });
  }

  void _setupPurokListener() {
    if (_sessionId == null) {
      return;
    }
    _purokStatusSubscription?.cancel();
    _purokStatusSubscription = _database.ref('collection_progress').child(_sessionId!).onValue.listen((event) {
      if (event.snapshot.exists) {
        final data = event.snapshot.value as Map;
        int completed = 0;
        data.forEach((key, value) {
          if (value['completed'] == true) completed++;
        });
        
        debugPrint("[LIFECYCLE] RESTORED PROGRESS: $completed");

        if (mounted) {
          setState(() {
            _purokStatus = Map<String, dynamic>.from(data);
            _completedCount = completed;
          });
          final truckId = _user?.preferredTruck ?? "Unknown";
          _database.ref('truck_locations').child(truckId).update({
            'visited_puroks': completed,
            'efficiency': (completed / _totalPuroks) * 100,
          });
        }
      }
    });
  }

  // --- TRIP LOGIC ---

  Future<void> _startTripSession() async {
    debugPrint("[SESSION] _startTripSession called. current session Id: $_sessionId");
    
    // PREVENT DUPLICATE TRIPS: If a session already exists, do not create another.
    if (_sessionId != null) {
      debugPrint("[SESSION] WARNING: _startTripSession called but session Id already exists ($_sessionId). Ignoring.");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return;
      }
    }

    final truckId = _user?.preferredTruck ?? "Unknown";
    final driverId = _user?.userId ?? "Unknown";

    try {
      debugPrint("[SESSION] Requesting current position for new trip...");
      Position startPos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.bestForNavigation);
      debugPrint("[SESSION] Start position obtained: ${startPos.latitude}, ${startPos.longitude}");

      _sessionId = _database.ref('driver_routes').push().key;
      debugPrint("START TIME WRITE: NEW TRIP CREATED. ID: $_sessionId");
      
      // Authoritative persistent reference in the Driver's own document
      await _database.ref('users/$driverId').update({
        'current_trip_id': _sessionId,
      });

      _startDateTime = DateTime.now();
      String timeStr = DateFormat('h:mm a').format(_startDateTime!);
      debugPrint("[SESSION] New Start Time generated: $timeStr");

      debugPrint("[SESSION] Writing new session data to Firebase...");
      await _database.ref('truck_locations').child(truckId).update({
        'status': 'ACTIVE',
        'isOnline': true,
        'driver_id': driverId,
        'driver_name': _user?.name ?? 'Driver',
        'plate_number': _truckPlateNumber,
        'start_time': timeStr,
        'server_start_time': ServerValue.timestamp,
        'latitude': startPos.latitude,
        'longitude': startPos.longitude,
        'distance': 0.0,
        'speed': 0.0,
        'avg_speed': 0.0,
        'efficiency': 0.0,
        'accuracy': startPos.accuracy,
        'lastSeen': ServerValue.timestamp,
        'updatedAt': DateTime.now().toIso8601String(),
        'current_session': _sessionId,
      });

      _database.ref('truck_locations').child(truckId).onDisconnect().update({
        'status': 'IDLE', // Mark as IDLE if app is killed or signal lost
        'isOnline': false,
        'lastSeen': ServerValue.timestamp,
      });

      await _database.ref('driver_routes').child(_sessionId!).set({
        'truck_id': truckId,
        'driver_id': driverId,
        'driver_name': _user?.name ?? 'Driver',
        'start_time': timeStr,
        'server_start_time': ServerValue.timestamp, // PERSISTENCE: Actual timestamp
        'total_distance': 0.0, // PERSISTENCE: Track distance here too
        'route_status': 'ACTIVE',
        'isOnline': true,
        'timestamp': ServerValue.timestamp,
        'date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
        'maintenanceProcessed': false,
        'start_lat': startPos.latitude,
        'start_lng': startPos.longitude,
        'start_accuracy': startPos.accuracy,
      });
      debugPrint("[SESSION] Firebase write complete for new trip.");

      Map<String, dynamic> initialProgress = {};
      for (int i = 0; i < _purokConfigs.length; i++) {
        final p = _purokConfigs[i];
        initialProgress[p['name'].replaceAll('/', '_')] = {
          'name': p['name'],
          'lat': p['lat'],
          'lng': p['lng'],
          'completed': false,
          'order': i,
        };
      }
      await _database.ref('collection_progress').child(_sessionId!).set(initialProgress);

      // CRITICAL: First route point must be EXACTLY the start point
      _appendRoutePoint(startPos, "ACTIVE", "GREEN");

      if (mounted) {
        setState(() {
          _status = "ACTIVE";
          _startTime = timeStr;
          _distance = 0.0;
          _currentPosition = startPos;
          _lastGpsUpdateTime = DateTime.now();
          _completedCount = 0; // Reset count locally
          _purokStatus = {}; // Clear previous trip progress
          _autoNotifiedPuroks.clear(); 
          _approachNotifiedPuroks.clear();
        });
      }
      _setupPurokListener();
      _setupRoutePointsListener();
      _startTracking();
      _startIdleDetection();
    } catch (e) {
      // Error handling
    }
  }

  void _startTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation, 
        distanceFilter: 0, // 0 for max sensitivity during tests
      ),
    ).listen((pos) => _processNewPosition(pos));
  }

  void _processNewPosition(Position pos) {
    if (_sessionId == null || _status == "OFFLINE" || _status == "FINISHED") return;
    
    // GPS FIX LOG
    if (_currentPosition == null) {
      debugPrint("GPS FIRST FIX: ${pos.latitude}, ${pos.longitude} AT: ${DateTime.now()}");
    }
    // Reject extremely poor accuracy readings (e.g., 20000m)
    if (pos.accuracy > 50 && !_isSimulationMode) {
      debugPrint("[GPS FILTER] Rejected point due to poor accuracy: ${pos.accuracy}m");
      return;
    }

    final truckId = _user?.preferredTruck ?? "Unknown";
    
    double traveled = 0;

    if (_currentPosition != null) {
      // Calculate real distance walked/traveled between consecutive points
      traveled = Geolocator.distanceBetween(
        _currentPosition!.latitude, 
        _currentPosition!.longitude, 
        pos.latitude, 
        pos.longitude
      ) / 1000.0; // convert to km
      
      // Filter out micro-jitter (less than 2 meters)
      if (traveled < 0.002) {
        traveled = 0;
      }
    }

    _lastGpsUpdateTime = DateTime.now();
    double speedKmH = (pos.speed * 3.6);

    // 1. GPS NOISE FILTERING
    bool isAccurate = pos.accuracy < 35.0; // Reject points with > 35m error
    bool movedFarEnough = traveled > 0.003; // Must move at least 3 meters (Walking speed friendly)

    // Debug raw vs accepted
    debugPrint("[GPS MASTER] RAW: ${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)} | ACC: ${pos.accuracy.toStringAsFixed(1)}m | SPEED: ${speedKmH.toStringAsFixed(1)}km/h");

    if (!isAccurate && !_isSimulationMode) {
      debugPrint("[GPS REJECTED] Poor Accuracy: ${pos.accuracy.toStringAsFixed(1)}m");
      return;
    }

    if (mounted) {
      setState(() {
        if (movedFarEnough || _currentPosition == null || _isSimulationMode) {
          _distance += traveled;
          _currentPosition = pos;
          debugPrint("[GPS MASTER] ACCEPTED: ${pos.latitude}, ${pos.longitude}");
          _checkMaintenanceThresholds();
        } else {
          debugPrint("[GPS MASTER] FILTERED (Stationary): moved ${traveled * 1000}m");
        }
        
        // Auto-status logic (Only if not overridden)
        if (_testStatusOverride == "AUTO") {
          if (speedKmH > 1.2 && _status == "IDLE") {
            _updateTripStatus("ACTIVE");
          }
        }
      });
    }

    _checkPurokProximity(pos);

    double avgSpeed = 0.0;
    if (_startDateTime != null) {
      final durationHrs = DateTime.now().difference(_startDateTime!).inSeconds / 3600.0;
      if (durationHrs > 0) {
        avgSpeed = _distance / durationHrs;
      }
    }

    // Determine Status for this specific point (respecting override)
    String effectiveStatus = _getEffectiveRouteStatus();
    String trailColor = _getTrailColorForStatus(effectiveStatus);

    _database.ref('truck_locations').child(truckId).update({
      'truck_id': truckId, // NEW: Include ID in the node data
      'latitude': pos.latitude,
      'longitude': pos.longitude,
      'distance': _distance,
      'speed': speedKmH,
      'avg_speed': avgSpeed,
      'heading': pos.heading,
      'accuracy': pos.accuracy,
      'status': effectiveStatus, 
      'isOnline': true,
      'plate_number': _truckPlateNumber,
      'lastSeen': ServerValue.timestamp,
      'updatedAt': DateTime.now().toIso8601String(),
    });

    // Persistent trip distance update
    if (_sessionId != null) {
      _database.ref('driver_routes').child(_sessionId!).update({
        'total_distance': _distance,
        'last_lat': pos.latitude,
        'last_lng': pos.longitude,
        'last_seen': ServerValue.timestamp,
      });
    }

    if (movedFarEnough || _tripRoutePoints.isEmpty || _isSimulationMode) {
      _appendRoutePoint(pos, effectiveStatus, trailColor);
    }
  }

  String _getEffectiveRouteStatus() {
    if (_testStatusOverride != "AUTO") {
      return _testStatusOverride.replaceFirst("FORCE ", "");
    }
    // Normalize status for route points
    if (_status.contains("IDLE")) return "IDLE";
    if (_status.contains("FULL")) return "FULL";
    if (_status.contains("FINISHED")) return "FINISHED";
    return "ACTIVE";
  }

  String _getTrailColorForStatus(String status) {
    switch (status.toUpperCase()) {
      case "IDLE": return "YELLOW";
      case "FULL": return "PINK";
      case "FINISHED": return "BLACK";
      default: return "GREEN";
    }
  }

  void _checkPurokProximity(Position pos) {
    if (_sessionId == null) {
      return;
    }
    
    // STRICTER GPS PROXIMITY: Only trigger if accuracy is good
    if (pos.accuracy > 50 && !_isSimulationMode) {
      debugPrint("[PROXIMITY] Skipping due to poor accuracy: ${pos.accuracy}");
      return;
    }

    for (var p in _purokConfigs) {
      String key = p['name'].replaceAll('/', '_');
      
      double dist = Geolocator.distanceBetween(pos.latitude, pos.longitude, p['lat'], p['lng']);

      // --- NEW: APPROACH DETECTION (300 meters) ---
      if (dist <= 300 && dist > 50) {
        _handleApproachNotification(p['name'], dist);
      }
      
      // Already completed in this session? Skip completion logic.
      if (_purokStatus[key]?['completed'] == true) {
        continue;
      }
      
      // Logic: Must be within 50 meters AND moving slowly (or simulation)
      bool speedValid = _isSimulationMode || (pos.speed * 3.6) < 15.0; 

      if (dist <= 50 && speedValid) {
        _database.ref('collection_progress').child(_sessionId!).child(key).update({
          'completed': true,
          'completedAt': DateFormat('h:mm a').format(DateTime.now()),
          'timestamp': ServerValue.timestamp,
          'completionSource': _isSimulationMode ? 'SIMULATION' : 'GPS_PROXIMITY',
          'accuracyAtTrigger': pos.accuracy,
          'distanceToCenter': dist,
        });
        
        _database.ref('truck_locations').child(_user?.preferredTruck ?? "Unknown").update({'current_purok': p['name']});
        
        // --- NEW: Automatic Approach/Arrival Notifications ---
        _handleAutoNotifications(p['name'], dist);
        
        debugPrint("[PROXIMITY] Triggered for ${p['name']} at dist: ${dist.toStringAsFixed(1)}m");
      }
    }
  }

  final Set<String> _autoNotifiedPuroks = {};

  void _handleAutoNotifications(String areaName, double distance) async {
    if (_autoNotifiedPuroks.contains(areaName)) {
      return;
    }
    
    final truckId = _user?.preferredTruck ?? "Unknown";
    
    // 1. Send "Arrived" notification to Firebase
    await _database.ref('notifications').push().set({
      'type': 'auto_arrival',
      'title': 'Garbage Truck Arrived',
      'message': 'The garbage truck ($truckId) has arrived in $areaName.',
      'purok': areaName,
      'truck_id': truckId,
      'timestamp': ServerValue.timestamp,
      'isRead': false
    });
    
    _autoNotifiedPuroks.add(areaName);
    debugPrint("[AUTO-NOTIFY] Sent arrival alert for $areaName");
  }

  final Set<String> _approachNotifiedPuroks = {};

  void _handleApproachNotification(String areaName, double distance) async {
    if (_approachNotifiedPuroks.contains(areaName)) {
      return;
    }
    
    final truckId = _user?.preferredTruck ?? "Unknown";
    
    // Calculate simple ETA (Assume 15 km/h for arrival)
    double speedMps = 15 / 3.6; 
    int etaMinutes = (distance / speedMps / 60).ceil();
    if (etaMinutes < 1) {
      etaMinutes = 1;
    }

    await _database.ref('notifications').push().set({
      'type': 'auto_approach',
      'title': 'Garbage Truck Approaching',
      'message': 'Truck $truckId is on the way to $areaName. Estimated arrival: $etaMinutes min.',
      'purok': areaName,
      'truck_id': truckId,
      'timestamp': ServerValue.timestamp,
      'isRead': false
    });
    
    _approachNotifiedPuroks.add(areaName);
    debugPrint("[AUTO-NOTIFY] Sent approach alert for $areaName (ETA: $etaMinutes)");
  }

  void _appendRoutePoint(Position pos, String status, String color) {
    if (_sessionId == null) {
      return;
    }
    // Use local timestamp for immediate consistent sorting in map views
    final int ts = DateTime.now().millisecondsSinceEpoch;
    _database.ref('driver_routes').child(_sessionId!).child('route').push().set({
      'lat': pos.latitude, 'lng': pos.longitude, 'status': status, 'color': color,
      'speed': pos.speed * 3.6, 'heading': pos.heading, 'accuracy': pos.accuracy, 
      'timestamp': ts,
    });
  }

  void _startIdleDetection() {
    _idleDetectionTimer?.cancel();
    _idleDetectionTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_currentPosition == null || _status == "OFFLINE" || _status == "FINISHED" || _status == "IDLE") {
        return;
      }
      if (_lastGpsUpdateTime != null && DateTime.now().difference(_lastGpsUpdateTime!).inMinutes >= 2) {
        _updateTripStatus("IDLE");
      }
    });
  }

  Future<void> _updateTripStatus(String newStatus) async {
    final truckId = _user?.preferredTruck ?? "Unknown";
    await _database.ref('truck_locations').child(truckId).update({
      'status': newStatus.toUpperCase(),
      'updatedAt': DateTime.now().toIso8601String(),
    });
    if (mounted) {
      setState(() => _status = newStatus);
    }
  }

  bool _isFinishing = false; // Added to prevent multiple finish calls

  Future<void> _finishTrip() async {
    debugPrint("[FINISH] Finish Trip sequence started...");
    
    if (_isFinishing) {
      debugPrint("[FINISH] WARNING: Already in the process of finishing.");
      return;
    }

    setState(() => _isFinishing = true);
    final truckId = _user?.preferredTruck ?? "Unknown";
    final driverId = _user?.userId.toString() ?? "Unknown";

    debugPrint("[FINISH] LOG: Initial State - session Id: $_sessionId, driverId: $driverId, status: $_status");

    try {
      // 1. RECOVERY LOGIC: If session Id is null, try to find an active trip in Firebase
      if (_sessionId == null) {
        debugPrint("[FINISH] RECOVERY: Local session Id is null. Searching Firebase...");
        
        // 1. Check truck_locations first (Direct path, NO INDEX NEEDED)
        final locSnap = await _database.ref('truck_locations/$truckId').get();
        if (locSnap.exists && locSnap.value != null) {
          final lData = locSnap.value as Map;
          if (lData['current_session'] != null) {
            _sessionId = lData['current_session'].toString();
            debugPrint("[FINISH] Recovered session Id from truck_locations: $_sessionId");
            
            final sessionSnap = await _database.ref('driver_routes/$_sessionId').get();
            if (sessionSnap.exists) {
              final sData = sessionSnap.value as Map;
              _startTime = sData['start_time'] ?? _startTime;
              _distance = (sData['total_distance'] ?? _distance).toDouble();
            }
          }
        }

        // 2. Fallback: Check driver_routes (Query, NEEDS INDEX)
        if (_sessionId == null) {
          try {
            final routesRef = _database.ref('driver_routes');
            final activeRouteSnapshot = await routesRef
                .orderByChild('driver_id')
                .equalTo(int.tryParse(driverId) ?? driverId)
                .get();
            
            if (activeRouteSnapshot.exists && activeRouteSnapshot.value != null) {
              final Map routes = activeRouteSnapshot.value as Map;
              routes.forEach((key, value) {
                if (value['route_status'] == 'ACTIVE') {
                  _sessionId = key.toString();
                  _startTime = value['start_time'] ?? _startTime;
                  _distance = (value['total_distance'] ?? _distance).toDouble();
                  if (value['server_start_time'] != null) {
                    _startDateTime = DateTime.fromMillisecondsSinceEpoch(value['server_start_time'] as int);
                  }
                }
              });
            }
          } catch (e) {
            debugPrint("[FINISH] Fallback query failed: $e");
          }
        }
      }

      final String? finalSessionId = _sessionId;
      debugPrint("[FINISH] RECOVERY RESULT: session Id resolved to: $finalSessionId");

      // 2. FINALIZE TRIP DOCUMENT (if it exists)
      if (finalSessionId != null) {
        debugPrint("[FINISH] Step 1: Updating driver_routes document...");
        await _database.ref('driver_routes').child(finalSessionId).update({
          'route_status': 'COMPLETED',
          'end_time': DateFormat('h:mm a').format(DateTime.now()),
          'finish_lat': _currentPosition?.latitude,
          'finish_lng': _currentPosition?.longitude,
          'final_distance': _distance,
          'total_distance': _distance,
        });

        if (_currentPosition != null) {
          _appendRoutePoint(_currentPosition!, "FINISHED", "BLACK");
        }

        // Apply Maintenance Deduction
        final sessionRef = _database.ref('driver_routes').child(finalSessionId);
        final sessionSnap = await sessionRef.get();
        bool alreadyDeducted = false;
        if (sessionSnap.exists) {
          final sData = sessionSnap.value as Map;
          alreadyDeducted = sData['maintenance_applied'] == true;
        }

        if (!alreadyDeducted) {
          debugPrint("[FINISH] Step 2: Applying maintenance deduction...");
          await _applyMaintenanceDeduction(truckId, _distance);
          await sessionRef.update({'maintenance_applied': true});
        }
      } else {
        debugPrint("[FINISH] INFO: No persistent trip document found to finalize.");
      }

      // 3. CLEANUP TRUCK LOCATIONS & RESET LOCAL STATE
      debugPrint("[FINISH] Step 3: Resetting truck_locations node and local state...");
      await _database.ref('truck_locations').child(truckId).update({
        'status': 'completed', 
        'current_session': null,
        'start_time': null,
        'distance': 0.0,
        'current_purok': null,
      });

      _positionSubscription?.cancel();
      debugPrint("[FINISH] WRITE SUCCESS: Driver session closed safely.");

      // Clear persistent user doc reference
      await _database.ref('users/$driverId').update({
        'current_trip_id': null,
      });

      if (mounted) {
        setState(() { 
          _status = "COMPLETED"; 
          _sessionId = null; 
          _startTime = "--:--"; 
          _distance = 0.0;
          _isFinishing = false;
          _completedCount = 0;
          _purokStatus = {};
          _autoNotifiedPuroks.clear();
          _approachNotifiedPuroks.clear();
        });

        String msg = finalSessionId != null 
            ? "Trip completed successfully." 
            : "No active route record was found. Driver session has been closed.";
            
        debugPrint("[FINISH] TRIP FINISHED: true");
        debugPrint("[FINISH] PREVIOUS TRIP FINISHED: true");

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg),
            backgroundColor: finalSessionId != null ? Colors.green : Colors.orange,
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isFinishing = false);
        debugPrint("[FINISH] ERROR: $e");
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Failed to finish Trip: $e"),
            backgroundColor: Colors.red,
          ));
        }
      }
    }
  }

  void _checkMaintenanceThresholds() async {
    if (_maintenanceData.isEmpty || _user == null) return;
    final truckId = _user?.preferredTruck ?? "Unknown";

    final categories = ['oilChange', 'tireRotation', 'fullInspection'];
    final labels = {
      'oilChange': 'Oil Change',
      'tireRotation': 'Tire Rotation',
      'fullInspection': 'Full Inspection'
    };

    for (var cat in categories) {
      if (!_maintenanceData.containsKey(cat)) continue;
      final data = _maintenanceData[cat] as Map;
      double savedRemaining = (data['remainingKm'] ?? 0.0).toDouble();
      double currentRemaining = savedRemaining - _distance;

      // Thresholds
      if (currentRemaining <= 0 && data['notifiedDue'] != true) {
        await _sendMaintenanceNotification(truckId, cat, "${labels[cat]} Required", "$truckId has reached its ${(labels[cat] ?? '').toLowerCase()} limit. Maintenance is required.", "notifiedDue");
      } else if (currentRemaining <= 100 && data['notified100'] != true) {
        await _sendMaintenanceNotification(truckId, cat, "${labels[cat]} Urgent", "$truckId only has ${currentRemaining.toStringAsFixed(0)} km remaining before its ${(labels[cat] ?? '').toLowerCase()} is due.", "notified100");
      } else if (currentRemaining <= 500 && data['notified500'] != true) {
        await _sendMaintenanceNotification(truckId, cat, "${labels[cat]} Due Soon", "$truckId has ${currentRemaining.toStringAsFixed(0)} km remaining before the next ${(labels[cat] ?? '').toLowerCase()}.", "notified500");
      }
    }
  }

  Future<void> _sendMaintenanceNotification(String truckId, String category, String title, String message, String flagField) async {
    // 1. Mark as notified in Firebase immediately to prevent duplicate triggers
    await _database.ref('trucks/$truckId/maintenance/$category').update({flagField: true});
    
    // 2. Push notification to the global notifications node
    await _database.ref('notifications').push().set({
      'type': 'MAINTENANCE_ALERT',
      'title': title,
      'message': message,
      'truck_id': truckId,
      'driver_id': _user?.userId.toString(),
      'targetRole': 'driver',
      'timestamp': ServerValue.timestamp,
      'isRead': false,
    });
    
    debugPrint("[MAINTENANCE ALERT] $title: $message");
  }

  Future<void> _applyMaintenanceDeduction(String truckId, double tripDistance) async {
    try {
      final truckRef = _database.ref('trucks/$truckId/maintenance');
      final snapshot = await truckRef.get();
      
      if (!snapshot.exists || snapshot.value == null) {
        return;
      }
      final data = snapshot.value as Map;

      // Deduct from each maintenance category
      Future<void> deductItem(String key, double interval) async {
        final item = data[key] as Map?;
        double currentRemaining = (item?['remainingKm'] ?? interval).toDouble();
        double newRemaining = currentRemaining - tripDistance;
        
        // Dynamic status based on new value
        String status = "NORMAL";
        if (newRemaining <= 0) {
          status = "SERVICE DUE";
        } else if (newRemaining <= 100) {
          status = "URGENT";
        } else if (newRemaining <= 500) {
          status = "DUE SOON";
        }

        await truckRef.child(key).update({
          'remainingKm': newRemaining,
          'status': status,
          'lastMaintenanceUpdate': ServerValue.timestamp,
        });
      }

      await deductItem('oilChange', 5000.0);
      await deductItem('tireRotation', 10000.0);
      await deductItem('fullInspection', 20000.0);

      debugPrint("[MAINTENANCE] Final Deduction: $tripDistance km from truck $truckId");
    } catch (e) {
      debugPrint("[MAINTENANCE] Error applying deduction: $e");
    }
  }

  void _handleSimulationToggle() {
    if (_isSimulationMode) {
      setState(() {
        _isSimulationMode = false;
        _simulationTimer?.cancel();
        _startTracking();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Simulation stopped. Returning to Real GPS.")));
    } else {
      _showAreaSelection("Select Simulation Location", (area) {
        setState(() => _isSimulationMode = true);
        _startSimulationAt(area);
      });
    }
  }

  void _startSimulationAt(String areaName) {
    _positionSubscription?.cancel();
    _simulationTimer?.cancel();
    
    // 1. Find the area in our config
    final config = _purokConfigs.firstWhere(
      (p) => p['name'] == areaName,
      orElse: () => _purokConfigs.first,
    );

    debugPrint("[SIMULATION] Starting at ${config['name']} (${config['lat']}, ${config['lng']})");

    void sendSimulatedUpdate(Map<String, dynamic> targetPurok) {
      final pos = Position(
        latitude: targetPurok['lat'], 
        longitude: targetPurok['lng'], 
        timestamp: DateTime.now(), 
        accuracy: 5.0, // High accuracy for simulation
        altitude: 0, heading: 0, speed: 15.0,
        speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0
      );
      
      // Update local state for Map to pick up
      if (mounted) {
        setState(() {
          _currentPosition = pos;
        });
      }

      // This will update truck_locations and trigger proximity checks
      _processNewPosition(pos);
    }

    // Move to the selected Purok instantly
    sendSimulatedUpdate(config);
  }

  void _sendManualAlert(String area) async {
    if (_sessionId == null) {
      return;
    }
    final truckId = _user?.preferredTruck ?? "Unknown";
    
    try {
      // 1. Send Notification (Target specific Purok residents)
      await _database.ref('notifications').push().set({
        'type': 'manual_alert', 
        'title': 'Garbage Truck Update',
        'message': 'The garbage truck is now approaching $area.',
        'purok': area, // FILTERED BY AREA
        'truck_id': truckId, 
        'timestamp': ServerValue.timestamp, 
        'isRead': false
      });

      // 2. Mark ONLY selected Purok as Completed in the current session
      String key = area.replaceAll('/', '_');
      await _database.ref('collection_progress').child(_sessionId!).child(key).update({
        'completed': true,
        'completedAt': DateFormat('h:mm a').format(DateTime.now()),
        'timestamp': ServerValue.timestamp,
        'completionSource': 'MANUAL_ALERT',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Alert sent and $area marked as visited.")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to send alert: $e")));
      }
    }
  }

  Future<void> _handleLogout() async {
    debugPrint("[LIFECYCLE] LOGOUT CLICKED: true");
    debugPrint("[LIFECYCLE] ACTIVE TRIP BEFORE LOGOUT: $_sessionId");
    debugPrint("[LIFECYCLE] START TIME BEFORE LOGOUT: $_startTime");
    debugPrint("[LIFECYCLE] DISTANCE BEFORE LOGOUT: $_distance");
    debugPrint("[LIFECYCLE] ROUTE POINT COUNT BEFORE LOGOUT: ${_tripRoutePoints.length}");
    debugPrint("[LIFECYCLE] PROGRESS BEFORE LOGOUT: $_completedCount");

    _positionSubscription?.cancel();
    final truckId = _user?.preferredTruck ?? "Unknown";
    await _database.ref('truck_locations').child(truckId).update({'status': 'OFFLINE', 'isOnline': false, 'lastSeen': ServerValue.timestamp});
    await SessionManager.logout();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  @override
  Widget build(BuildContext context) {
    // DIAGNOSTIC LOGGING
    if (_currentPosition != null) {
       debugPrint("[DASHBOARD BUILD] currentPos: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}");
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          LayoutBuilder(builder: (context, constraints) {
            return IndexedStack(
              index: _selectedIndex,
              children: [
                FadeSlideEntrance(key: const ValueKey(0), child: _buildResponsiveDashboard(constraints)),
                FadeSlideEntrance(
                  key: const ValueKey(1),
                  child: DriverTrackTruckScreen(
                    isEmbedded: false, 
                    currentSessionId: _sessionId, 
                    focusTruckId: _user?.preferredTruck ?? "Unknown", 
                    onBack: () => setState(() => _selectedIndex = 0),
                    isSimulation: _isSimulationMode,
                    manualPosition: _currentPosition, // ALWAYS pass current position from the main tracking service
                    testRoute: _debugTestRoute, // PASS test route
                  ),
                ),
                FadeSlideEntrance(
                  key: const ValueKey(2),
                  child: DriverSettingsScreen(isEmbedded: true, onBack: () => setState(() => _selectedIndex = 0), currentSessionId: _sessionId),
                ),
              ],
            );
          }),
          // LOADING OVERLAY FOR SESSION RESTORATION
          if (_isRestoringSession)
            Container(
              color: Colors.white,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.teal),
                    SizedBox(height: 24),
                    Text("Restoring trip session...", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
                  ],
                ),
              ),
            ),
          // DIAGNOSTICS OVERLAY
          Positioned(
            top: 50, right: 10,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
          _buildDiagnosticRow("GPS", _currentPosition != null 
              ? "${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}" 
              : "WAITING FOR GPS"),
          _buildDiagnosticRow("LAST", _tripRoutePoints.isNotEmpty 
              ? "${_tripRoutePoints.last['lat']?.toStringAsFixed(5) ?? '...'}, ${_tripRoutePoints.last['lng']?.toStringAsFixed(5) ?? '...'}" 
              : "NO POINTS"),
        ],
      ),
    ),
  ),
),
// COLLAPSIBLE DEBUG OVERLAY & WALK TEST PANEL
Positioned(
  top: 100, left: 10,
  child: Container(
    width: 180,
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white24),
    ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () => setState(() => _isDebugPanelExpanded = !_isDebugPanelExpanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("DEBUG PANEL", style: TextStyle(color: Colors.yellow, fontSize: 10, fontWeight: FontWeight.bold)),
                          Icon(_isDebugPanelExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white70, size: 14),
                        ],
                      ),
                    ),
                  ),
                  if (_isDebugPanelExpanded) ...[
                    const Divider(color: Colors.white24, height: 1),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("TRIP: ${_sessionId ?? 'none'}", style: const TextStyle(color: Colors.white70, fontSize: 8)),
                          Text("CURRENT STATUS: $_status", style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                          Text("EFFECTIVE ROUTE STATUS: ${_getEffectiveRouteStatus()}", style: const TextStyle(color: Colors.cyanAccent, fontSize: 8, fontWeight: FontWeight.bold)),
                          if (_startDateTime != null)
                            Text("START: ${_tripRoutePoints.isNotEmpty ? _tripRoutePoints.first['lat'] : '...' }, ${_tripRoutePoints.isNotEmpty ? _tripRoutePoints.first['lng'] : '...'}", style: const TextStyle(color: Colors.white70, fontSize: 8)),
                          Text("GPS: ${_currentPosition != null ? 'LOCKED' : 'SEARCHING'}", style: TextStyle(color: _currentPosition != null ? Colors.greenAccent : Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                          if (_currentPosition != null) ...[
                            Text("LAT: ${_currentPosition!.latitude.toStringAsFixed(6)}", style: const TextStyle(color: Colors.white70, fontSize: 8)),
                            Text("LNG: ${_currentPosition!.longitude.toStringAsFixed(6)}", style: const TextStyle(color: Colors.white70, fontSize: 8)),
                            Text("ACCURACY: ${_currentPosition!.accuracy.toStringAsFixed(1)}m", style: TextStyle(color: _currentPosition!.accuracy < 20 ? Colors.greenAccent : Colors.orangeAccent, fontSize: 8)),
                          ],
                          const SizedBox(height: 4),
                          Text("ROUTE POINTS: ${_tripRoutePoints.length}", style: const TextStyle(color: Colors.white, fontSize: 8)),
                          _buildDebugCounter("ACTIVE POINTS", "ACTIVE"),
                          _buildDebugCounter("IDLE POINTS", "IDLE"),
                          _buildDebugCounter("FULL POINTS", "FULL"),
                          const SizedBox(height: 4),
                          Text("DISTANCE: ${_distance.toStringAsFixed(3)} km", style: const TextStyle(color: Colors.white, fontSize: 9)),
                          Text("MAP ROUTE: ${_sessionId != null ? 'VISIBLE' : 'HIDDEN'}", style: const TextStyle(color: Colors.white, fontSize: 8)),
                          const SizedBox(height: 8),
                          const Text("FORCE STATUS COLOR:", style: TextStyle(color: Colors.cyanAccent, fontSize: 8, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          _buildOverrideButtons(),
                          const SizedBox(height: 8),
                          if (_debugTestRoute != null) ...[
                            const Divider(color: Colors.white24),
                            const Text("TEST ROUTE METRICS:", style: TextStyle(color: Colors.orangeAccent, fontSize: 8, fontWeight: FontWeight.bold)),
                            _buildTestRouteMetrics(),
                            const SizedBox(height: 8),
                          ],
                          const Divider(color: Colors.white24),
                          const Text("RENDERER TEST:", style: TextStyle(color: Colors.orangeAccent, fontSize: 8, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          _buildRendererTestButtons(),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildDiagnosticRow(String label, String value, {Color color = Colors.white70}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("$label: ", style: const TextStyle(color: Colors.white38, fontSize: 8)),
          Text(value, style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDebugCounter(String label, String status) {
    int count = _tripRoutePoints.where((p) => (p['status'] ?? '').toString().toUpperCase() == status).length;
    Color color = Colors.white70;
    if (status == "ACTIVE") color = Colors.greenAccent;
    if (status == "IDLE") color = Colors.yellowAccent;
    if (status == "FULL") color = Colors.pinkAccent;
    return Text("$label: $count", style: TextStyle(color: color, fontSize: 7));
  }

  Widget _buildResponsiveDashboard(BoxConstraints constraints) {
    double width = constraints.maxWidth;
    return SingleChildScrollView(
      child: Column(children: [
        _buildHeader(width),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Row(children: [
              Expanded(child: _buildMetricCard("Start Time", _startTime, Icons.access_time_filled, Colors.blue)),
              const SizedBox(width: 16),
              Expanded(child: _buildMetricCard("Distance", "${_distance.toStringAsFixed(2)} km", Icons.route, Colors.purple)),
            ]),
            const SizedBox(height: 24),
            _buildVehicleControls(),
            const SizedBox(height: 24),
            _buildActionsGrid(width),
            const SizedBox(height: 24),
            _buildMapCard(width),
            const SizedBox(height: 24),
            _buildTripInformation(),
            const SizedBox(height: 24),
            _buildGpsStatus(),
            const SizedBox(height: 24),
            _buildProgressTracker(),
            const SizedBox(height: 40),
          ]),
        ),
      ]),
    );
  }

  Widget _buildHeader(double width) {
    bool isMobile = width < 600;
    double headerHeight = isMobile ? 160 : 190;
    
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(48)),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            height: headerHeight,
            decoration: const BoxDecoration(color: Color(0xFF00695C)),
          ),
          AnimatedBuilder(
            animation: _circleController,
            builder: (context, child) {
              return CustomPaint(
                size: Size(double.infinity, headerHeight),
                painter: HeaderCirclePainter(_circleController.value),
              );
            },
          ),
          Positioned(
            bottom: 20, left: 24, right: 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Welcome back", style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(_user?.name ?? "Driver Name", style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                      const SizedBox(height: 8),
                      Row(children: [
                        const Icon(Icons.local_shipping_outlined, color: Colors.white70, size: 14),
                        const SizedBox(width: 6),
                        Text("Truck: ${_user?.preferredTruck ?? 'GT-001'}", style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                      ]),
                      const SizedBox(height: 8),
                      _buildStatusIndicator(),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      width: 108,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white38, width: 1.5),
                      ),
                      child: Text(
                        _currentTime,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'monospace',
                          letterSpacing: 1.5,
                          shadows: [
                            Shadow(color: Colors.black26, offset: Offset(0, 2), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _buildHeaderActionIcon(Icons.notifications_none_rounded, badgeCount: _unreadNotifications > 0 ? _unreadNotifications : null, onTap: () => _showAlertHistory()),
                        const SizedBox(width: 12),
                        _buildHeaderActionIcon(Icons.logout, onTap: () => _showLogoutDialog(context)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderActionIcon(IconData icon, {int? badgeCount, VoidCallback? onTap}) {
    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.1,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 30 / 255), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
        if (badgeCount != null)
          Positioned(
            right: -2, top: -2,
            child: Container(padding: const EdgeInsets.all(5), decoration: const BoxDecoration(color: Color(0xFFFF4081), shape: BoxShape.circle), child: Text("$badgeCount", style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900))),
          ),
      ]),
    );
  }

  Color _buildStatusIndicatorColor() {
    switch(_status.toUpperCase()) {
      case "ACTIVE": return Colors.greenAccent;
      case "IDLE": return Colors.yellowAccent;
      case "FULL": return Colors.redAccent;
      case "FINISHED": 
      case "COMPLETED": return Colors.blueAccent;
      default: return Colors.white70;
    }
  }

  Widget _buildStatusIndicator() {
    Color color = _buildStatusIndicatorColor();
    String label = _status.toUpperCase();
    
    // Updated Status Mapping
    if (label == "FINISHED" || label == "DONE" || label == "COMPLETED") {
      label = "COMPLETED";
    } else if (label == "IDLE") {
      label = "IDLE";
    } else if (label == "ACTIVE" || label == "START") {
      label = "ACTIVE";
    } else if (label == "FULL") {
      label = "FULL";
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: color)),
      child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900)),
    );
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(20), 
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05), // Light background color
        borderRadius: BorderRadius.circular(32), 
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 5 / 255), blurRadius: 10, offset: const Offset(0, 4))],
        border: Border.all(color: color.withValues(alpha: 0.1), width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(10), 
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle), 
          child: Icon(icon, color: color, size: 22)
        ),
        const SizedBox(height: 16),
        Text(title, style: TextStyle(fontSize: 12, color: color.darken(0.3), fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color.darken(0.2))),
      ]),
    );
  }

  Widget _buildVehicleControls() {
    return Container(
      padding: const EdgeInsets.all(28), 
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow,
        border: Border.all(color: Colors.grey.shade100, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppColors.tealText.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.settings_input_component_rounded, color: AppColors.tealText, size: 18),
            ),
            const SizedBox(width: 12),
            const Text("Vehicle Controls", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
          ],
        ),
        const SizedBox(height: 28),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _buildOpButton("START", Icons.play_arrow_rounded, Colors.teal, () {
            if (_sessionId == null) {
              _startTripSession();
            } else {
              _updateTripStatus("ACTIVE");
            }
          }),
          _buildOpButton("PAUSE", Icons.pause_rounded, Colors.orange, () => _updateTripStatus("IDLE")),
          _buildOpButton("FULL", Icons.local_shipping_rounded, Colors.pink, _showFullConfirmation),
          _buildOpButton("DONE", Icons.check_rounded, Colors.blue, _showFinishConfirmation),
        ]),
      ]),
    );
  }

  Widget _buildOpButton(String label, IconData icon, Color color, VoidCallback onTap) {
    String currentStatus = _status.toUpperCase();
    bool isSelected = false;
    
    if (label == "START") {
      isSelected = currentStatus == "ACTIVE";
    } else if (label == "PAUSE") {
      isSelected = currentStatus == "IDLE";
    } else if (label == "FULL") {
      isSelected = currentStatus == "FULL";
    } else if (label == "DONE") {
      isSelected = currentStatus == "FINISHED" || currentStatus == "COMPLETED";
    }

    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.15,
      child: Column(children: [
        Container(
          width: 64, height: 64, 
          decoration: BoxDecoration(
            color: isSelected ? color : Colors.white, 
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isSelected ? color : color.withValues(alpha: 0.3), width: 2),
            boxShadow: isSelected ? [
              BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 6))
            ] : [
              BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 4))
            ],
          ), 
          child: Icon(icon, color: isSelected ? Colors.white : color, size: 32)
        ),
        const SizedBox(height: 10),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: isSelected ? color : Colors.grey.shade600, letterSpacing: 0.5)),
      ]),
    );
  }

  Widget _buildActionsGrid(double width) {
    return LayoutBuilder(builder: (context, constraints) {
      return Row(
        children: [
          Expanded(child: _buildActionCard("Manual Alert", Icons.notifications_active_rounded, Colors.blue, () => _showAreaSelection("Manual Alert", _sendManualAlert))),
          const SizedBox(width: 12),
          Expanded(child: _buildActionCard(_isSimulationMode ? "Real GPS" : "Simulation", _isSimulationMode ? Icons.location_on_rounded : Icons.directions_run_rounded, _isSimulationMode ? Colors.orange : Colors.purple, _handleSimulationToggle)),
          const SizedBox(width: 12),
          Expanded(child: _buildActionCard("Progress: $_completedCount", Icons.checklist_rtl_rounded, Colors.green, () => setState(() => _selectedIndex = 0))),
        ],
      );
    });
  }

  Widget _buildActionCard(String label, IconData icon, Color color, VoidCallback onTap) {
    return _HoverZoomCard(
      onTap: onTap,
      scale: 1.05,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white, 
          borderRadius: BorderRadius.circular(24), 
          boxShadow: AppTheme.pulidongShadow,
          border: Border.all(color: color.withValues(alpha: 0.1), width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, 
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              label, 
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: color.darken(0.2))
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapCard(double width) {
    return Container(
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
          height: 300,
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 10 / 255), blurRadius: 10, offset: const Offset(0, 5))]
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: DriverTrackTruckScreen(
              isEmbedded: true, 
              currentSessionId: _sessionId, 
              focusTruckId: _user?.preferredTruck ?? "Unknown",
              isSimulation: _isSimulationMode,
              manualPosition: _currentPosition, // Pass current position for real-time dashboard tracking
            )
          ),
        ),
      ]),
    );
  }

  Widget _buildTripInformation() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow,
        border: Border.all(color: Colors.grey.shade100, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppColors.tealText.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.info_outline_rounded, color: AppColors.tealText, size: 18),
            ),
            const SizedBox(width: 12),
            const Text("Trip Information", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
          ],
        ),
        const SizedBox(height: 24),
        _buildInfoRow("Truck Number", _user?.preferredTruck ?? "Unknown", color: AppColors.tealText),
        const Divider(height: 24),
        _buildInfoRow("Plate Number", _truckPlateNumber ?? "N/A", isBold: true),
        const Divider(height: 24),
        _buildInfoRow("Start Time", _startTime),
        const Divider(height: 24),
        _buildInfoRow("Estimated End", _calculateEstimatedEnd()),
        const Divider(height: 24),
        _buildInfoRow("Total Distance", "${_distance.toStringAsFixed(1)} km", color: Colors.orangeAccent.shade200),
      ]),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? color, bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 14)),
        Text(
          value,
          style: TextStyle(
            color: color ?? const Color(0xFF2C3E50),
            fontWeight: isBold ? FontWeight.w900 : FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ],
    );
  }

  String _calculateEstimatedEnd() {
    if (_startTime == "--:--" || _startDateTime == null) {
      // If no start time yet, show a static relative estimate from now
      final now = DateTime.now();
      final est = now.add(const Duration(hours: 4));
      return DateFormat('h:mm a').format(est);
    }
    // Assuming a 4-hour shift for estimation
    final end = _startDateTime!.add(const Duration(hours: 4));
    return DateFormat('h:mm a').format(end);
  }

  Widget _buildGpsStatus() {
    bool isSearching = _currentPosition == null;
    Color statusColor = isSearching ? Colors.orange : Colors.green;
    String statusText = isSearching ? "Searching..." : "Strong";

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow,
        border: Border.all(color: Colors.grey.shade100, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
            const SizedBox(width: 12),
            const Text("GPS Status", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Signal Strength", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 14)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusColor.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text(statusText, style: TextStyle(fontWeight: FontWeight.w900, color: statusColor, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 24),
        _buildInfoRow("Accuracy", isSearching ? "Waiting for fix..." : "±${_currentPosition!.accuracy.toInt()} meters"),
        const Divider(height: 24),
        _buildInfoRow("Last Update", _lastGpsUpdateTime != null ? DateFormat('hh:mm:ss a').format(_lastGpsUpdateTime!) : "Waiting..."),
      ]),
    );
  }

  Widget _buildProgressTracker() {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(32), 
        boxShadow: AppTheme.pulidongShadow,
        border: Border.all(color: Colors.grey.shade100, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text("Collection Progress", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
          Text("${((_completedCount / _totalPuroks) * 100).toInt()}%", style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.tealText, fontSize: 18)),
        ]),
        const SizedBox(height: 24),
        ListView.separated(
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          itemCount: _isPuroksExpanded ? _purokConfigs.length : 3,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final p = _purokConfigs[i];
            final String key = p['name'].replaceAll('/', '_');
            final statusData = _purokStatus[key] ?? {'completed': false};
            bool done = statusData['completed'] == true;
            
            return Container(
              padding: const EdgeInsets.all(16), 
              decoration: BoxDecoration(
                color: done ? Colors.green.shade50 : const Color(0xFFF8F9FA), 
                borderRadius: BorderRadius.circular(16),
                border: done ? Border.all(color: Colors.green.withValues(alpha: 0.2)) : Border.all(color: Colors.grey.shade100),
              ),
              child: Row(children: [
                Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? Colors.green : Colors.grey.shade400, size: 20), 
                const SizedBox(width: 12), 
                Expanded(child: Text(p['name'], style: TextStyle(fontWeight: FontWeight.w700, color: done ? Colors.green.shade900 : const Color(0xFF2C3E50)))),
                if (done)
                  const Icon(Icons.verified_rounded, color: Colors.green, size: 14),
              ]),
            );
          },
        ),
        const SizedBox(height: 16),
        Center(
          child: _HoverZoomLink(
            onTap: () => setState(() => _isPuroksExpanded = !_isPuroksExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _isPuroksExpanded ? "Show Less" : "View All Puroks ($_totalPuroks)",
                style: const TextStyle(color: AppColors.tealText, fontWeight: FontWeight.w900, fontSize: 14),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  void _showAreaSelection(String title, Function(String) onSelect) {
    _showStyledBottomSheet(
      title: title,
      children: [
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _purokConfigs.length,
          itemBuilder: (context, i) => ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            title: Text(_purokConfigs[i]['name'], style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))),
            trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
            onTap: () {
              Navigator.pop(context);
              onSelect(_purokConfigs[i]['name']);
            },
          ),
        ),
      ],
    );
  }

  void _showStyledBottomSheet({required String title, required List<Widget> children}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
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

  void _showFullConfirmation() async {
    _updateTripStatus("FULL");
  }

  void _showFinishConfirmation() async {
    debugPrint("[FINISH] DONE button clicked. Attempting to resolve session state...");
    
    // We no longer block the button if session Id is null.
    // Instead, we always show the confirmation and handle recovery/cleanup inside finish Trip.

    bool confirmed = await _showConfirmDialog(
      title: "Finish Trip?",
      message: "Are you sure you want to finalize this collection session? All data will be saved to history.",
      icon: Icons.check_circle_outline_rounded,
      confirmColor: Colors.blue,
    );

    debugPrint("[FINISH] FINISH CONFIRM CLICKED: $confirmed");
    if (confirmed) {
      if (!mounted) return;
      _finishTrip();
    }
  }

  void _showLogoutDialog(BuildContext context) async {
    bool confirmed = await _showConfirmDialog(
      title: "Sign Out?",
      message: "Are you sure you want to end your session? You will need to log in again to access your dashboard.",
      icon: Icons.logout_rounded,
    );
    if (confirmed) {
      if (!mounted) return;
      _handleLogout();
    }
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

  bool _isNotificationForMe(Map val) {
    final String type = (val['type'] ?? '').toString();
    final String? truckId = val['truck_id']?.toString() ?? val['truckId']?.toString();
    final String? targetUserId = val['targetUserId']?.toString() ?? val['userId']?.toString() ?? val['resident_id']?.toString();
    final String? targetRole = val['targetRole']?.toString().toLowerCase();

    // 1. STRICT EXCLUSION: Admin-only types
    if (['REGISTRATION', 'NEW_REGISTRATION', 'RESIDENT_COMPLAINT'].contains(type)) {
      return false;
    }

    // 2. STRICT EXCLUSION: Resident-only types (Even if they have truck_id)
    if (['auto_arrival', 'auto_approach', 'manual_alert', 'COLLECTION_ALERT', 'COMPLAINT_RESOLVED'].contains(type)) {
      return false;
    }

    // 3. TARGETED: Explicitly for this User ID
    if (targetUserId != null && targetUserId == _user?.userId.toString()) {
      return true;
    }

    // 4. ROLE-BASED: Targeted to all drivers or this specific driver role
    if (targetRole == 'driver') {
      if (truckId == null || truckId.isEmpty || truckId == _user?.preferredTruck) {
        return true;
      }
    }

    // 5. TRUCK-BASED: Relevant to the assigned truck (e.g., ISSUE_UPDATE, MAINTENANCE)
    if (truckId != null && truckId.isNotEmpty && truckId == _user?.preferredTruck) {
       // Only allow driver-relevant types if filtered by truck
       // (Excluded resident types were already caught in step 2)
       return true; 
    }

    return false;
  }

  void _showAlertHistory() {
    final GlobalKey<AnimatedListState> listKey = GlobalKey<AnimatedListState>();
    List<Map> notifications = [];

    showDialog(context: context, builder: (context) {
      return StatefulBuilder(builder: (context, setModalState) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          child: Container(
            clipBehavior: Clip.antiAlias,
            constraints: BoxConstraints(
              maxWidth: 500,
              maxHeight: MediaQuery.of(context).size.height * 0.7,
              minHeight: MediaQuery.of(context).size.height * 0.7,
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
                  const Expanded(child: Text("Alert History", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 28),
                child: Divider(height: 32),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Recent driver alerts", style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500)),
                    _HoverZoomLink(
                      onTap: () => _handleClearAllNotifications(notifications, listKey, setModalState),
                      child: const Text("Clear All", style: TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.w800, fontSize: 14)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: StreamBuilder<DatabaseEvent>(
                    stream: _database.ref('notifications').onValue,
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data!.snapshot.exists) {
                        final Map data = snapshot.data!.snapshot.value as Map;
                        List<Map> newList = [];
                        data.forEach((k, v) {
                          final val = v as Map;
                          if (_isNotificationForMe(val)) {
                            newList.add({...val, 'key': k});
                          }
                        });

                        newList.sort((a, b) => (b['timestamp'] ?? 0).compareTo(a['timestamp'] ?? 0));
                        notifications = newList;
                        if (notifications.isEmpty) {
                          return _buildEmptyState();
                        }

                        return AnimatedList(
                          key: listKey,
                          shrinkWrap: true,
                          initialItemCount: notifications.length,
                          itemBuilder: (context, index, animation) {
                            if (index >= notifications.length) {
                              return const SizedBox();
                            }
                            return _buildDismissibleNotification(notifications[index], index, listKey, setModalState);
                          },
                        );
                      }
                      return _buildEmptyState();
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _HoverZoomLink(
                onTap: () => Navigator.pop(context),
                child: const Text("CLOSE", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1)),
              ),
            ]),
          ),
        );
      });
    });
  }

  Widget _buildEmptyState() {
    return const Column(children: [
      SizedBox(height: 48),
      CircleAvatar(radius: 40, backgroundColor: Color(0xFFF5F5F5), child: Icon(Icons.notifications_rounded, size: 40, color: Colors.grey)),
      SizedBox(height: 16),
      Text("No alerts found.", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey)),
      SizedBox(height: 48),
    ]);
  }

  Future<void> _handleClearAllNotifications(List<Map> notifications, GlobalKey<AnimatedListState> listKey, StateSetter setModalState) async {
    if (notifications.isEmpty) {
      return;
    }
    bool confirmed = await _showConfirmDialog(
      title: "Clear All?",
      message: "Are you sure you want to permanently remove all alerts?",
      icon: Icons.delete_sweep_rounded,
      isDestructive: true,
    );
    if (confirmed) {
      final List<Map> toRemove = List.from(notifications);
      for (int i = toRemove.length - 1; i >= 0; i--) {
        final removedItem = toRemove[i];
        await _database.ref('notifications/${removedItem['key']}').remove();
        if (i < notifications.length) {
          notifications.removeAt(i);
          listKey.currentState?.removeItem(i, (context, animation) => _buildNotificationItem(removedItem, animation), duration: const Duration(milliseconds: 200));
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
      _showSnackBar("Alerts cleared");
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
            message: "This notification will be permanently removed.",
            icon: Icons.delete_outline_rounded,
            isDestructive: true,
          );
        },
        onDismissed: (direction) {
          _database.ref('notifications/${item['key']}').remove();
          _showSnackBar("Alert deleted");
        },
        background: Container(
          decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(24)),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400),
        ),
        secondaryBackground: Container(
          decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(24)),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400),
        ),
        child: _buildNotificationItem(item, const AlwaysStoppedAnimation(1.0)),
      ),
    );
  }

  Widget _buildNotificationItem(Map item, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: SizeTransition(
        sizeFactor: animation,
        child: _HoverZoomCard(
          onTap: () {
            _database.ref('notifications/${item['key']}').update({'isRead': true});
            Navigator.pop(context);
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.grey.shade200, width: 1.5),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.notifications_active_rounded, color: Color(0xFF00796B), size: 24),
              ),
              title: Text(item['title'] ?? 'Alert', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(item['message'] ?? '', style: const TextStyle(fontSize: 13, color: Color(0xFF666666), fontWeight: FontWeight.w500)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _showConfirmDialog({required String title, required String message, required IconData icon, bool isDestructive = false, Color? confirmColor}) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: isDestructive ? Colors.redAccent : (confirmColor ?? AppColors.tealText), size: 48),
            const SizedBox(height: 24),
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5)),
            const SizedBox(height: 32),
            HoverActionButton(
              text: "Confirm", 
              isDestructive: isDestructive,
              color: confirmColor,
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

  Widget _buildOverrideButtons() {
    return Column(
      children: [
        _buildOverrideOption("AUTO", Colors.white),
        _buildOverrideOption("FORCE ACTIVE", Colors.greenAccent),
        _buildOverrideOption("FORCE IDLE", Colors.yellowAccent),
        _buildOverrideOption("FORCE FULL", Colors.pinkAccent),
      ],
    );
  }

  Widget _buildOverrideOption(String label, Color color) {
    bool isSelected = _testStatusOverride == label;
    return InkWell(
      onTap: () => setState(() => _testStatusOverride = label),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: isSelected ? color : Colors.white10),
        ),
        child: Text(
          label, 
          style: TextStyle(color: isSelected ? color : Colors.white54, fontSize: 8, fontWeight: FontWeight.bold)
        ),
      ),
    );
  }

  Widget _buildRendererTestButtons() {
    return Column(
      children: [
        _buildTestButton("TEST STRAVA ROUTE", Colors.orangeAccent, _generateDebugTestRoute),
        const SizedBox(height: 4),
        _buildTestButton("CLEAR TEST ROUTE", Colors.redAccent, () => setState(() => _debugTestRoute = null)),
      ],
    );
  }

  Widget _buildTestButton(String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.5))),
        child: Text(label, textAlign: TextAlign.center, style: TextStyle(color: color, fontSize: 7, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _generateDebugTestRoute() {
    final startLat = _currentPosition?.latitude ?? 13.9413;
    final startLng = _currentPosition?.longitude ?? 121.1623;
    final now = DateTime.now().millisecondsSinceEpoch;

    final testRoute = [
      {'lat': startLat, 'lng': startLng, 'status': 'ACTIVE', 'color': 'GREEN', 'timestamp': now},
      {'lat': startLat + 0.0005, 'lng': startLng + 0.0005, 'status': 'ACTIVE', 'color': 'GREEN', 'timestamp': now + 1000},
      {'lat': startLat + 0.0010, 'lng': startLng + 0.0010, 'status': 'ACTIVE', 'color': 'GREEN', 'timestamp': now + 2000},
      {'lat': startLat + 0.0015, 'lng': startLng + 0.0005, 'status': 'IDLE', 'color': 'YELLOW', 'timestamp': now + 3000},
      {'lat': startLat + 0.0020, 'lng': startLng, 'status': 'IDLE', 'color': 'YELLOW', 'timestamp': now + 4000},
      {'lat': startLat + 0.0025, 'lng': startLng - 0.0005, 'status': 'ACTIVE', 'color': 'GREEN', 'timestamp': now + 5000},
      {'lat': startLat + 0.0030, 'lng': startLng - 0.0010, 'status': 'ACTIVE', 'color': 'GREEN', 'timestamp': now + 6000},
      {'lat': startLat + 0.0035, 'lng': startLng - 0.0005, 'status': 'FULL', 'color': 'PINK', 'timestamp': now + 7000},
      {'lat': startLat + 0.0040, 'lng': startLng, 'status': 'FULL', 'color': 'PINK', 'timestamp': now + 8000},
      {'lat': startLat + 0.0045, 'lng': startLng + 0.0005, 'status': 'FINISHED', 'color': 'BLACK', 'timestamp': now + 9000},
    ];

    setState(() {
      _debugTestRoute = testRoute;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Debug route generated. Check Map tab."), duration: Duration(seconds: 2))
    );
  }

  Widget _buildTestRouteMetrics() {
    if (_debugTestRoute == null) return const SizedBox.shrink();
    final points = _debugTestRoute!;
    final expectedEdges = points.length - 1;
    
    // Simple edge count calculation logic matching the renderer
    int actualEdges = 0;
    for (int i = 1; i < points.length; i++) {
      if ((points[i]['timestamp'] - points[i-1]['timestamp']) <= 60000) {
        actualEdges++;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _debugText("TEST POINTS: ${points.length}"),
        _debugText("EXPECTED EDGES: $expectedEdges"),
        _debugText("ACTUAL EDGES: $actualEdges"),
        _debugText("MISSING EDGES: ${expectedEdges - actualEdges}"),
        _debugText("CONTINUITY ERRORS: 0"),
        _debugText("ACTIVE SEGMENTS: ${points.where((p) => p['color'] == 'GREEN').length}"),
        _debugText("IDLE SEGMENTS: ${points.where((p) => p['color'] == 'YELLOW').length}"),
        _debugText("FULL SEGMENTS: ${points.where((p) => p['color'] == 'PINK').length}"),
        _debugText("FINISH SEGMENTS: ${points.where((p) => p['color'] == 'BLACK').length}"),
      ],
    );
  }

  Widget _debugText(String text) {
    return Text(text, style: const TextStyle(color: Colors.white70, fontSize: 7));
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 8 / 255), blurRadius: 20, offset: const Offset(0, -5))],
        border: Border(top: BorderSide(color: Colors.grey.shade100, width: 1))
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(0, Icons.home_rounded, 'Home'),
              _buildNavItem(1, Icons.location_on_rounded, 'Map'),
              _buildNavItem(2, Icons.settings_suggest_rounded, 'Settings'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    bool isSelected = _selectedIndex == index;
    return _HoverZoomLink(
      onTap: () => setState(() => _selectedIndex = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isSelected ? const Color(0xFF00796B) : const Color(0xFF9E9E9E), size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? const Color(0xFF00796B) : const Color(0xFF9E9E9E),
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600
            ),
          ),
        ],
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
