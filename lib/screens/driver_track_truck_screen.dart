import 'dart:async';
import 'dart:convert';
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
  final List<Map>? testRoute; // NEW: For web testing
  
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
  CircleAnnotationManager? _circleAnnotationManager;
  
  final Map<String, PointAnnotation> _truckMarkers = {};
  List<Map> _lastPoints = [];
  StreamSubscription? _truckSubscription;
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
  
  // LIVE DRIVER MARKERS (Annotations)
  CircleAnnotation? _liveDriverCircle;
  CircleAnnotation? _liveDriverHalo;
  PointAnnotation? _liveDriverLabel;

  // NEW: Session Meta Persistence
  Map? _lastSessionData;

  // NEW: Follow Mode State
  bool _isFollowLocked = true;
  String _currentStatus = "ACTIVE";

  // Modal Info State
  String _startTime = "--:--";
  DateTime? _startDateTime;
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
    _listenToRoute();
  }

  void _loadUser() async {
    _user = await SessionManager.getUser();
    if (mounted) setState(() {});
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
  void dispose() {
    _clockTimer?.cancel();
    _truckSubscription?.cancel();
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
      if (mounted) setState(() { 
        _lastLocalPos = pos;
        _currentSpeed = pos.speed * 3.6; // Convert m/s to km/h
      });
      _updateLocalDriverMarker(pos);
    } catch (e) {}

    _localGpsSubscription = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.bestForNavigation, distanceFilter: 1),
    ).listen((pos) {
      if (widget.isSimulation) return;
      if (mounted) setState(() { 
        _lastLocalPos = pos;
        _currentSpeed = pos.speed * 3.6; // Convert m/s to km/h
      });
      _updateLocalDriverMarker(pos);
    });
  }

  void _listenToTrucks() {
    _truckSubscription?.cancel();
    _truckSubscription = _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _lastTruckData = event.snapshot.value as Map;
        
        final String tid = (widget.focusTruckId ?? "GT-001").toUpperCase();
        if (_lastTruckData!.containsKey(tid)) {
          final myData = _lastTruckData![tid] as Map;
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
      if (widget.testRoute != null) return; // Skip if test route is active
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        _lastSessionData = data;

        // Update modal info
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
          
          points.sort((a, b) {
            final num tsA = a['timestamp'] ?? 0;
            final num tsB = b['timestamp'] ?? 0;
            return tsA.compareTo(tsB);
          });
          
          if (mounted && points.isNotEmpty) {
            if (points.length != _lastPoints.length) {
              _updateRoutePolyline(points);
            }
            
            final lastPoint = points.last;
            final double lat = (lastPoint['lat'] ?? 0.0).toDouble();
            final double lng = (lastPoint['lng'] ?? 0.0).toDouble();
            
            if (lat != 0 && lng != 0) {
              final latestPos = geo.Position(
                latitude: lat, longitude: lng,
                timestamp: DateTime.now(), accuracy: (lastPoint['accuracy'] ?? 0.0).toDouble(),
                altitude: 0, heading: (lastPoint['heading'] ?? 0.0).toDouble(),
                speed: (lastPoint['speed'] ?? 0.0).toDouble(),
                speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0
              );
              
              _lastLocalPos = latestPos;
              _updateLocalDriverMarker(latestPos);
              
              if (_isFollowLocked && mapboxMap != null) {
                mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat))));
              }
            }
            _lastPoints = points;
          }
        }
        if (_managersReady) _updateSpecialMarkers(data);
      }
    });
  }

  void _onMapCreated(MapboxMap map) { mapboxMap = map; }

  void _onStyleLoaded(dynamic data) async {
    debugPrint("[DRIVER MAP] Style loaded. Initializing layers...");
    
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
      _circleAnnotationManager = await mapboxMap!.annotations.createCircleAnnotationManager();
    } catch (e) {}
    if (!mounted) return;
    _truckMarkers.clear();
    
    _liveDriverCircle = null;
    _liveDriverHalo = null;
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
    final tid = (widget.focusTruckId ?? "GT-001").toUpperCase();
    
    final geojson = {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature", 
          "geometry": {"type": "Point", "coordinates": [pos.longitude, pos.latitude]}, 
          "properties": {"name": "DRIVER", "truckId": tid, "status": _currentStatus}
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

        // 1. HALO (Status Indicator)
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

        // 2. CENTER CIRCLE
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

        // 3. LABEL
        if (!(await style.styleLayerExists("driver-live-location-label"))) {
          await style.addLayer(SymbolLayer(
            id: "driver-live-location-label", 
            sourceId: sourceId, 
            textField: "DRIVER\n$tid", 
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
        debugPrint("[DRIVER MARKER] Source and Layers established at: ${pos.latitude}, ${pos.longitude}");
      } else {
        // FAST DATA UPDATE
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(geojson));
      }
    } catch (e) {
      debugPrint("[DRIVER MARKER] Style Update Error: $e");
    }
  }

  int _getStatusHaloColorInt() {
     switch(_currentStatus) {
       case "IDLE": return Colors.yellow.toARGB32();
       case "FULL": return Colors.pinkAccent.toARGB32();
       case "FINISHED": return Colors.black.toARGB32();
       default: return Colors.green.toARGB32();
     }
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
      if (!_specialMarkersCreated || !sourceExists) {
        if (!sourceExists) await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(geojson)));
        
        if (!(await style.styleLayerExists("driver-special-circles"))) {
          await style.addLayer(CircleLayer(
            id: "driver-special-circles", sourceId: sourceId, 
            circleRadius: 6.0, circleStrokeWidth: 2.0, circleStrokeColor: Colors.white.toARGB32(),
          ));
          await style.setStyleLayerProperty("driver-special-circles", "circle-color", 
            ["match", ["get", "type"], "START", "#2196F3", "#000000"] // Blue for START, Black for FINISH
          );
        }
        if (!(await style.styleLayerExists("driver-special-labels"))) {
          await style.addLayer(SymbolLayer(
            id: "driver-special-labels", sourceId: sourceId, 
            textField: "{label}", textSize: 11.0, textHaloColor: Colors.white.toARGB32(), textHaloWidth: 2.0,
          ));
          await style.setStyleLayerProperty("driver-special-labels", "text-offset", 
            ["match", ["get", "type"], "START", ["literal", [0, 1.5]], ["literal", [0, -1.5]]]
          );
          await style.setStyleLayerProperty("driver-special-labels", "text-color", 
            ["match", ["get", "type"], "START", "#2196F3", "#000000"]
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
    final String truckId = (data['truck_id'] ?? id).toString().toUpperCase();
    final String targetId = (widget.focusTruckId ?? "GT-001").toUpperCase();
    if (truckId == targetId) return; 

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
    if (mapboxMap == null || points.length < 2) { if (points.isEmpty) _clearRoute(); return; }
    
    points.sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num));

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
        if (d > 4.0 || prev['status'] != curr['status'] || i == points.length - 1) smoothedPoints.add(curr);
      }
    }

    final String sourceId = "driver-route-source";
    final List<Map<String, dynamic>> segments = [];
    
    for (int i = 1; i < smoothedPoints.length; i++) {
      final prev = smoothedPoints[i - 1];
      final curr = smoothedPoints[i];
      final String color = (curr['color'] ?? 'GREEN').toString().toUpperCase();
      final bool isGap = ((curr['timestamp'] ?? 0) as int) - ((prev['timestamp'] ?? 0) as int) > 60000;

      if (!isGap) {
        if (segments.isNotEmpty && segments.last['properties']['color'] == color) {
          final List coords = segments.last['geometry']['coordinates'];
          coords.add([(curr['lng'] ?? 0.0).toDouble(), (curr['lat'] ?? 0.0).toDouble()]);
        } else {
          segments.add({
            "type": "Feature",
            "geometry": {
              "type": "LineString",
              "coordinates": [
                [(prev['lng'] ?? 0.0).toDouble(), (prev['lat'] ?? 0.0).toDouble()],
                [(curr['lng'] ?? 0.0).toDouble(), (curr['lat'] ?? 0.0).toDouble()]
              ]
            },
            "properties": {"color": color, "isGap": false}
          });
        }
      }
    }

    final featureCollection = {"type": "FeatureCollection", "features": segments};
    
    try {
      final style = mapboxMap!.style;
      bool sourceCreated = await style.styleSourceExists(sourceId);
      if (!sourceCreated) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        try { await style.removeStyleLayer("driver-route-layer"); } catch(_) {}
        await style.addLayer(LineLayer(
          id: "driver-route-layer", sourceId: sourceId, 
          lineColor: Colors.green.toARGB32(), lineWidth: 10.0, lineOpacity: 1.0, 
          lineCap: LineCap.ROUND, lineJoin: LineJoin.ROUND
        ));
        await style.setStyleLayerProperty("driver-route-layer", "line-color", [
          "match", ["get", "color"],
          "GREEN", "#00FF00", "YELLOW", "#FFFF00", "PINK", "#FF1493", "BLACK", "#000000", "BLUE", "#0000FF", "#00FF00"
        ]);
      } else { 
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection)); 
      }
    } catch (e) {}
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
            
            // Swipe-up Modal (Only show if NOT embedded)
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
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Live Route Tracking", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              Text("Searching...", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        
        // Trip Information Card
        _buildInfoCard(
          title: "Trip Information",
          icon: Icons.info_outline_rounded,
          color: AppColors.tealText,
          content: [
            _buildInfoRow("Truck Number", _user?.preferredTruck ?? "GT-001", color: AppColors.tealText),
            const Divider(height: 24),
            _buildInfoRow("Plate Number", "ABC 1234", isBold: true),
            const Divider(height: 24),
            _buildInfoRow("Start Time", _startTime),
            const Divider(height: 24),
            _buildInfoRow("Total Distance", "${_distance.toStringAsFixed(1)} km", color: Colors.orangeAccent.shade200),
          ],
        ),
        
        const SizedBox(height: 20),
        
        // GPS Status Card
        _buildInfoCard(
          title: "GPS Status",
          icon: Icons.gps_fixed_rounded,
          color: Colors.green, // Changed to Green
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
        color: Colors.white, // Changed to White
        borderRadius: BorderRadius.circular(32),
        boxShadow: AppTheme.pulidongShadow, // Changed to pulidongShadow
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
            color: Colors.green.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20), // Oval
            border: Border.all(color: Colors.green.withOpacity(0.2)),
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
      bottom: widget.isEmbedded ? 20 : 160, // Sits above the minimized modal
      right: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // FOLLOW TOGGLE (TARGET ICON)
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
          // RECENTER (MAP ICON)
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
    // Only show the large floating header if NOT embedded
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
          color: Colors.white.withOpacity(0.9), 
          borderRadius: BorderRadius.circular(20), 
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: const Offset(0, 4))]
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

  Color _getStatusColor(String status) {
    switch (status) {
      case "IDLE": return Colors.yellow;
      case "FULL": return Colors.pinkAccent;
      case "FINISHED": return Colors.blue;
      default: return Colors.greenAccent;
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
