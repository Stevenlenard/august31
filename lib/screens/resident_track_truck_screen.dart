import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../utils/prediction_engine.dart';
import '../utils/app_theme.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../widgets/fade_slide_entrance.dart';

class ResidentTrackTruckScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const ResidentTrackTruckScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<ResidentTrackTruckScreen> createState() => _ResidentTrackTruckScreenState();
}

class _ResidentTrackTruckScreenState extends State<ResidentTrackTruckScreen> with TickerProviderStateMixin {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  MapboxMap? mapboxMap;
  List<Map<dynamic, dynamic>> _trucks = [];
  Map<String, dynamic> _allTrucksRegistry = {};
  Map<String, dynamic> _liveLocations = {};
  final Set<String> _comparingTrucks = {};
  geo.Position? _residentPosition;
  
  final Map<String, StreamSubscription> _routeSubscriptions = {};
  final Map<String, Position?> _sessionStartPoints = {}; 
  final Map<String, List<Map>> _lastRoutePoints = {}; 

  bool _truckLayersCreated = false;
  bool _isFollowLocked = true;
  final Position _balintawakCenter = Position(121.1623, 13.9413);

  // Animation for Header Circles
  late AnimationController _circleController;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _listenToTrucks();
    _getResidentLocation();
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();
  }

  @override
  void dispose() {
    _routeSubscriptions.forEach((key, sub) => sub.cancel());
    _circleController.dispose();
    super.dispose();
  }

  void _loadUser() async {
    // Note: _user was marked unused, keeping it removed to clean up
  }

  Future<void> _getResidentLocation() async {
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    
    geo.Geolocator.getPositionStream().listen((pos) {
      if (mounted) {
        setState(() => _residentPosition = pos);
        _updateTruckMarkers();
        if (_isFollowLocked && mapboxMap != null) {
          mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(pos.longitude, pos.latitude))));
        }
      }
    });
    
    geo.Position startPos = await geo.Geolocator.getCurrentPosition();
    if (mounted) {
      setState(() => _residentPosition = startPos);
    }
  }

  void _listenToTrucks() {
    _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists) {
        _allTrucksRegistry = Map<String, dynamic>.from(event.snapshot.value as Map);
        _processMergedTrucks();
      }
    });

    _database.ref('truck_locations').onValue.listen((event) {
      _liveLocations = event.snapshot.exists ? Map<String, dynamic>.from(event.snapshot.value as Map) : {};
      _processMergedTrucks();
    });
  }

  void _processMergedTrucks() {
    final List<Map<dynamic, dynamic>> mergedList = [];
    
    _allTrucksRegistry.forEach((id, truckData) {
      final String tid = id.toString().toUpperCase();
      final Map rawLive = _liveLocations[tid] ?? {};
      final liveData = Map<String, dynamic>.from(rawLive);
      
      mergedList.add({
        ...Map<String, dynamic>.from(truckData as Map),
        ...liveData,
        'truck_id': tid,
        'status': liveData['isOnline'] == true ? (liveData['status'] ?? 'ACTIVE') : 'OFFLINE',
      });
    });

    if (mounted) {
      setState(() => _trucks = mergedList);
      _updateTruckMarkers();
      
      final activeTruckIds = mergedList.where((t) => t['isOnline'] == true).map((t) => t['truck_id'] as String).toSet();
      final trucksToClear = _routeSubscriptions.keys.where((id) => !activeTruckIds.contains(id)).toList();
      
      for (var id in trucksToClear) {
        _routeSubscriptions[id]?.cancel();
        _routeSubscriptions.remove(id);
        _clearTruckRoute(id);
      }

      for (var t in mergedList) {
        if (t['isOnline'] != true) continue;
        final String tid = t['truck_id'];
        final String? sid = t['current_session'];
        if (sid != null) {
          if (!_routeSubscriptions.containsKey(tid)) _setupRouteSubscription(tid, sid);
        } else {
          _routeSubscriptions[tid]?.cancel();
          _routeSubscriptions.remove(tid);
          _clearTruckRoute(tid);
        }
      }
    }
  }

  void _setupRouteSubscription(String truckId, String sessionId) {
    _routeSubscriptions[truckId]?.cancel();
    _routeSubscriptions[truckId] = _database.ref('driver_routes/$sessionId/route').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List<Map> points = [];
        data.forEach((key, value) => points.add(value as Map));
        points.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
        
        _lastRoutePoints[truckId] = points;

        if (_comparingTrucks.contains(truckId)) {
          _updateRoutePolyline(truckId, points);
        }
      }
    });

    _database.ref('driver_routes/$sessionId').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        if (data['start_lat'] != null && data['start_lng'] != null) {
          if (mounted) {
            setState(() => _sessionStartPoints[truckId] = Position(data['start_lng'], data['start_lat']));
            _updateTruckMarkers();
          }
        }
      }
    });
  }

  void _clearTruckRoute(String truckId) async {
     if (mapboxMap == null) return;
     try {
       final style = mapboxMap!.style;
       final String sourceId = "route-source-$truckId";
       if (await style.styleSourceExists(sourceId)) {
         await style.setStyleSourceProperty(sourceId, "data", jsonEncode({"type": "FeatureCollection", "features": []}));
       }
     } catch (_) {}
     if (mounted) {
       setState(() => _sessionStartPoints.remove(truckId));
       _updateTruckMarkers();
     }
  }

  void _updateRoutePolyline(String truckId, List<Map> points) async {
    if (mapboxMap == null || points.length < 2) return;
    points.sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num));

    final String sourceId = "route-source-$truckId";
    final List<Map<String, dynamic>> segments = [];

    final List<Map> smoothedPoints = [];
    if (points.isNotEmpty) {
      smoothedPoints.add(points.first);
      for (int i = 1; i < points.length; i++) {
        final prev = smoothedPoints.last;
        final curr = points[i];
        final double d = geo.Geolocator.distanceBetween(
          (prev['lat'] ?? 0.0).toDouble(), (prev['lng'] ?? 0.0).toDouble(),
          (curr['lat'] ?? 0.0).toDouble(), (curr['lng'] ?? 0.0).toDouble()
        );
        if (d > 5.0 || i == points.length - 1) smoothedPoints.add(curr);
      }
    }

    for (int i = 1; i < smoothedPoints.length; i++) {
      final prev = smoothedPoints[i - 1];
      final curr = smoothedPoints[i];
      final double prevLng = (prev['lng'] ?? 0.0).toDouble();
      final double prevLat = (prev['lat'] ?? 0.0).toDouble();
      final double currLng = (curr['lng'] ?? 0.0).toDouble();
      final double currLat = (curr['lat'] ?? 0.0).toDouble();
      final int prevTs = (prev['timestamp'] ?? 0) as int;
      final int currTs = (curr['timestamp'] ?? 0) as int;
      final String color = (curr['color'] ?? 'GREEN').toString().toUpperCase();
      final bool isGap = (currTs - prevTs) > 60000;

      if (!isGap) {
        if (segments.isNotEmpty && segments.last['properties']['color'] == color) {
          final List coords = segments.last['geometry']['coordinates'];
          if (coords.isEmpty || coords.last[0] != currLng || coords.last[1] != currLat) coords.add([currLng, currLat]);
        } else {
          segments.add({
            "type": "Feature",
            "geometry": { "type": "LineString", "coordinates": [[prevLng, prevLat], [currLng, currLat]] },
            "properties": {"color": color}
          });
        }
      }
    }

    final featureCollection = {"type": "FeatureCollection", "features": segments};
    try {
      final style = mapboxMap!.style;
      if (!(await style.styleSourceExists(sourceId))) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        await style.addLayer(LineLayer(id: "route-layer-$truckId", sourceId: sourceId, lineColor: Colors.green.toARGB32(), lineWidth: 8.0, lineOpacity: 0.9, lineCap: LineCap.ROUND, lineJoin: LineJoin.ROUND));
        await style.setStyleLayerProperty("route-layer-$truckId", "line-color", ["match", ["get", "color"], "GREEN", "#00FF00", "YELLOW", "#FFFF00", "PINK", "#FF1493", "BLACK", "#000000", "BLUE", "#0000FF", "#00FF00"]);
      } else { await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection)); }
    } catch (_) {}
  }

  void _recenterToBalintawak() { mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: _balintawakCenter), zoom: 14.5)); }
  void _recenterToResident() { if (_residentPosition == null) return; mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(_residentPosition!.longitude, _residentPosition!.latitude)), zoom: 16.5)); }
  void _focusOnTruck(Map<dynamic, dynamic> truck) {
    final double lat = (truck['latitude'] ?? 0.0).toDouble();
    final double lng = (truck['longitude'] ?? 0.0).toDouble();
    if (lat == 0 || lng == 0) return;
    mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat)), zoom: 17.5));
  }

  void _onMapCreated(MapboxMap map) { mapboxMap = map; }
  void _onStyleLoaded(dynamic data) async {
    mapboxMap?.location.updateSettings(LocationComponentSettings(enabled: false, pulsingEnabled: false));
    _updateTruckMarkers();
    _recenterToBalintawak();
  }

  bool _isUpdatingMarkers = false;
  void _updateTruckMarkers() async {
    if (mapboxMap == null || _isUpdatingMarkers) return;
    _isUpdatingMarkers = true;
    final String sourceId = "trucks-live-location-source";
    final List<Map<String, dynamic>> features = _trucks.where((t) => (t['latitude'] ?? 0) != 0 && (t['longitude'] ?? 0) != 0).map((truck) {
      return { "type": "Feature", "geometry": {"type": "Point", "coordinates": [(truck['longitude'] ?? 0.0).toDouble(), (truck['latitude'] ?? 0.0).toDouble()]}, "properties": {"type": "TRUCK", "truckId": truck['truck_id'].toString(), "label": "DRIVER\n${truck['truck_id']}"} };
    }).toList();

    for (var entry in _sessionStartPoints.entries) {
      if (entry.value != null && _comparingTrucks.contains(entry.key)) {
        features.add({ "type": "Feature", "geometry": {"type": "Point", "coordinates": [entry.value!.lng, entry.value!.lat]}, "properties": {"type": "SESSION_START", "label": "START / ${entry.key}"} });
      }
    }

    final residentFeature = _residentPosition == null ? null : { "type": "Feature", "geometry": {"type": "Point", "coordinates": [_residentPosition!.longitude, _residentPosition!.latitude]}, "properties": {"label": "YOU / RESIDENT"} };

    try {
      final style = mapboxMap!.style;
      if (!_truckLayersCreated || !(await style.styleLayerExists("trucks-live-location-circle"))) {
        try { await style.removeStyleLayer("trucks-live-location-circle"); } catch (_) {}
        try { await style.removeStyleLayer("trucks-live-location-label"); } catch (_) {}
        try { await style.removeStyleLayer("resident-marker-circle"); } catch (_) {}
        try { await style.removeStyleLayer("resident-marker-label"); } catch (_) {}
        try { await style.removeStyleLayer("session-start-circle"); } catch (_) {}
        try { await style.removeStyleLayer("session-start-label"); } catch (_) {}
        try { await style.removeStyleSource(sourceId); } catch (_) {}
        try { await style.removeStyleSource("resident-marker-source"); } catch (_) {}

        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode({"type": "FeatureCollection", "features": features})));
        await style.addSource(GeoJsonSource(id: "resident-marker-source", data: jsonEncode({"type": "FeatureCollection", "features": residentFeature != null ? [residentFeature] : []})));

        await style.addLayer(CircleLayer(id: "resident-marker-circle", sourceId: "resident-marker-source", circleRadius: 7.0, circleColor: Colors.blue.toARGB32(), circleStrokeWidth: 3.0, circleStrokeColor: Colors.white.toARGB32(), circleSortKey: 2000.0));
        await style.addLayer(SymbolLayer(id: "resident-marker-label", sourceId: "resident-marker-source", textField: "{label}", textSize: 10.0, textColor: Colors.blue.toARGB32(), textHaloColor: Colors.white.toARGB32(), textHaloWidth: 2.0, textAnchor: TextAnchor.TOP, textOffset: [0, 1.2], symbolSortKey: 2000.0));
        await style.addLayer(CircleLayer(id: "trucks-live-location-circle", sourceId: sourceId, circleRadius: 9.0, circleColor: Colors.green.toARGB32(), circleStrokeWidth: 3.0, circleStrokeColor: Colors.white.toARGB32(), circleSortKey: 3000.0, filter: ["==", ["get", "type"], "TRUCK"]));
        await style.addLayer(CircleLayer(id: "session-start-circle", sourceId: sourceId, circleRadius: 7.0, circleColor: Colors.green.shade800.toARGB32(), circleStrokeWidth: 2.0, circleStrokeColor: Colors.white.toARGB32(), circleSortKey: 2500.0, filter: ["==", ["get", "type"], "SESSION_START"]));
        await style.addLayer(SymbolLayer(id: "trucks-live-location-label", sourceId: sourceId, textField: "{label}", textSize: 13.0, textColor: Colors.green.toARGB32(), textHaloColor: Colors.white.toARGB32(), textHaloWidth: 2.0, textAnchor: TextAnchor.BOTTOM, textOffset: [0, -1.2], symbolSortKey: 3000.0, textAllowOverlap: true, filter: ["==", ["get", "type"], "TRUCK"]));
        await style.addLayer(SymbolLayer(id: "session-start-label", sourceId: sourceId, textField: "{label}", textSize: 10.0, textColor: Colors.green.shade800.toARGB32(), textHaloColor: Colors.white.toARGB32(), textHaloWidth: 2.0, textAnchor: TextAnchor.BOTTOM, textOffset: [0, -1.0], symbolSortKey: 2500.0, filter: ["==", ["get", "type"], "SESSION_START"]));
        if (mounted) setState(() => _truckLayersCreated = true);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode({"type": "FeatureCollection", "features": features}));
        await style.setStyleSourceProperty("resident-marker-source", "data", jsonEncode({"type": "FeatureCollection", "features": residentFeature != null ? [residentFeature] : []}));
      }
    } catch (_) { if (mounted) setState(() => _truckLayersCreated = false); } finally { _isUpdatingMarkers = false; }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final bool isDesktop = constraints.maxWidth >= 900;
      return FadeSlideEntrance(
        child: Scaffold(
          backgroundColor: AppColors.dashboardBg, 
          body: isDesktop ? _buildDesktopLayout() : _buildMobileLayout(), 
        ),
      );
    });
  }

  Widget _buildMapControls({double bottom = 220}) { 
    return Positioned(
      bottom: bottom, 
      right: 16, 
      child: Column(
        mainAxisSize: MainAxisSize.min, 
        children: [
          // FOLLOW TOGGLE (TARGET ICON)
          _HoverZoomLink(
            onTap: () {
              setState(() => _isFollowLocked = !_isFollowLocked);
              if (_isFollowLocked && _residentPosition != null) {
                mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(_residentPosition!.longitude, _residentPosition!.latitude)), zoom: 16.5));
                mapboxMap?.gestures.updateSettings(GesturesSettings(scrollEnabled: false, rotateEnabled: false, pitchEnabled: false));
              } else {
                mapboxMap?.gestures.updateSettings(GesturesSettings(scrollEnabled: true, rotateEnabled: true, pitchEnabled: true));
              }
            },
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: _isFollowLocked ? const Color(0xFF00C853) : Colors.white,
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ),
              child: Icon(
                _isFollowLocked ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                color: _isFollowLocked ? Colors.white : const Color(0xFF1A1A1A),
                size: 28,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // RECENTER (MAP ICON)
          _HoverZoomLink(
            onTap: _recenterToBalintawak,
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ),
              child: const Icon(Icons.map_outlined, color: Color(0xFF1A1A1A), size: 28),
            ),
          ),
          const SizedBox(height: 12),
          // GUIDE ICON
          _HoverZoomLink(
            onTap: _showTrackingGuide,
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ),
              child: const Icon(Icons.description_outlined, color: Color(0xFF1A1A1A), size: 28),
            ),
          ),
        ]
      )
    ); 
  }

  Widget _buildDesktopLayout() {
    return Row(children: [
      Expanded(child: Stack(children: [
        Positioned.fill(child: MapWidget(onMapCreated: _onMapCreated, onStyleLoadedListener: _onStyleLoaded, viewport: CameraViewportState(center: Point(coordinates: _balintawakCenter), zoom: 14.5))), 
        _buildMapControls(bottom: 20),
        _buildFloatingHeader(), 
        _buildDebugOverlay()
      ])),
      Container(width: 400, decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20, offset: Offset(-5, 0))]), child: _buildFleetStatusContent(null))
    ]);
  }

  Widget _buildMobileLayout() {
    return Stack(children: [
      Positioned.fill(child: Stack(
        children: [
          Positioned.fill(child: MapWidget(onMapCreated: _onMapCreated, onStyleLoadedListener: _onStyleLoaded, viewport: CameraViewportState(center: Point(coordinates: _balintawakCenter), zoom: 14.5))),
          _buildMapControls(bottom: 210),
        ],
      )),
      _buildFloatingHeader(),
      _buildDebugOverlay(),
      Positioned.fill(child: DraggableScrollableSheet(
        initialChildSize: 0.18, 
        minChildSize: 0.18,
        maxChildSize: 0.95,
        snap: true,
        snapSizes: const [0.18, 0.45, 0.95],
        builder: (context, scrollController) => PointerInterceptor(child: Container(decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(40)), boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 25, spreadRadius: 5, offset: Offset(0, -5))]), child: _buildFleetStatusContent(scrollController, isMobile: true)))))
    ]);
  }

  Widget _buildDebugOverlay() {
    final active = _trucks.where((t) => (t['latitude'] ?? 0) != 0).toList();
    return Positioned(top: 100, right: 20, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text("UNITS: ${_trucks.length}", style: const TextStyle(color: Colors.white, fontSize: 10)), Text("GPS: ${active.length}", style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold))])));
  }

  Widget _buildFloatingHeader() {
    return Positioned(
      top: 24, left: 16, right: 16,
      child: SafeArea(
        child: Row(
          children: [
            if (widget.onBack != null) 
              _HoverZoomLink(
                onTap: widget.onBack!, 
                child: Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white, 
                    shape: BoxShape.circle,
                    boxShadow: AppTheme.pulidongShadow,
                  ), 
                  child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A1A1A), size: 24)
                )
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: AppTheme.pulidongShadow,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("Track Fleet", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)),
                    Text("Live GPS connected", style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF00695C), 
                shape: BoxShape.circle,
                boxShadow: AppTheme.pulidongShadow,
              ), 
              child: const Icon(Icons.gps_fixed_rounded, color: Colors.white, size: 24)
            )
          ],
        ),
      ),
    );
  }

  Widget _buildFleetStatusContent(ScrollController? scrollController, {bool isMobile = false}) {
    return ListView(controller: scrollController, physics: const BouncingScrollPhysics(), padding: EdgeInsets.zero, children: [
      if (isMobile) ...[const SizedBox(height: 12), Center(child: Container(width: 50, height: 6, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10))))],
      const SizedBox(height: 32),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 28), child: Text("Active Fleet Status", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))),
      const SizedBox(height: 20),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(children: _trucks.isEmpty ? [const Padding(padding: EdgeInsets.all(60), child: Center(child: Text("Scanning for active units...", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500))))] : _trucks.map((truck) => _buildOrganizedTruckCard(truck)).toList())),
      const SizedBox(height: 120)
    ]);
  }

  Widget _buildOrganizedTruckCard(Map<dynamic, dynamic> truck) {
    final String tid = truck['truck_id'].toString();
    final String license = (truck['license_number'] ?? 'N/A').toString();
    final String driver = (truck['driver_name'] ?? 'Driver').toString();
    final String status = (truck['status'] ?? 'IDLE').toString().toUpperCase();
    final bool isActive = status == 'ACTIVE' || status == 'COLLECTING';
    final Color statusColor = isActive ? const Color(0xFF00C853) : Colors.grey.shade400;
    
    final double speed = (truck['speed'] ?? 0.0).toDouble();
    final double dist = (truck['distance'] ?? 0.0).toDouble();
    final double fuel = (truck['fuel_level'] ?? 0.0).toDouble();
    final int stops = (truck['stops_count'] ?? 0) as int;
    
    String eta = isActive ? "${PredictionEngine.estimateArrivalTime(dist > 0 ? dist : 2.5, [speed > 5 ? speed : 15.0]).toStringAsFixed(0)} mins" : "--";
    String lastUpdate = truck['updatedAt'] != null ? "just now" : "Offline";

    return _HoverZoomCard(
      onTap: () => _focusOnTruck(truck),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16), 
        padding: const EdgeInsets.all(24), 
        decoration: BoxDecoration(
          color: Colors.white, 
          borderRadius: BorderRadius.circular(32), 
          boxShadow: AppTheme.pulidongShadow,
          border: Border.all(color: Colors.grey.shade50, width: 1)
        ), 
        child: Column(children: [
          // Top Row: Icon, Name/License, Status
          Row(children: [
            Container(
              padding: const EdgeInsets.all(12), 
              decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(16)), 
              child: const Icon(Icons.local_shipping_rounded, color: Color(0xFF2196F3), size: 28)
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(driver, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))), 
              Text("$tid | $license", style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600))
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), 
              decoration: BoxDecoration(color: statusColor.withAlpha(20), borderRadius: BorderRadius.circular(12)), 
              child: Text(status, style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.w900))
            ),
          ]),
          
          const SizedBox(height: 24),
          
          // Middle Info: Location, Speed, Driver
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildMetricsInfo(Icons.location_on_rounded, Colors.redAccent, "Location", (truck['current_purok'] ?? "Balintawak").toString()),
            _buildMetricsInfo(Icons.wb_cloudy_rounded, Colors.blueAccent, "Speed", "${speed.toStringAsFixed(0)} km/h"),
            _buildMetricsInfo(Icons.person_rounded, Colors.indigoAccent, "Driver", driver),
          ]),
          
          const SizedBox(height: 20),
          
          // Metrics Pill Row
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.grey.shade100)
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _buildPillMetric(Icons.straighten_rounded, Colors.green, "DISTANCE", "${dist.toStringAsFixed(1)} km"),
              Container(width: 1, height: 20, color: Colors.grey.shade300),
              _buildPillMetric(Icons.local_gas_station_rounded, Colors.orange, "FUEL", "${fuel.toStringAsFixed(1)} L"),
              Container(width: 1, height: 20, color: Colors.grey.shade300),
              _buildPillMetric(Icons.pause_circle_filled_rounded, Colors.red, "STOPS", "$stops"),
            ]),
          ),
          
          const SizedBox(height: 20),
          
          // Action Buttons
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTapDown: (details) => _showHistoryOverlay(context, tid, details),
                child: _buildSecondaryButton("HISTORY", Icons.history_rounded, () {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: _buildPrimaryButton(
                _comparingTrucks.contains(tid) ? "HIDE PATH" : "COMPARE PATH",
                Icons.near_me_rounded, 
                _comparingTrucks.contains(tid) ? Colors.orange : const Color(0xFF00C853), 
                () => _togglePath(tid)
              ),
            ),
          ]),
          
          const SizedBox(height: 20),
          
          // Footer
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildFooterInfo(Icons.access_time_rounded, "Last Update: $lastUpdate"),
            _buildFooterInfo(null, "Start: --:--"),
            _buildFooterInfo(null, "ETA: $eta", isTeal: true),
          ]),
        ])),
    );
  }

  Widget _buildMetricsInfo(IconData icon, Color color, String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1A1A1A))),
    ]);
  }

  Widget _buildPillMetric(IconData icon, Color color, String label, String value) {
    return Column(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 8, color: Colors.grey, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ]),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF2196F3))),
    ]);
  }

  Widget _buildFooterInfo(IconData? icon, String text, {bool isTeal = false}) {
    return Row(children: [
      if (icon != null) ...[Icon(icon, size: 12, color: Colors.grey), const SizedBox(width: 4)],
      Text(text, style: TextStyle(
        fontSize: 10, 
        color: isTeal ? const Color(0xFF00796B) : Colors.grey, 
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2
      )),
    ]);
  }

  Widget _buildSecondaryButton(String label, IconData icon, VoidCallback onTap) {
    return _HoverZoomLink(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F2F5),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: const Color(0xFF1A1A1A), size: 16),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w900, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildPrimaryButton(String label, IconData icon, Color color, VoidCallback onTap) {
    bool isOrange = label.contains("HIDE");
    return _HoverZoomLink(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isOrange 
              ? [const Color(0xFFFF9800), const Color(0xFFE65100)] // Orange Gradient
              : [AppColors.loginButtonStart, AppColors.loginButtonEnd], // Green Gradient (Logout Style)
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: (isOrange ? const Color(0xFFE65100) : AppColors.loginButtonEnd).withAlpha(60), 
              blurRadius: 10, 
              offset: const Offset(0, 4)
            )
          ],
        ),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
        ]),
      ),
    );
  }

  void _togglePath(String truckId) {
    if (!_comparingTrucks.contains(truckId) && !_lastRoutePoints.containsKey(truckId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("No active path data.", style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }
    setState(() {
      if (_comparingTrucks.contains(truckId)) {
        _comparingTrucks.remove(truckId);
        _clearTruckRoute(truckId);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Path hidden", style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: const Color(0xFFE65100),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 1),
            margin: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } else {
        _comparingTrucks.add(truckId);
        if (_lastRoutePoints.containsKey(truckId)) {
          _updateRoutePolyline(truckId, _lastRoutePoints[truckId]!);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Path data shown", style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: const Color(0xFF00897B),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 1),
            margin: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      _updateTruckMarkers();
    });
  }

  void _showHistoryOverlay(BuildContext context, String truckId, TapDownDetails details) {
    final List<Map> history = _lastRoutePoints[truckId] ?? [];
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      // Para sa Mobile: Gumamit ng BottomSheet para siguradong makikita
      _showStyledBottomSheet(
        title: "Activity Log",
        children: [
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text("No recent data recorded.", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500))),
            )
          else
            ...history.reversed.take(5).map((point) => Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Container(
                  width: 10, height: 10, 
                  decoration: BoxDecoration(
                    color: (point['color'] == 'PINK' ? Colors.pink : const Color(0xFF00C853)),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("At ${point['purok'] ?? 'Balintawak'}", style: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 13, fontWeight: FontWeight.w800)),
                      const Text("Collected recently", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ]),
            )),
        ],
      );
    } else {
      // Para sa Desktop: Manatili sa Floating Overlay
      OverlayEntry? overlayEntry;
      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          top: details.globalPosition.dy - 160,
          left: details.globalPosition.dx - 110,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 220,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: const Border(top: BorderSide(color: Color(0xFF00897B), width: 4)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  )
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text("ACTIVITY LOG", style: TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.5)),
                    GestureDetector(
                      onTap: () => overlayEntry?.remove(),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                        child: const Icon(Icons.close_rounded, color: Colors.grey, size: 14)
                      )
                    ),
                  ]),
                  const Divider(height: 24, thickness: 1, color: Color(0xFFF5F5F5)),
                  if (history.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text("No recent data recorded.", style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.w500)),
                    )
                  else
                    ...history.reversed.take(3).map((point) => Container(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(children: [
                        Container(
                          width: 8, height: 8, 
                          decoration: BoxDecoration(
                            color: (point['color'] == 'PINK' ? Colors.pink : const Color(0xFF00C853)),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("At ${point['purok'] ?? 'Balintawak'}", style: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 11, fontWeight: FontWeight.w800)),
                              const Text("Collected just now", style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ]),
                    )),
                ],
              ),
            ),
          ),
        ),
      );
      Overlay.of(context).insert(overlayEntry);
    }
  }

  void _showTrackingGuide() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.85,
          constraints: const BoxConstraints(maxWidth: 450),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Tracking Guide",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.tealText),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                "Learn how to monitor garbage trucks in real-time and use the advanced tracking features.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 24),
              _buildGuideSection("Legend", [
                _buildGuideItem(Icons.circle, "Green: Active collection", color: Colors.green),
                _buildGuideItem(Icons.circle, "Yellow: Idle / Signal issue", color: Colors.yellow),
                _buildGuideItem(Icons.circle, "Magenta: Truck is FULL", color: Colors.pinkAccent),
                _buildGuideItem(Icons.linear_scale, "Dashed: Signal gap detected", color: Colors.grey),
              ]),
              const SizedBox(height: 16),
              _buildGuideSection("Tips & Features", [
                _buildGuideText("• Tap 'History' to view detailed audit trails"),
                _buildGuideText("• Use 'Compare Path' for AI-optimized routes"),
                _buildGuideText("• Real-time heatmaps indicate collection speed"),
              ]),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuideSection(String title, List<Widget> items) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.pulidongShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 16),
          ...items,
        ],
      ),
    );
  }

  Widget _buildGuideItem(IconData icon, String text, {required Color color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Text(text, style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildGuideText(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w600)),
    );
  }

  void _showStyledBottomSheet({required String title, required List<Widget> children}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
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
            const Padding(padding: EdgeInsets.symmetric(horizontal: 32), child: Divider(height: 32)),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: Column(mainAxisSize: MainAxisSize.min, children: children),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoverZoomCard extends StatefulWidget {
  final Widget child; final VoidCallback? onTap; final double scale;
  const _HoverZoomCard({required this.child, this.onTap, this.scale = 1.02});
  @override
  State<_HoverZoomCard> createState() => _HoverZoomCardState();
}
class _HoverZoomCardState extends State<_HoverZoomCard> {
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(onEnter: (_) => setState(() => _active = true), onExit: (_) => setState(() => _active = false), cursor: SystemMouseCursors.click, child: GestureDetector(onTap: widget.onTap, onTapDown: (_) => setState(() => _active = true), onTapUp: (_) => setState(() => _active = false), child: AnimatedScale(scale: _active ? widget.scale : 1.0, duration: const Duration(milliseconds: 200), child: widget.child)));
  }
}

class _HoverZoomLink extends StatefulWidget {
  final Widget child; final VoidCallback onTap;
  const _HoverZoomLink({required this.child, required this.onTap});
  @override
  State<_HoverZoomLink> createState() => _HoverZoomLinkState();
}
class _HoverZoomLinkState extends State<_HoverZoomLink> {
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(onEnter: (_) => setState(() => _active = true), onExit: (_) => setState(() => _active = false), cursor: SystemMouseCursors.click, child: GestureDetector(onTap: widget.onTap, onTapDown: (_) => setState(() => _active = true), onTapUp: (_) => setState(() => _active = false), onTapCancel: () => setState(() => _active = false), child: AnimatedScale(scale: _active ? 1.05 : 1.0, duration: const Duration(milliseconds: 200), child: widget.child)));
  }
}
