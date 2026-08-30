import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_database/firebase_database.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../utils/prediction_engine.dart';
import '../utils/responsive.dart';

class TrackTrucksScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const TrackTrucksScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<TrackTrucksScreen> createState() => _TrackTrucksScreenState();
}

class _TrackTrucksScreenState extends State<TrackTrucksScreen> {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  MapboxMap? mapboxMap;
  List<Map<dynamic, dynamic>> _trucks = [];
  String? _selectedTruckId;
  String? _followedTruckId;

  PointAnnotationManager? _pointAnnotationManager;
  PolylineAnnotationManager? _polylineAnnotationManager;
  
  final Map<String, StreamSubscription> _sharedRouteSubscriptions = {};
  final Map<String, List<PolylineAnnotation>> _sharedRouteAnnotations = {};
  final Map<String, List<PointAnnotation>> _sharedSpecialAnnotations = {};

  Map<String, Offset> _webMarkerPositions = {};
  Map<String, List<Map<String, dynamic>>> _webSharedRouteData = {}; 
  Map<String, List<Offset>> _webSharedRoutePixels = {}; 
  Map<String, Offset> _webStartPositions = {};
  final Map<String, List<Map>> _lastRoutePoints = {}; 
  final Set<String> _visiblePaths = {};
  final Map<String, Position?> _sessionStartPoints = {};

  final Map<String, List<Map<String, dynamic>>> _webHeatmapData = {}; 
  Map<String, List<Offset>> _webHeatmapPixels = {}; 
  Map<String, List<Offset>> _webOptimizedPixels = {};

  @override
  void initState() {
    super.initState();
    _listenToTrucks();
  }

  @override
  void dispose() {
    _sharedRouteSubscriptions.forEach((k, v) => v.cancel());
    super.dispose();
  }

  void _listenToTrucks() {
    _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        final List<Map<dynamic, dynamic>> list = [];
        data.forEach((key, value) {
          final truckMap = Map<dynamic, dynamic>.from(value as Map);
          truckMap['internal_id'] = key.toString(); 
          if (truckMap['truck_id'] == null) truckMap['truck_id'] = key.toString();
          list.add(truckMap);
        });
        if (mounted) {
          setState(() => _trucks = list);
          if (kIsWeb) _updateWebOverlays();
          else _updateTruckMarkersNative();

          // Auto-follow logic
          if (_followedTruckId != null) {
            final t = list.firstWhere((element) => element['internal_id'] == _followedTruckId || element['truck_id'] == _followedTruckId, orElse: () => {});
            if (t.isNotEmpty) {
              final double lat = (t['latitude'] ?? 0.0).toDouble();
              final double lng = (t['longitude'] ?? 0.0).toDouble();
              if (lat != 0 && lng != 0) {
                mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat))));
              }
            }
          }

          for (var t in list) {
            final String tid = t['truck_id'];
            final String? sid = t['current_session'];
            if (sid != null) {
              if (!_sharedRouteSubscriptions.containsKey(tid)) _setupSharedRouteSubscription(tid, sid);
            } else {
              _sharedRouteSubscriptions[tid]?.cancel();
              _sharedRouteSubscriptions.remove(tid);
              _clearSharedRoute(tid);
            }
          }
        }
      }
    });
  }

  void _onMapCreated(MapboxMap map) { mapboxMap = map; }

  void _onStyleLoaded(dynamic data) async {
    _pointAnnotationManager = await mapboxMap?.annotations.createPointAnnotationManager();
    _polylineAnnotationManager = await mapboxMap?.annotations.createPolylineAnnotationManager();
    if (!kIsWeb) _updateTruckMarkersNative();
  }

  void _updateWebOverlays() async {
    if (!kIsWeb || mapboxMap == null) return;
    Map<String, Offset> newMarkerPositions = {};
    for (var truck in _trucks) {
      final double lat = (truck['latitude'] ?? 13.9402).toDouble();
      final double lng = (truck['longitude'] ?? 121.1638).toDouble();
      final String internalId = (truck['internal_id'] ?? "").toString();
      try {
        final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: Position(lng, lat)));
        newMarkerPositions[internalId] = Offset(screenPos.x, screenPos.y);
      } catch (e) {
        debugPrint("[ADMIN MAP] Pixel mapping error: $e");
      }
    }
    
    // 1.5 Update Start Marker Positions
    Map<String, Offset> newStartPositions = {};
    for (var entry in _sessionStartPoints.entries) {
      if (entry.value != null && _visiblePaths.contains(entry.key)) {
        try {
          final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: entry.value!));
          newStartPositions[entry.key] = Offset(screenPos.x, screenPos.y);
        } catch (_) {}
      }
    }

    Map<String, List<Offset>> newHeatmapPixels = {};
    for (var entry in _webHeatmapData.entries) {
      List<Offset> pixels = [];
      for (var point in entry.value) {
        final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: Position(point['lng'], point['lat'])));
        pixels.add(Offset(screenPos.x, screenPos.y));
      }
      newHeatmapPixels[entry.key] = pixels;
    }

    Map<String, List<Offset>> newSharedPixels = {};
    for (var entry in _webSharedRouteData.entries) {
      List<Offset> pixels = [];
      for (var point in entry.value) {
        final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: Position(point['lng'], point['lat'])));
        pixels.add(Offset(screenPos.x, screenPos.y));
      }
      newSharedPixels[entry.key] = pixels;
    }

    Map<String, List<Offset>> newOptimizedPixels = {};
    if (_webOptimizedPixels.isNotEmpty) {
       final List<Position> idealPathCoords = [Position(121.1638, 13.9402), Position(121.1645, 13.9410), Position(121.1655, 13.9425), Position(121.1668, 13.9440)];
       for (var truckId in _webOptimizedPixels.keys) {
         List<Offset> pixels = [];
         for (var pos in idealPathCoords) {
           final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: pos));
           pixels.add(Offset(screenPos.x, screenPos.y));
         }
         newOptimizedPixels[truckId] = pixels;
       }
    }
    if (mounted) {
      setState(() { 
        _webMarkerPositions = newMarkerPositions; 
        _webStartPositions = newStartPositions;
        _webHeatmapPixels = newHeatmapPixels; 
        _webSharedRoutePixels = newSharedPixels;
        _webOptimizedPixels = newOptimizedPixels; 
      });
    }
  }

  void _selectTruck(String truckId, double lat, double lng) {
    setState(() { 
      _selectedTruckId = truckId; 
      _followedTruckId = truckId;
    });
    mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat)), zoom: 16.0));
    if (kIsWeb) Future.delayed(const Duration(milliseconds: 100), _updateWebOverlays);
  }

  void _toggleTrack(String truckId, double lat, double lng) {
    setState(() {
      if (_followedTruckId == truckId) {
        _followedTruckId = null;
      } else {
        _selectedTruckId = truckId;
        _followedTruckId = truckId;
      }
    });
    if (_followedTruckId != null) {
      mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat)), zoom: 16.0));
      if (kIsWeb) Future.delayed(const Duration(milliseconds: 100), _updateWebOverlays);
    }
  }

  void _setupSharedRouteSubscription(String truckId, String sessionId) {
    _sharedRouteSubscriptions[truckId]?.cancel();
    _sharedRouteSubscriptions[truckId] = _database.ref('driver_routes/$sessionId/route').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List<Map> points = [];
        data.forEach((key, value) => points.add(value as Map));
        points.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
        
        _lastRoutePoints[truckId] = points;
        
        if (_visiblePaths.contains(truckId)) {
          if (!kIsWeb) _updateSharedRoutePolyline(truckId, points);
          else _updateWebSharedRoute(truckId, points);
        }
      }
    });

    _database.ref('driver_routes/$sessionId').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        if (data['start_lat'] != null && data['start_lng'] != null) {
          if (mounted) {
            setState(() {
              _sessionStartPoints[truckId] = Position(data['start_lng'], data['start_lat']);
            });
            if (kIsWeb) _updateWebOverlays();
            else _updateTruckMarkersNative();
          }
        }
      }
    });
  }

  void _clearSharedRoute(String truckId) async {
    if (mapboxMap == null) return;
    try {
      final style = mapboxMap!.style;
      final String sourceId = "admin-route-source-$truckId";
      if (await style.styleSourceExists(sourceId)) {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode({"type": "FeatureCollection", "features": []}));
      }
    } catch (_) {}
    if (kIsWeb) {
      if (mounted) { setState(() { _webSharedRouteData.remove(truckId); _webSharedRoutePixels.remove(truckId); }); }
    }
  }

  void _updateWebSharedRoute(String truckId, List<Map> points) async {
    if (!kIsWeb || mapboxMap == null) return;
    final List<Map<String, dynamic>> webPoints = points.map((p) => {
      'lat': (p['lat'] ?? 0.0).toDouble(),
      'lng': (p['lng'] ?? 0.0).toDouble(),
      'color': (p['color'] ?? 'GREEN').toString().toUpperCase(),
      'timestamp': p['timestamp'],
    }).toList();
    _webSharedRouteData[truckId] = webPoints;
    _updateWebOverlays();
  }

  void _updateSharedRoutePolyline(String truckId, List<Map> points) async {
    if (mapboxMap == null || points.length < 2) return;

    // 1. Strict numerical sort
    points.sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num));

    final String sourceId = "admin-route-source-$truckId";
    final List<Map<String, dynamic>> segments = [];

    // EDGE-BASED SEGMENTATION: Connect points directly to avoid gaps
    // AND apply smoothing filter for clean roads
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
          if (coords.isEmpty || coords.last[0] != currLng || coords.last[1] != currLat) {
            coords.add([currLng, currLat]);
          }
        } else {
          segments.add({
            "type": "Feature",
            "geometry": {
              "type": "LineString",
              "coordinates": [[prevLng, prevLat], [currLng, currLat]]
            },
            "properties": {"color": color, "isGap": false}
          });
        }
      }
    }

    final featureCollection = {"type": "FeatureCollection", "features": segments};

    try {
      final style = mapboxMap!.style;
      if (!(await style.styleSourceExists(sourceId))) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        await style.addLayer(LineLayer(
          id: "admin-route-layer-$truckId",
          sourceId: sourceId,
          lineColor: Colors.green.toARGB32(),
          lineWidth: 6.0, lineOpacity: 0.9, lineCap: LineCap.ROUND, lineJoin: LineJoin.ROUND,
        ));
        await style.setStyleLayerProperty("admin-route-layer-$truckId", "line-color", [
          "match", ["get", "color"], 
          "GREEN", "#00FF00",
          "YELLOW", "#FFFF00", 
          "PINK", "#FF1493", 
          "BLACK", "#000000",
          "BLUE", "#0000FF", 
          "#00FF00"
        ]);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection));
      }
    } catch (e) {}
  }

  void _updateTruckMarkersNative() async {
    if (_pointAnnotationManager == null || _trucks.isEmpty || kIsWeb) return;
    try { await _pointAnnotationManager?.deleteAll(); } catch (_) {}
    
    for (var truck in _trucks) {
      final double lat = (truck['latitude'] ?? 13.9402).toDouble();
      final double lng = (truck['longitude'] ?? 121.1638).toDouble();
      final String id = (truck['truck_id'] ?? truck['internal_id'] ?? "GT-001").toString();
      try { await _pointAnnotationManager?.create(PointAnnotationOptions(geometry: Point(coordinates: Position(lng, lat)), textField: id, textOffset: [0, 2], textColor: Colors.blue.toARGB32(), iconImage: "truck-15")); } catch (_) {}
    }

    for (var entry in _sessionStartPoints.entries) {
      if (entry.value != null && _visiblePaths.contains(entry.key)) {
        try {
          await _pointAnnotationManager?.create(PointAnnotationOptions(
            geometry: Point(coordinates: entry.value!),
            textField: "START / ${entry.key}",
            textColor: Colors.green.shade800.toARGB32(),
            textSize: 10.0,
            textHaloColor: Colors.white.toARGB32(),
            textHaloWidth: 2.0,
          ));
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final bool isDesktop = constraints.maxWidth >= 1024;
      return Scaffold(backgroundColor: const Color(0xFFF8F9FA), body: isDesktop ? _buildDesktopLayout() : _buildMobileLayout());
    });
  }

  Widget _buildDesktopLayout() {
    return Row(children: [
      Expanded(child: Stack(children: [
        Positioned.fill(child: MapWidget(onMapCreated: _onMapCreated, onStyleLoadedListener: _onStyleLoaded, onCameraChangeListener: (e) { if (kIsWeb) _updateWebOverlays(); }, viewport: CameraViewportState(center: Point(coordinates: Position(121.1638, 13.9413)), zoom: 14.0))),
        if (kIsWeb) ..._buildWebOverlays(), _buildHeader(), _buildRouteProgress(true),
      ])),
      Container(width: 400, decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 20, offset: const Offset(-5, 0))]), child: _buildFleetStatusContent(null)),
    ]);
  }

  List<Widget> _buildWebOverlays() {
    List<Widget> overlays = [];
    overlays.add(Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: WebPathPainter(heatmapData: _webHeatmapData, heatmapPixels: _webHeatmapPixels, sharedRouteData: _webSharedRouteData, sharedRoutePixels: _webSharedRoutePixels, optimizedPixels: _webOptimizedPixels)))));
    overlays.addAll(_trucks.map((truck) {
      final String internalId = (truck['internal_id'] ?? "").toString();
      final String id = (truck['truck_id'] ?? internalId).toString();
      final offset = _webMarkerPositions[internalId];
      if (offset == null) return const SizedBox.shrink();
      return Positioned(left: offset.dx - 20, top: offset.dy - 40, child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(6), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)]), child: Text(id, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.blue))),
        const Icon(Icons.local_shipping, color: Colors.blue, size: 28),
      ]));
    }));

    _webStartPositions.forEach((truckId, offset) {
      overlays.add(Positioned(left: offset.dx - 15, top: offset.dy - 35, child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)]), child: Text("START / $truckId", style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.green))),
        const Icon(Icons.location_on, color: Colors.green, size: 24),
      ])));
    });
    return overlays;
  }

  Widget _buildMobileLayout() {
    return Stack(children: [
      Positioned.fill(child: MapWidget(onMapCreated: _onMapCreated, onStyleLoadedListener: _onStyleLoaded, onCameraChangeListener: (e) { if (kIsWeb) _updateWebOverlays(); }, viewport: CameraViewportState(center: Point(coordinates: Position(121.1638, 13.9413)), zoom: 14.0))),
      if (kIsWeb) ..._buildWebOverlays(), _buildHeader(), _buildRouteProgress(false),
      Positioned.fill(child: DraggableScrollableSheet(initialChildSize: 0.45, minChildSize: 0.18, maxChildSize: 0.95, snap: true, snapSizes: const [0.18, 0.45, 0.95], builder: (context, scrollController) { return PointerInterceptor(child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(40)), boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 20, spreadRadius: 5, offset: const Offset(0, -5))]), child: _buildFleetStatusContent(scrollController, isMobile: true))); })),
    ]);
  }

  Widget _buildHeader() {
    return Positioned(top: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))]), child: SafeArea(child: Row(children: [if (!widget.isEmbedded || widget.onBack != null) ...[IconButton(icon: const Icon(Icons.arrow_back, color: Color(0xFF1A1A1A)), onPressed: () { if (widget.onBack != null) { widget.onBack!(); } else { Navigator.pop(context); } }), const SizedBox(width: 12)], const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text("Track Fleet", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))), Text("Real-time GPS status", style: TextStyle(fontSize: 12, color: Color(0xFF757575), fontWeight: FontWeight.w500))])]))));
  }

  Widget _buildRouteProgress(bool isDesktop) {
    double progress = 0.0;
    if (_trucks.isNotEmpty) { int active = _trucks.where((t) => t['isOnline'] == true).length; progress = active > 0 ? 0.3 : 0.0; }
    return Positioned(top: widget.isEmbedded ? 68 : 96, left: 0, right: 0, child: LinearProgressIndicator(value: progress, backgroundColor: const Color(0xFFE0E0E0), valueColor: const AlwaysStoppedAnimation(Color(0xFF2196F3)), minHeight: 4));
  }

  Widget _buildFleetStatusContent(ScrollController? scrollController, {bool isMobile = false}) {
    return ListView(controller: scrollController, physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()), padding: EdgeInsets.zero, children: [
      if (isMobile) const SizedBox(height: 12),
      if (isMobile) Center(child: Container(width: 60, height: 8, decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: BorderRadius.circular(10)))),
      const SizedBox(height: 24),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 28), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("Fleet Status", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)), Icon(Icons.local_shipping_rounded, color: Colors.grey)])),
      const SizedBox(height: 20),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(children: _trucks.isEmpty ? [const Padding(padding: EdgeInsets.all(60), child: Center(child: Text("Scanning for active units...", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500))))] : _trucks.where((t) => t['isOnline'] == true).map((truck) => _buildDetailedTruckCard(truck)).toList())),
      const SizedBox(height: 120),
    ]);
  }

  Widget _buildDetailedTruckCard(Map<dynamic, dynamic> truck) {
    String internalId = (truck['internal_id'] ?? truck['truck_id'] ?? "GT-001").toString();
    String id = (truck['truck_id'] ?? internalId).toString();
    String status = (truck['status'] ?? "Idle").toString().toUpperCase();
    String driver = (truck['driver_name'] ?? truck['driverName'] ?? "Unknown Driver").toString();
    String location = (truck['purok'] ?? "Balintawak").toString();
    String speed = "${truck['speed']?.toString() ?? "0"} km/h";
    double distVal = double.tryParse(truck['distance_covered']?.toString() ?? "0.0") ?? 0.0;
    String distance = "${distVal.toStringAsFixed(1)} km";
    String lastUpdate = (truck['last_update'] ?? "Just now").toString();
    bool isHistoryVisible = _visiblePaths.contains(internalId);
    bool isSelected = _selectedTruckId == internalId;
    Color statusColor = status == 'FULL' ? const Color(0xFFFF1744) : (status == 'ACTIVE' ? const Color(0xFF4CAF50) : const Color(0xFFFFAB00));
    return GestureDetector(
      onTap: () => _toggleTrack(internalId, (truck['latitude'] ?? 13.9402).toDouble(), (truck['longitude'] ?? 121.1638).toDouble()),
      child: Container(
        margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32), boxShadow: [BoxShadow(color: isSelected ? Colors.blue.withAlpha(40) : Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(0, 4))], border: Border.all(color: isSelected ? Colors.blue : const Color(0xFFF5F5F5), width: isSelected ? 2 : 1)),
        child: Column(children: [
          Row(children: [Container(width: 52, height: 52, decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.local_shipping_rounded, color: Color(0xFF1976D2), size: 28)), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(id, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))), Text(lastUpdate, style: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 13, fontWeight: FontWeight.w500))])), Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), decoration: BoxDecoration(color: statusColor.withAlpha(30), borderRadius: BorderRadius.circular(12)), child: Text(status, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w900)))]),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_buildInfoItem(Icons.location_on_rounded, const Color(0xFFFF1744), "Location", location), _buildInfoItem(Icons.refresh_rounded, const Color(0xFF03A9F4), "Speed", speed), _buildInfoItem(Icons.person_rounded, const Color(0xFF1976D2), "Driver", driver)]),
          const SizedBox(height: 24),
          Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [_buildStatItem(Icons.local_shipping_outlined, "DISTANCE", distance, const Color(0xFF2E7D32))])),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: _buildSecondaryButton(
              _followedTruckId == internalId ? "TRACKING" : "TRACK TRUCK", 
              _followedTruckId == internalId ? Icons.gps_fixed : Icons.center_focus_strong_rounded, 
              () => _toggleTrack(internalId, (truck['latitude'] ?? 13.9402).toDouble(), (truck['longitude'] ?? 121.1638).toDouble())
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildPrimaryButton(
              isHistoryVisible ? "HIDE PATH" : "PATH", 
              Icons.insights_rounded, 
              isHistoryVisible ? const Color(0xFFFFA726) : const Color(0xFF00BFA5), 
              () => _togglePath(internalId)
            ))
          ]),
        ]),
      ),
    );
  }

  Widget _buildSecondaryButton(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(onPressed: onTap, icon: Icon(icon, size: 16), label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF5F5F5), foregroundColor: const Color(0xFF1A1A1A), elevation: 0, padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))));
  }

  Widget _buildPrimaryButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return ElevatedButton.icon(onPressed: onTap, icon: Icon(icon, size: 16), label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)), style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, elevation: 6, shadowColor: color.withAlpha(100), padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))));
  }

  void _togglePath(String truckId) {
    if (!_visiblePaths.contains(truckId) && !_lastRoutePoints.containsKey(truckId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No active route available for this truck."))
      );
      return;
    }

    setState(() {
      if (_visiblePaths.contains(truckId)) {
        _visiblePaths.remove(truckId);
        _clearSharedRoute(truckId);
      } else {
        _visiblePaths.add(truckId);
        if (_lastRoutePoints.containsKey(truckId)) {
          if (!kIsWeb) _updateSharedRoutePolyline(truckId, _lastRoutePoints[truckId]!);
          else _updateWebSharedRoute(truckId, _lastRoutePoints[truckId]!);
        }
      }
    });
  }

  Widget _buildInfoItem(IconData icon, Color color, String label, String value) {
    return Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(icon, size: 14, color: color), const SizedBox(width: 4), Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFBDBDBD), fontWeight: FontWeight.w600))]), const SizedBox(height: 4), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)))]));
  }

  Widget _buildStatItem(IconData icon, String label, String value, Color color) {
    return Column(children: [Row(children: [Icon(icon, size: 12, color: const Color(0xFF757575)), const SizedBox(width: 4), Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF757575), fontWeight: FontWeight.w800))]), const SizedBox(height: 4), Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: color))]);
  }
}

class WebPathPainter extends CustomPainter {
  final Map<String, List<Map<String, dynamic>>> heatmapData;
  final Map<String, List<Offset>> heatmapPixels;
  final Map<String, List<Map<String, dynamic>>> sharedRouteData; 
  final Map<String, List<Offset>> sharedRoutePixels; 
  final Map<String, List<Offset>> optimizedPixels;

  WebPathPainter({
    required this.heatmapData, 
    required this.heatmapPixels, 
    required this.sharedRouteData,
    required this.sharedRoutePixels,
    required this.optimizedPixels
  });

  @override
  void paint(Canvas canvas, Size size) {
    heatmapPixels.forEach((truckId, pixels) {
      if (pixels.length < 2) return;
      final data = heatmapData[truckId];
      if (data == null) return;
      for (int i = 0; i < pixels.length - 1; i++) {
        final double speed = data[i + 1]['speed'] ?? 0;
        final paint = Paint()..strokeWidth = 4.0..strokeCap = StrokeCap.round..style = PaintingStyle.stroke..color = speed < 5 ? Colors.red : (speed < 15 ? Colors.yellow : Colors.green);
        canvas.drawLine(pixels[i], pixels[i+1], paint);
      }
    });

    sharedRoutePixels.forEach((truckId, pixels) {
      if (pixels.length < 2) return;
      final data = sharedRouteData[truckId];
      if (data == null) return;
      for (int i = 0; i < pixels.length - 1; i++) {
        final String colorName = (data[i + 1]['color'] ?? 'GREEN').toString().toUpperCase();
        Color color = Colors.green;
        if (colorName == "YELLOW") color = Colors.yellow;
        if (colorName == "PINK") color = Colors.pinkAccent;
        if (colorName == "BLACK") color = Colors.black;
        if (colorName == "GRAY") color = Colors.grey;
        if (colorName == "BLUE") color = Colors.blue;
        final paint = Paint()..strokeWidth = 8.0..strokeCap = StrokeCap.round..style = PaintingStyle.stroke..color = color.withOpacity(0.8);
        canvas.drawLine(pixels[i], pixels[i+1], paint);
      }
    });

    optimizedPixels.forEach((truckId, pixels) {
      if (pixels.length < 2) return;
      final paint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 8.0..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      final path = Path(); path.moveTo(pixels[0].dx, pixels[0].dy);
      for (int i = 1; i < pixels.length; i++) path.lineTo(pixels[i].dx, pixels[i].dy);
      canvas.drawPath(path, paint);
    });
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
