import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:intl/intl.dart';
import '../utils/app_theme.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../widgets/fade_slide_entrance.dart';

class DriverTrackTruckScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  final String? currentSessionId;
  final String? focusTruckId;
  final geo.Position? manualPosition;
  final bool isSimulation;
  final List<Map>? testRoute; 
  
  const DriverTrackTruckScreen({
    super.key, 
    this.isEmbedded = false, 
    this.onBack,
    this.currentSessionId,
    this.focusTruckId,
    this.manualPosition,
    this.isSimulation = false,
    this.testRoute,
  });

  @override
  State<DriverTrackTruckScreen> createState() => _DriverTrackTruckScreenState();
}

class _DriverTrackTruckScreenState extends State<DriverTrackTruckScreen> {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  MapboxMap? mapboxMap;
  UserData? _user;
  
  PointAnnotationManager? _pointAnnotationManager;
  
  final Map<String, PointAnnotation> _truckMarkers = {};
  List<Map> _lastPoints = [];
  StreamSubscription? _truckSubscription;
  StreamSubscription? _userSubscription;
  StreamSubscription? _routeSubscription;
  StreamSubscription? _routeMetaSubscription;
  StreamSubscription? _localGpsSubscription;
  
  Map<dynamic, dynamic>? _lastTruckData;
  geo.Position? _lastLocalPos;

  final Position _balintawakCenter = Position(121.1623, 13.9413);

  bool _managersReady = false;
  bool _driverSourceCreated = false;
  bool _routeSourceCreated = false;
  bool _specialMarkersCreated = false;
  
  // LIVE DRIVER MARKERS
  PointAnnotation? _liveDriverLabel;

  // Session Meta Persistence
  Map? _lastSessionData;

  // Follow Mode State
  bool _isFollowLocked = true;
  String _currentStatus = "ACTIVE";
  String? _truckPlateNumber;
  StreamSubscription? _truckMetaSubscription;

  // Modal Info State
  String _startTime = "--:--";
  double _distance = 0.0;
  double _currentSpeed = 0.0;
  String _currentTime = "";
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _startClock();
    if (widget.manualPosition != null) {
      _lastLocalPos = widget.manualPosition;
    }
    _checkPermissionAndStartGps();
    _listenToTrucks();
    _listenToTruckMeta();
    _listenToRoute();
  }

  void _loadUser() async {
    _user = await SessionManager.getUser();
    if (mounted) {
      setState(() {});
      _listenToTruckMeta();
    }
    _setupUserListener();
  }

  void _setupUserListener() {
    if (_user == null) return;
    _userSubscription?.cancel();
    _userSubscription = _database.ref('users/${_user!.userId}').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        if (mounted) {
          setState(() {
            final Map<String, dynamic> currentData = _user!.toJson();
            data.forEach((k, v) => currentData[k] = v);
            _user = UserData.fromJson(currentData);
          });
          _listenToTruckMeta(); // Refresh plate number if assignment changed
          if (_lastLocalPos != null) _updateLocalDriverMarker(_lastLocalPos!);
          
          // Refresh other truck markers with the new user context
          if (_managersReady && _lastTruckData != null) {
            _lastTruckData!.forEach((k, v) => _updateSingleTruckMarker(k.toString(), v as Map));
          }
        }
      }
    });
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
      setState(() => _currentTime = time);
    }
  }

  @override
  void didUpdateWidget(DriverTrackTruckScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusTruckId != widget.focusTruckId) {
      _listenToTrucks();
      _listenToTruckMeta();
    }
    if (oldWidget.currentSessionId != widget.currentSessionId) {
      _listenToRoute();
    }
    if (oldWidget.manualPosition != widget.manualPosition && widget.manualPosition != null) {
      _lastLocalPos = widget.manualPosition;
      _updateLocalDriverMarker(widget.manualPosition!);
    }
  }

  void _listenToTruckMeta() {
    _truckMetaSubscription?.cancel();
    final String? currentAssignedTruck = _user?.preferredTruck;
    final String tid = (widget.focusTruckId ?? currentAssignedTruck ?? "Unknown").toUpperCase();
    
    _truckMetaSubscription = _database.ref('trucks/$tid').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = event.snapshot.value as Map;
        if (mounted) {
          setState(() {
            _truckPlateNumber = data['plateNumber']?.toString();
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _truckSubscription?.cancel();
    _userSubscription?.cancel();
    _truckMetaSubscription?.cancel();
    _routeSubscription?.cancel();
    _routeMetaSubscription?.cancel();
    _localGpsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkPermissionAndStartGps() async {
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied || permission == geo.LocationPermission.deniedForever) {
      return;
    }

    try {
      geo.Position pos = await geo.Geolocator.getCurrentPosition(desiredAccuracy: geo.LocationAccuracy.high);
      if (mounted) {
        setState(() { 
          _lastLocalPos = pos;
          _currentSpeed = pos.speed * 3.6; 
        });
      }
      _updateLocalDriverMarker(pos);
    } catch (e) {}

    _localGpsSubscription = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.bestForNavigation, distanceFilter: 0),
    ).listen((pos) {
      if (widget.isSimulation) return;
      if (mounted) {
        setState(() { 
          _lastLocalPos = pos;
          _currentSpeed = pos.speed * 3.6;
        });
      }
      _updateLocalDriverMarker(pos);
    });
  }

  void _listenToTrucks() {
    _truckSubscription?.cancel();
    _truckSubscription = _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _lastTruckData = event.snapshot.value as Map;
        
        // DEBUG STALE RECORDS
        bool oldGT001Found = _lastTruckData!.containsKey("GT-001");
        bool gt007Found = _lastTruckData!.containsKey("GT-007");
        debugPrint("LIVE RECORDS FOR DRIVER: ${_lastTruckData!.keys.toList()}");
        debugPrint("OLD GT-001 LIVE RECORD FOUND: $oldGT001Found");
        debugPrint("GT-007 LIVE RECORD FOUND: $gt007Found");

        final String tid = (widget.focusTruckId ?? _user?.preferredTruck ?? "Unknown").toUpperCase();
        if (_lastTruckData!.containsKey(tid)) {
          final myData = _lastTruckData![tid] as Map;
          debugPrint("SELECTED CURRENT LIVE RECORD: $tid -> $myData");
          final String newStatus = (myData['status'] ?? "ACTIVE").toString().toUpperCase();
          if (newStatus != _currentStatus) {
            if (mounted) setState(() => _currentStatus = newStatus);
            if (_lastLocalPos != null) _updateLocalDriverMarker(_lastLocalPos!);
          }
        }

        if (_managersReady) {
          _lastTruckData!.forEach((key, value) {
            _updateSingleTruckMarker(key.toString(), value as Map);
          });
        }
      }
    });
  }

  void _listenToRoute() {
    if (widget.currentSessionId == null) return;
    _routeSubscription?.cancel();
    _routeSubscription = _database.ref('driver_routes/${widget.currentSessionId}').onValue.listen((event) {
      if (widget.testRoute != null) return; 
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        _lastSessionData = data;

        if (mounted) {
          setState(() {
            if (data['start_time'] != null) _startTime = data['start_time'];
            if (data['final_distance'] != null) {
              _distance = (data['final_distance'] as num).toDouble();
            } else if (data['total_distance'] != null) {
              _distance = (data['total_distance'] as num).toDouble();
            }
          });
        }

        if (data['route'] != null) {
          final Map routeData = data['route'] as Map;
          final List<Map> points = [];
          routeData.forEach((key, value) => points.add(value as Map));
          
          points.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
          
          if (mounted && points.isNotEmpty) {
            if (points.length != _lastPoints.length) {
              _updateRoutePolyline(points);
            }
            
            // PRIORITY: Use Firebase route points for historical polyline rendering,
            // but NEVER overwrite the current Driver marker with potentially stale Firebase data.
            // Local GPS stream handles real-time marker movement for minimal delay.
            
            _lastPoints = points;
          }
        }
        if (_managersReady) _updateSpecialMarkers(data);
      }
    });
  }

  void _onMapCreated(MapboxMap map) { mapboxMap = map; }

  void _onStyleLoaded(dynamic data) async {
    _driverSourceCreated = false;
    _routeSourceCreated = false;
    _specialMarkersCreated = false;

    try {
      await mapboxMap?.location.updateSettings(LocationComponentSettings(enabled: false, pulsingEnabled: false));
    } catch (e) {}
    await mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: _balintawakCenter), zoom: 14.5));
    try {
      await Future.delayed(const Duration(milliseconds: 800));
      _pointAnnotationManager = await mapboxMap!.annotations.createPointAnnotationManager();
    } catch (e) {}
    if (!mounted) return;
    _truckMarkers.clear();
    
    _liveDriverLabel = null;

    setState(() => _managersReady = true);
    
    if (_lastLocalPos != null) _updateLocalDriverMarker(_lastLocalPos!);
    if (_lastTruckData != null) _lastTruckData!.forEach((k, v) => _updateSingleTruckMarker(k.toString(), v as Map));
    if (_lastPoints.isNotEmpty) _updateRoutePolyline(_lastPoints);
    if (_lastSessionData != null) _updateSpecialMarkers(_lastSessionData!);
  }

  Future<void> _updateLocalDriverMarker(geo.Position pos) async {
    if (mapboxMap == null) return;

    final String sourceId = "driver-live-location-source";
    
    // DELAY DEBUG LOGS
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int gpsTs = pos.timestamp.millisecondsSinceEpoch;
    final int localDelay = now - gpsTs;

    debugPrint("--- REAL-TIME GPS UPDATE ---");
    debugPrint("GPS POSITION: ${pos.latitude}, ${pos.longitude}");
    debugPrint("GPS TIMESTAMP: ${pos.timestamp}");
    debugPrint("MARKER UPDATE TIME: ${DateTime.now()}");
    debugPrint("LOCAL DELAY: $localDelay ms");
    debugPrint("FOLLOW MODE ACTIVE: $_isFollowLocked");
    
    // Resolve identity info with priority
    // 1. Current Driver assignedTruckId (preferredTruck)
    // 2. Current active trip truckId (from _lastSessionData)
    // 3. Focus Truck ID (if valid)
    
    final String driverName = (_user?.name != null && _user!.name.trim().isNotEmpty) ? _user!.name : "DRIVER";
    String? currentAssignedTruckId = _user?.preferredTruck;
    String? tripTruckId = _lastSessionData?['truck_id']?.toString();
    String? focusTruckId = (widget.focusTruckId != null && widget.focusTruckId!.toUpperCase() != "UNKNOWN") ? widget.focusTruckId : null;
    
    // AUTHORITATIVE RESOLUTION
    String resolvedTruckId = currentAssignedTruckId ?? focusTruckId ?? tripTruckId ?? "N/A";
    
    if (resolvedTruckId.toUpperCase() == "UNKNOWN") {
      resolvedTruckId = "N/A";
    }

    final String labelText = "$driverName\n${resolvedTruckId.toUpperCase()}";
    
    // DEBUG LOGS
    debugPrint("==================================================");
    debugPrint("DRIVER: $driverName");
    debugPrint("CURRENT DRIVER ID: ${_user?.userId}");
    debugPrint("assignedTruckId (preferred): $currentAssignedTruckId");
    debugPrint("TRUCK DOC (tid used for meta): ${(widget.focusTruckId ?? currentAssignedTruckId ?? "Unknown").toUpperCase()}");
    debugPrint("ACTIVE TRIP truckId: $tripTruckId");
    debugPrint("WIDGET focusTruckId: ${widget.focusTruckId}");
    debugPrint("FINAL DISPLAY TRUCK ID: $resolvedTruckId");
    debugPrint("NUMBER OF OTHER TRUCK MARKERS: ${_truckMarkers.length}");
    debugPrint("==================================================");

    final geojson = {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature", 
          "geometry": {"type": "Point", "coordinates": [pos.longitude, pos.latitude]}, 
          "properties": {
            "name": "DRIVER", 
            "label": labelText,
            "status": _currentStatus
          }
        }
      ]
    };

    try {
      final style = mapboxMap!.style;
      bool sourceExists = await style.styleSourceExists(sourceId);
      
      if (!_driverSourceCreated || !sourceExists) {
        if (!sourceExists) {
          await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(geojson)));
        }

        if (!(await style.styleLayerExists("driver-live-location-halo"))) {
          await style.addLayer(CircleLayer(
            id: "driver-live-location-halo", 
            sourceId: sourceId, 
            circleRadius: 18.0, 
            circleOpacity: 0.3,
            circleStrokeWidth: 2.0,
            circleSortKey: 3100.0
          ));
        }

        if (!(await style.styleLayerExists("driver-live-location-circle"))) {
          await style.addLayer(CircleLayer(
            id: "driver-live-location-circle", 
            sourceId: sourceId, 
            circleRadius: 8.0, 
            circleColor: Colors.green.toARGB32(), 
            circleStrokeWidth: 3.0, 
            circleStrokeColor: Colors.white.toARGB32(), 
            circleSortKey: 3200.0
          ));
        }

        if (!(await style.styleLayerExists("driver-live-location-label"))) {
          await style.addLayer(SymbolLayer(
            id: "driver-live-location-label", 
            sourceId: sourceId, 
            textField: "{label}",
            textSize: 14.0, 
            textColor: Colors.green.toARGB32(), 
            textHaloColor: Colors.white.toARGB32(), 
            textHaloWidth: 2.0, 
            textAnchor: TextAnchor.BOTTOM, 
            textOffset: [0, -1.5], 
            symbolSortKey: 3300.0,
            textAllowOverlap: true
          ));
        }

        final statusColorExpression = [
          "match", ["get", "status"],
          "IDLE", "#FFFF00",
          "FULL", "#FF1493",
          "FINISHED", "#000000",
          "#00FF00" 
        ];

        await style.setStyleLayerProperty("driver-live-location-halo", "circle-color", statusColorExpression);
        await style.setStyleLayerProperty("driver-live-location-halo", "circle-stroke-color", statusColorExpression);

        if (mounted) setState(() => _driverSourceCreated = true);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(geojson));
      }

      // ENSURE CAMERA FOLLOWS IF LOCKED - Applied immediately after source update
      if (_isFollowLocked) {
        mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(pos.longitude, pos.latitude))));
      }
    } catch (e) {}
  }

  void _updateSpecialMarkers(Map data) async {
    if (mapboxMap == null) return;
    final String sourceId = "driver-special-markers-source";
    final List<Map<String, dynamic>> features = [];

    if (data['start_lat'] != null && data['start_lng'] != null) {
      features.add({
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [data['start_lng'], data['start_lat']]},
        "properties": {"label": "START POINT", "type": "START"}
      });
    }
    if (data['finish_lat'] != null && data['finish_lng'] != null) {
      features.add({
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [data['finish_lng'], data['finish_lat']]},
        "properties": {"label": "🏁 FINISH", "type": "FINISH"}
      });
    }

    if (features.isEmpty) return;
    final geojson = {"type": "FeatureCollection", "features": features};

    try {
      final style = mapboxMap!.style;
      bool sourceExists = await style.styleSourceExists(sourceId);
      
      if (!sourceExists) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(geojson)));
        
        if (!(await style.styleLayerExists("driver-special-circles"))) {
          await style.addLayer(CircleLayer(
            id: "driver-special-circles", sourceId: sourceId, 
            circleRadius: 8.0, circleStrokeWidth: 3.0, circleStrokeColor: Colors.white.toARGB32(),
            circleSortKey: 3000.0,
          ));
          await style.setStyleLayerProperty("driver-special-circles", "circle-color", 
            ["match", ["get", "type"], "START", "#2196F3", "#000000"] 
          );
        }
        if (!(await style.styleLayerExists("driver-special-labels"))) {
          await style.addLayer(SymbolLayer(
            id: "driver-special-labels", sourceId: sourceId, 
            textField: "{label}", textSize: 12.0, textHaloColor: Colors.white.toARGB32(), textHaloWidth: 2.5,
            textAnchor: TextAnchor.TOP, textOffset: [0, 1.0], symbolSortKey: 3010.0,
          ));
          await style.setStyleLayerProperty("driver-special-labels", "text-color", 
            ["match", ["get", "type"], "START", "#1976D2", "#000000"]
          );
        }
        if (mounted) setState(() => _specialMarkersCreated = true);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(geojson));
      }
    } catch (e) {}
  }

  void _updateSingleTruckMarker(String id, Map data) {
    if (!_managersReady || _pointAnnotationManager == null) return;
    
    // DEDUPLICATION: Do not render markers for the CURRENT driver or CURRENT truck
    final String currentDriverId = _user?.userId.toString() ?? "";
    final String recordDriverId = data['driver_id']?.toString() ?? "";
    
    final String truckId = (data['truck_id'] ?? id).toString().toUpperCase();
    final String targetId = (widget.focusTruckId ?? "Unknown").toUpperCase();
    final String assignedTruckId = (_user?.preferredTruck ?? "").toUpperCase();

    bool isCurrentDriver = (currentDriverId.isNotEmpty && recordDriverId == currentDriverId);
    bool isCurrentTruck = (truckId == targetId || (assignedTruckId.isNotEmpty && truckId == assignedTruckId));

    // DEBUG LOGS FOR DEDUPLICATION
    if (truckId.contains("GT-001") || truckId.contains("GT-007")) {
      debugPrint("DEDUPLICATION CHECK [$id / $truckId]: isCurrentDriver=$isCurrentDriver (Rec:$recordDriverId vs Cur:$currentDriverId), isCurrentTruck=$isCurrentTruck (Rec:$truckId vs Target:$targetId or Assigned:$assignedTruckId)");
    }

    if (isCurrentDriver || isCurrentTruck) {
      // If it's a stale record for the current driver/truck, REMOVE it from the map
      if (_truckMarkers.containsKey(id)) {
        debugPrint("DEDUPLICATION: Removing stale/current marker for $id ($truckId)");
        final marker = _truckMarkers[id]!;
        _pointAnnotationManager?.delete(marker);
        _truckMarkers.remove(id);
      }
      return;
    }

    final double lat = (data['latitude'] ?? 0.0).toDouble();
    final double lng = (data['longitude'] ?? 0.0).toDouble();
    if (lat == 0.0 || lng == 0.0) return;
    final point = Point(coordinates: Position(lng, lat));
    final String status = (data['status'] ?? "OFFLINE").toString().toUpperCase();
    final int color = status == "IDLE" ? Colors.orange.toARGB32() : Colors.green.toARGB32();

    if (_truckMarkers.containsKey(id)) {
      final marker = _truckMarkers[id]!;
      marker.geometry = point; marker.textField = "$truckId ($status)"; marker.textColor = color;
      _pointAnnotationManager?.update(marker);
    } else {
      _pointAnnotationManager?.create(PointAnnotationOptions(geometry: point, textField: "$truckId ($status)", textOffset: [0, 3.0], textColor: color, textSize: 11, iconSize: 0)).then((m) { if (m != null) _truckMarkers[id] = m; });
    }
  }

  void _updateRoutePolyline(List<Map> points) async {
    if (mapboxMap == null) return;
    if (points.isEmpty && _lastSessionData == null) {
      _clearRoute();
      return;
    }

    final List<Map> allPoints = [];
    if (_lastSessionData != null && _lastSessionData!['start_lat'] != null) {
      allPoints.add({
        'lat': _lastSessionData!['start_lat'],
        'lng': _lastSessionData!['start_lng'],
        'status': 'START',
        'color': 'BLUE',
        'timestamp': _lastSessionData!['timestamp'] ?? 0
      });
    }

    allPoints.addAll(points);

    if (_lastLocalPos != null) {
      allPoints.add({
        'lat': _lastLocalPos!.latitude,
        'lng': _lastLocalPos!.longitude,
        'status': _currentStatus,
        'color': _currentStatus == "IDLE" ? "YELLOW" : (_currentStatus == "FULL" ? "PINK" : "GREEN"),
        'timestamp': DateTime.now().millisecondsSinceEpoch
      });
    }

    allPoints.sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num));

    final List<Map> filtered = [];
    if (allPoints.isNotEmpty) {
      filtered.add(allPoints.first);
      for (int i = 1; i < allPoints.length; i++) {
        final prev = filtered.last;
        final curr = allPoints[i];
        
        final double lat = (curr['lat'] ?? 0.0).toDouble();
        final double lng = (curr['lng'] ?? 0.0).toDouble();
        final double prevLat = (prev['lat'] ?? 0.0).toDouble();
        final double prevLng = (prev['lng'] ?? 0.0).toDouble();

        final double d = geo.Geolocator.distanceBetween(prevLat, prevLng, lat, lng);
        final int timeDiff = (curr['timestamp'] as int) - (prev['timestamp'] as int);
        final double speedKmH = (curr['speed'] ?? 0.0).toDouble() * 3.6;

        // 1. FILTER: Outlier jump detection (Speed check)
        if (timeDiff > 0 && timeDiff < 10000 && d > 150) continue;

        // 2. FILTER: Jitter reduction (Speed + Distance)
        bool isStationary = speedKmH < 2.0;
        double threshold = isStationary ? 8.0 : 4.0;
        if (d < threshold && i != allPoints.length - 1 && prev['status'] == curr['status']) continue;

        filtered.add(curr);
      }
    }

    final List<Map> processed = [];
    if (filtered.isNotEmpty) {
      int start = 0;
      for (int i = 1; i <= filtered.length; i++) {
        if (i == filtered.length || filtered[i]['status'] != filtered[start]['status']) {
          final segment = filtered.sublist(start, i);
          // Epsilon 0.00004 (~4.5 meters) helps snap shaky trails into clean straight lines
          final simplified = _simplifyPoints(segment, 0.00004);
          if (processed.isNotEmpty) {
            processed.addAll(simplified.skip(1));
          } else {
            processed.addAll(simplified);
          }
          start = i;
        }
      }
    }

    final String sourceId = "driver-route-source";
    final List<Map<String, dynamic>> features = [];

    if (processed.length >= 2) {
      for (int i = 1; i < processed.length; i++) {
        final prev = processed[i - 1];
        final curr = processed[i];
        
        String color = (curr['color'] ?? 'GREEN').toString().toUpperCase();
        if (color == "BLUE") color = "GREEN"; 

        if (features.isNotEmpty && features.last['properties']['color'] == color) {
          final List coords = features.last['geometry']['coordinates'];
          coords.add([(curr['lng'] ?? 0.0).toDouble(), (curr['lat'] ?? 0.0).toDouble()]);
        } else {
          features.add({
            "type": "Feature",
            "geometry": {
              "type": "LineString",
              "coordinates": [
                [(prev['lng'] ?? 0.0).toDouble(), (prev['lat'] ?? 0.0).toDouble()],
                [(curr['lng'] ?? 0.0).toDouble(), (curr['lat'] ?? 0.0).toDouble()]
              ]
            },
            "properties": {"color": color}
          });
        }
      }
    }

    final featureCollection = {"type": "FeatureCollection", "features": features};

    try {
      final style = mapboxMap!.style;
      bool sourceCreated = await style.styleSourceExists(sourceId);
      if (!sourceCreated) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        
        if (!(await style.styleLayerExists("driver-route-layer"))) {
          await style.addLayer(LineLayer(
            id: "driver-route-layer", sourceId: sourceId, 
            lineColor: Colors.green.toARGB32(), lineWidth: 6.0, lineOpacity: 1.0, 
            lineCap: LineCap.ROUND, lineJoin: LineJoin.ROUND
          ));
          
          await style.setStyleLayerProperty("driver-route-layer", "line-color", [
            "match", ["get", "color"],
            "GREEN", "#4CAF50", 
            "YELLOW", "#FFEB3B", 
            "PINK", "#E91E63", 
            "BLACK", "#212121", 
            "#4CAF50"
          ]);
        }
        if (mounted) setState(() => _routeSourceCreated = true);
      } else { 
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection)); 
      }
    } catch (e) {}
  }

  List<Map> _simplifyPoints(List<Map> points, double epsilon) {
    if (points.length < 3) return points;
    int index = -1;
    double maxDist = 0;
    for (int i = 1; i < points.length - 1; i++) {
      double d = _perpendicularDistance(points[i], points.first, points.last);
      if (d > maxDist) { index = i; maxDist = d; }
    }
    if (maxDist > epsilon) {
      List<Map> res1 = _simplifyPoints(points.sublist(0, index + 1), epsilon);
      List<Map> res2 = _simplifyPoints(points.sublist(index), epsilon);
      return [...res1.sublist(0, res1.length - 1), ...res2];
    }
    return [points.first, points.last];
  }

  double _perpendicularDistance(Map p, Map start, Map end) {
    double x = (p['lng'] as num).toDouble(); double y = (p['lat'] as num).toDouble();
    double x1 = (start['lng'] as num).toDouble(); double y1 = (start['lat'] as num).toDouble();
    double x2 = (end['lng'] as num).toDouble(); double y2 = (end['lat'] as num).toDouble();
    double dx = x2 - x1; double dy = y2 - y1;
    if (dx == 0 && dy == 0) return sqrt(pow(x - x1, 2) + pow(y - y1, 2));
    double t = ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy);
    if (t < 0) return sqrt(pow(x - x1, 2) + pow(y - y1, 2));
    if (t > 1) return sqrt(pow(x - x2, 2) + pow(y - y2, 2));
    return sqrt(pow(x - (x1 + t * dx), 2) + pow(y - (y1 + t * dy), 2));
  }

  void _clearRoute() async {
    if (mapboxMap == null) return;
    try { await mapboxMap!.style.setStyleSourceProperty("driver-route-source", "data", jsonEncode({"type": "FeatureCollection", "features": []})); } catch (e) {}
  }

  Widget _buildLegendItem(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black87)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: FadeSlideEntrance(
        child: Stack(
          children: [
            _buildMap(),
            _buildFloatingHeader(),
            if (!widget.isEmbedded) _buildLegend(),
            _buildMapControls(),
            
            if (!widget.isEmbedded)
              Positioned.fill(
                child: DraggableScrollableSheet(
                  initialChildSize: 0.18,
                  minChildSize: 0.18,
                  maxChildSize: 0.85,
                  snap: true,
                  snapSizes: const [0.18, 0.45, 0.85],
                  builder: (context, scrollController) => PointerInterceptor(
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
                        boxShadow: [
                          BoxShadow(color: Colors.black26, blurRadius: 25, spreadRadius: 5, offset: Offset(0, -5))
                        ],
                      ),
                      child: _buildSwipeUpContent(scrollController),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return MapWidget(
      onMapCreated: _onMapCreated, 
      onStyleLoadedListener: _onStyleLoaded, 
      viewport: CameraViewportState(center: Point(coordinates: _balintawakCenter), zoom: 14.5)
    );
  }

  Widget _buildSwipeUpContent(ScrollController scrollController) {
    return ListView(
      controller: scrollController,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        const SizedBox(height: 12),
        Center(child: Container(width: 50, height: 6, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)))),
        const SizedBox(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _lastSessionData == null ? "Searching Tracking..." : "Live Route Tracking", 
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))
              ),
              Text(
                _lastSessionData == null ? "Establishing GPS connection" : "Tracking assigned truck", 
                style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600)
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        
        _buildInfoCard(
          title: "Trip Information",
          icon: Icons.info_outline_rounded,
          color: AppColors.tealText,
          content: [
            _buildInfoRow("Truck Number", _user?.preferredTruck ?? "Unknown", color: AppColors.tealText),
            const Divider(height: 24),
            _buildInfoRow("Plate Number", _truckPlateNumber ?? "N/A", isBold: true),
            const Divider(height: 24),
            _buildInfoRow("Start Time", _startTime),
            const Divider(height: 24),
            _buildInfoRow("Total Distance", "${_distance.toStringAsFixed(1)} km", color: Colors.orangeAccent.shade200),
          ],
        ),
        
        const SizedBox(height: 20),
        
        _buildInfoCard(
          title: "GPS Status",
          icon: Icons.gps_fixed_rounded,
          color: Colors.green, 
          content: [
            _buildGpsSignalRow(),
            const Divider(height: 24),
            _buildInfoRow("Accuracy", "±${_lastLocalPos?.accuracy.toInt() ?? 5} meters"),
            const Divider(height: 24),
            _buildInfoRow("Speed", "${_currentSpeed.toStringAsFixed(0)} km/h"),
          ],
        ),
        
        const SizedBox(height: 120),
      ],
    );
  }

  Widget _buildInfoCard({required String title, required IconData icon, required Color color, required List<Widget> content}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow, 
        border: Border.all(color: Colors.grey.shade100, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 12),
              Text(title, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: color == Colors.black ? Colors.black : color.darken(0.3))),
            ],
          ),
          const SizedBox(height: 24),
          ...content,
        ],
      ),
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

  Widget _buildGpsSignalRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text("Signal Strength", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 14)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20), 
            border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Text("Strong", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.green, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMapControls() {
    return Positioned(
      bottom: widget.isEmbedded ? 20 : 160, 
      right: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HoverZoomLink(
            onTap: () {
              setState(() => _isFollowLocked = !_isFollowLocked);
              if (_isFollowLocked && _lastLocalPos != null) {
                mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(_lastLocalPos!.longitude, _lastLocalPos!.latitude)), zoom: 16.5));
              }
            },
            child: Container(
              width: widget.isEmbedded ? 48 : 64, height: widget.isEmbedded ? 48 : 64,
              decoration: BoxDecoration(
                color: _isFollowLocked ? const Color(0xFF00C853) : Colors.white,
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ),
              child: Icon(
                _isFollowLocked ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                color: _isFollowLocked ? Colors.white : const Color(0xFF1A1A1A),
                size: widget.isEmbedded ? 24 : 28,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _HoverZoomLink(
            onTap: () {
              mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(121.1623, 13.9413)), zoom: 14.5));
            },
            child: Container(
              width: widget.isEmbedded ? 48 : 64, height: widget.isEmbedded ? 48 : 64,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ),
              child: Icon(Icons.map_outlined, color: const Color(0xFF1A1A1A), size: widget.isEmbedded ? 24 : 28),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingHeader() {
    if (widget.isEmbedded) return const SizedBox.shrink();

    return Positioned(
      top: 24, left: 16, right: 16,
      child: SafeArea(
        child: Row(
          children: [
            if (widget.onBack != null) 
              _HoverZoomLink(
                onTap: widget.onBack!, 
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white, 
                    shape: BoxShape.circle,
                    boxShadow: AppTheme.pulidongShadow,
                  ), 
                  child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A1A1A), size: 18)
                )
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: AppTheme.pulidongShadow,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("Live Tracking", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)),
                    Text("Live GPS connected", style: TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF00695C), 
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ), 
              child: const Icon(Icons.gps_fixed_rounded, color: Colors.white, size: 18)
            )
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    return Positioned(
      top: 160, right: 16,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9), 
          borderRadius: BorderRadius.circular(20), 
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))]
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildLegendItem(Colors.green, "Active"),
            _buildLegendItem(Colors.yellow, "Idle"),
            _buildLegendItem(Colors.pinkAccent, "Full"),
            _buildLegendItem(Colors.black, "Finish"),
            _buildLegendItem(Colors.blue, "Start"),
          ],
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
