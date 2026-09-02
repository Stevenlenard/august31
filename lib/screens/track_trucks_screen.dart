import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_database/firebase_database.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:geolocator/geolocator.dart' as geo;

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

  final Map<String, StreamSubscription> _sharedRouteSubscriptions = {};
  final Map<String, String> _truckPlates = {}; // Cache for plate numbers
  final Map<String, String> _driverCurrentTrucks = {}; // driverId -> truckId
  StreamSubscription? _trucksMetaSubscription;
  StreamSubscription? _usersSubscription;

  final Map<String, List<Map<String, dynamic>>> _webSharedRouteData = {}; 
  final Map<String, List<Offset>> _webSharedRoutePixels = {}; 
  final Map<String, Offset> _webStartPositions = {};
  final Map<String, List<Map<dynamic, dynamic>>> _lastRoutePoints = {}; 
  final Set<String> _visiblePaths = {};
  final Map<String, Position?> _sessionStartPoints = {};

  final Map<String, List<Map<String, dynamic>>> _webHeatmapData = {}; 
  final Map<String, List<Offset>> _webHeatmapPixels = {}; 
  final Map<String, List<Offset>> _webOptimizedPixels = {};

  // For Web Marker UI
  Map<String, Offset> _webMarkerPositions = {};

  @override
  void initState() {
    super.initState();
    _listenToTrucks();
    _listenToTruckMeta();
    _listenToUsers();
  }

  @override
  void dispose() {
    for (final sub in _sharedRouteSubscriptions.values) {
      sub.cancel();
    }
    _trucksMetaSubscription?.cancel();
    _usersSubscription?.cancel();
    super.dispose();
  }

  void _listenToTruckMeta() {
    _trucksMetaSubscription?.cancel();
    _trucksMetaSubscription = _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final Map<String, String> newPlates = {};
        data.forEach((key, value) {
          if (value is Map && value['plateNumber'] != null) {
            newPlates[key.toString().toUpperCase()] = value['plateNumber'].toString();
          }
        });
        if (mounted) {
          setState(() => _truckPlates.addAll(newPlates));
        }
      }
    });
  }

  void _listenToUsers() {
    _usersSubscription?.cancel();
    _usersSubscription = _database.ref('users').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final Map<String, String> currentAssignments = {};
        data.forEach((key, value) {
          if (value is Map && value['role'] == 'driver') {
            final String? truckId = value['preferred_truck']?.toString();
            if (truckId != null) {
              currentAssignments[key.toString()] = truckId;
            }
          }
        });
        if (mounted) {
          setState(() {
            _driverCurrentTrucks.clear();
            _driverCurrentTrucks.addAll(currentAssignments);
          });
        }
      }
    });
  }

  void _listenToTrucks() {
    _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        
        // DEDUPLICATION LOGIC: One current record per Driver
        final Map<String, Map<dynamic, dynamic>> driverToLatestTruck = {};

        data.forEach((key, value) {
          final truckMap = Map<dynamic, dynamic>.from(value as Map);
          final String nodeKey = key.toString();
          final String? dId = truckMap['driver_id']?.toString();
          
          if (dId == null) {
            // If no driver ID, treat node key as unique identifier (fallback)
            truckMap['internal_id'] = nodeKey;
            if (truckMap['truck_id'] == null) {
              truckMap['truck_id'] = nodeKey;
            }
            driverToLatestTruck["node_$nodeKey"] = truckMap;
            return;
          }

          truckMap['internal_id'] = nodeKey;
          if (truckMap['truck_id'] == null) {
            truckMap['truck_id'] = nodeKey;
          }

          if (!driverToLatestTruck.containsKey(dId)) {
            driverToLatestTruck[dId] = truckMap;
          } else {
            // Determine which record is more current
            final existing = driverToLatestTruck[dId]!;
            final bool existingOnline = existing['isOnline'] == true;
            final bool currentOnline = truckMap['isOnline'] == true;
            
            final int existingSeen = (existing['lastSeen'] ?? 0) as int;
            final int currentSeen = (truckMap['lastSeen'] ?? 0) as int;

            // Priority: 
            // 1. Match driver's current assigned truck
            // 2. isOnline
            // 3. latest lastSeen
            
            final String? assignedTruck = _driverCurrentTrucks[dId];
            final bool existingMatches = existing['truck_id'] == assignedTruck;
            final bool currentMatches = truckMap['truck_id'] == assignedTruck;

            if (currentMatches && !existingMatches) {
              driverToLatestTruck[dId] = truckMap;
            } else if (existingMatches && !currentMatches) {
              // keep existing
            } else if (currentOnline && !existingOnline) {
              driverToLatestTruck[dId] = truckMap;
            } else if (currentOnline == existingOnline && currentSeen > existingSeen) {
              driverToLatestTruck[dId] = truckMap;
            }
          }
        });

        final List<Map<dynamic, dynamic>> list = driverToLatestTruck.values.toList();

        if (mounted) {
          setState(() {
            _trucks = list;
          });
          if (kIsWeb) {
            _updateWebOverlays();
          } else {
            _updateTruckMarkersNative();
          }

          // Auto-follow logic
          if (_followedTruckId != null) {
            final t = list.firstWhere(
              (element) => element['internal_id'] == _followedTruckId || element['truck_id'] == _followedTruckId, 
              orElse: () => {}
            );
            if (t.isNotEmpty) {
              final double lat = (t['latitude'] ?? 0.0).toDouble();
              final double lng = (t['longitude'] ?? 0.0).toDouble();
              if (lat != 0 && lng != 0) {
                mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat))));
              }
            }
          }

          for (final t in list) {
            final String tid = t['truck_id'];
            final String? sid = t['current_session'];
            if (sid != null) {
              if (!_sharedRouteSubscriptions.containsKey(tid)) {
                _setupSharedRouteSubscription(tid, sid);
              }
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

  void _onMapCreated(MapboxMap map) {
    mapboxMap = map;
  }

  void _onStyleLoaded(dynamic data) async {
    _pointAnnotationManager = await mapboxMap?.annotations.createPointAnnotationManager();
    if (!kIsWeb) {
      _updateTruckMarkersNative();
    }
  }

  void _updateWebOverlays() async {
    if (!kIsWeb || mapboxMap == null) {
      return;
    }
    final Map<String, Offset> newMarkerPositions = {};
    for (final truck in _trucks) {
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
    
    final Map<String, Offset> newStartPositions = {};
    for (final entry in _sessionStartPoints.entries) {
      if (entry.value != null && _visiblePaths.contains(entry.key)) {
        try {
          final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: entry.value!));
          newStartPositions[entry.key] = Offset(screenPos.x, screenPos.y);
        } catch (_) {}
      }
    }

    final Map<String, List<Offset>> newHeatmapPixels = {};
    for (final entry in _webHeatmapData.entries) {
      final List<Offset> pixels = [];
      for (final point in entry.value) {
        final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: Position(point['lng'], point['lat'])));
        pixels.add(Offset(screenPos.x, screenPos.y));
      }
      newHeatmapPixels[entry.key] = pixels;
    }

    final Map<String, List<Offset>> newSharedPixels = {};
    for (final entry in _webSharedRouteData.entries) {
      final List<Offset> pixels = [];
      for (final point in entry.value) {
        final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: Position(point['lng'], point['lat'])));
        pixels.add(Offset(screenPos.x, screenPos.y));
      }
      newSharedPixels[entry.key] = pixels;
    }

    final Map<String, List<Offset>> newOptimizedPixels = {};
    if (_webOptimizedPixels.isNotEmpty) {
       final List<Position> idealPathCoords = [Position(121.1638, 13.9402), Position(121.1645, 13.9410), Position(121.1655, 13.9425), Position(121.1668, 13.9440)];
       for (final truckId in _webOptimizedPixels.keys) {
         final List<Offset> pixels = [];
         for (final pos in idealPathCoords) {
           final screenPos = await mapboxMap!.pixelForCoordinate(Point(coordinates: pos));
           pixels.add(Offset(screenPos.x, screenPos.y));
         }
         newOptimizedPixels[truckId] = pixels;
       }
    }

    if (mounted) {
      setState(() { 
        _webMarkerPositions = newMarkerPositions; 
        _webStartPositions.clear();
        _webStartPositions.addAll(newStartPositions);
        _webHeatmapPixels.clear();
        _webHeatmapPixels.addAll(newHeatmapPixels); 
        _webSharedRoutePixels.clear();
        _webSharedRoutePixels.addAll(newSharedPixels);
        _webOptimizedPixels.clear();
        _webOptimizedPixels.addAll(newOptimizedPixels);
      });
    }
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
      if (kIsWeb) {
        Future.delayed(const Duration(milliseconds: 100), _updateWebOverlays);
      }
    }
  }

  void _setupSharedRouteSubscription(String truckId, String sessionId) {
    _sharedRouteSubscriptions[truckId]?.cancel();
    _sharedRouteSubscriptions[truckId] = _database.ref('driver_routes/$sessionId/route').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List<Map<dynamic, dynamic>> points = [];
        data.forEach((key, value) => points.add(Map<dynamic, dynamic>.from(value as Map)));
        points.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
        
        _lastRoutePoints[truckId] = points;
        
        if (_visiblePaths.contains(truckId)) {
          if (!kIsWeb) {
            _updateSharedRoutePolyline(truckId, points);
          } else {
            _updateWebSharedRoute(truckId, points);
          }
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
            if (kIsWeb) {
              _updateWebOverlays();
            } else {
              _updateTruckMarkersNative();
            }
          }
        }
      }
    });
  }

  void _clearSharedRoute(String truckId) async {
    if (mapboxMap == null) {
      return;
    }
    try {
      final style = mapboxMap!.style;
      final String sourceId = "admin-route-source-$truckId";
      if (await style.styleSourceExists(sourceId)) {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode({"type": "FeatureCollection", "features": []}));
      }
    } catch (_) {}
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _webSharedRouteData.remove(truckId);
          _webSharedRoutePixels.remove(truckId);
        });
      }
    }
  }

  void _updateWebSharedRoute(String truckId, List<Map<dynamic, dynamic>> points) async {
    if (!kIsWeb || mapboxMap == null) {
      return;
    }
    
    points.sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num));

    final List<Map<String, dynamic>> filtered = [];
    if (points.isNotEmpty) {
      filtered.add({
        'lat': (points.first['lat'] ?? 0.0).toDouble(),
        'lng': (points.first['lng'] ?? 0.0).toDouble(),
        'color': (points.first['color'] ?? 'GREEN').toString().toUpperCase(),
        'timestamp': points.first['timestamp'],
        'speed': (points.first['speed'] ?? 0.0).toDouble(),
      });

      for (int i = 1; i < points.length; i++) {
        final prev = filtered.last;
        final curr = points[i];
        
        final double lat = (curr['lat'] ?? 0.0).toDouble();
        final double lng = (curr['lng'] ?? 0.0).toDouble();
        final double prevLat = prev['lat'];
        final double prevLng = prev['lng'];

        final double d = geo.Geolocator.distanceBetween(prevLat, prevLng, lat, lng);
        final int timeDiff = ((curr['timestamp'] ?? 0) as int) - (prev['timestamp'] as int);
        final double speedKmH = (curr['speed'] ?? 0.0).toDouble();

        if (timeDiff > 0 && timeDiff < 15000 && d > 200) {
          continue;
        }

        final bool isStationary = speedKmH < 2.0;
        final double threshold = isStationary ? 8.0 : 4.0;
        if (d < threshold && i != points.length - 1 && (curr['color'] ?? 'GREEN').toString().toUpperCase() == prev['color']) {
           continue;
        }

        filtered.add({
          'lat': lat,
          'lng': lng,
          'color': (curr['color'] ?? 'GREEN').toString().toUpperCase(),
          'timestamp': curr['timestamp'],
        });
      }
    }

    final List<Map<String, dynamic>> processed = [];
    if (filtered.isNotEmpty) {
      int start = 0;
      for (int i = 1; i <= filtered.length; i++) {
        if (i == filtered.length || filtered[i]['color'] != filtered[start]['color']) {
          final segment = filtered.sublist(start, i);
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

    _webSharedRouteData[truckId] = processed;
    _updateWebOverlays();
  }

  void _updateSharedRoutePolyline(String truckId, List<Map<dynamic, dynamic>> points) async {
    if (mapboxMap == null || points.length < 2) {
      return;
    }

    points.sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num));

    final List<Map<dynamic, dynamic>> filtered = [];
    if (points.isNotEmpty) {
      filtered.add(points.first);
      for (int i = 1; i < points.length; i++) {
        final prev = filtered.last;
        final curr = points[i];
        
        final double lat = (curr['lat'] ?? 0.0).toDouble();
        final double lng = (curr['lng'] ?? 0.0).toDouble();
        final double prevLat = (prev['lat'] ?? 0.0).toDouble();
        final double prevLng = (prev['lng'] ?? 0.0).toDouble();

        final double d = geo.Geolocator.distanceBetween(prevLat, prevLng, lat, lng);
        final int timeDiff = ((curr['timestamp'] ?? 0) as int) - (prev['timestamp'] as int);
        final double speedKmH = (curr['speed'] ?? 0.0).toDouble();

        if (timeDiff > 0 && timeDiff < 15000 && d > 200) {
          continue;
        }

        final bool isStationary = speedKmH < 2.0;
        final double threshold = isStationary ? 8.0 : 4.0;
        if (d < threshold && i != points.length - 1 && (curr['color'] ?? 'GREEN').toString().toUpperCase() == (prev['color'] ?? 'GREEN').toString().toUpperCase()) {
           continue;
        }

        filtered.add(curr);
      }
    }

    final List<Map<dynamic, dynamic>> processed = [];
    if (filtered.isNotEmpty) {
      int start = 0;
      for (int i = 1; i <= filtered.length; i++) {
        final String currentStatus = (filtered[start]['color'] ?? 'GREEN').toString().toUpperCase();
        if (i == filtered.length || (filtered[i]['color'] ?? 'GREEN').toString().toUpperCase() != currentStatus) {
          final segment = filtered.sublist(start, i);
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

    final String sourceId = "admin-route-source-$truckId";
    final List<Map<String, dynamic>> features = [];

    if (processed.length >= 2) {
      for (int i = 1; i < processed.length; i++) {
        final prev = processed[i - 1];
        final curr = processed[i];
        
        String color = (curr['color'] ?? 'GREEN').toString().toUpperCase();
        if (color == "BLUE") {
          color = "GREEN";
        } 

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
      final bool sourceExists = await style.styleSourceExists(sourceId);
      if (!sourceExists) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        await style.addLayer(LineLayer(
          id: "admin-route-layer-$truckId",
          sourceId: sourceId,
          lineColor: Colors.green.toARGB32(),
          lineWidth: 8.0, lineOpacity: 0.85, lineCap: LineCap.ROUND, lineJoin: LineJoin.ROUND,
        ));
        await style.setStyleLayerProperty("admin-route-layer-$truckId", "line-color", [
          "match", ["get", "color"], 
          "GREEN", "#4CAF50",
          "YELLOW", "#FFEB3B", 
          "PINK", "#E91E63", 
          "BLACK", "#212121",
          "#4CAF50"
        ]);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection));
      }
    } catch (e) {
      debugPrint("[ADMIN ROUTE] Render error for $truckId: $e");
    }
  }

  List<Map<String, dynamic>> _simplifyPoints(List<Map<dynamic, dynamic>> points, double epsilon) {
    if (points.length < 3) {
      return points.map((e) => Map<String, dynamic>.from(e)).toList();
    }
    int index = -1;
    double maxDist = 0;
    for (int i = 1; i < points.length - 1; i++) {
      final double d = _perpendicularDistance(points[i], points.first, points.last);
      if (d > maxDist) {
        index = i;
        maxDist = d;
      }
    }
    if (maxDist > epsilon) {
      final List<Map<String, dynamic>> res1 = _simplifyPoints(points.sublist(0, index + 1), epsilon);
      final List<Map<String, dynamic>> res2 = _simplifyPoints(points.sublist(index), epsilon);
      return [...res1.sublist(0, res1.length - 1), ...res2];
    }
    return [Map<String, dynamic>.from(points.first), Map<String, dynamic>.from(points.last)];
  }

  double _perpendicularDistance(Map<dynamic, dynamic> p, Map<dynamic, dynamic> start, Map<dynamic, dynamic> end) {
    final double x = (p['lng'] as num).toDouble();
    final double y = (p['lat'] as num).toDouble();
    final double x1 = (start['lng'] as num).toDouble();
    final double y1 = (start['lat'] as num).toDouble();
    final double x2 = (end['lng'] as num).toDouble();
    final double y2 = (end['lat'] as num).toDouble();
    final double dx = x2 - x1;
    final double dy = y2 - y1;
    if (dx == 0 && dy == 0) {
      return sqrt(pow(x - x1, 2) + pow(y - y1, 2));
    }
    final double t = ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy);
    if (t < 0) {
      return sqrt(pow(x - x1, 2) + pow(y - y1, 2));
    }
    if (t > 1) {
      return sqrt(pow(x - x2, 2) + pow(y - y2, 2));
    }
    return sqrt(pow(x - (x1 + t * dx), 2) + pow(y - (y1 + t * dy), 2));
  }

  void _updateTruckMarkersNative() async {
    if (_pointAnnotationManager == null || _trucks.isEmpty || kIsWeb) {
      return;
    }
    try {
      await _pointAnnotationManager?.deleteAll();
    } catch (_) {}
    
    for (final truck in _trucks) {
      final double lat = (truck['latitude'] ?? 13.9402).toDouble();
      final double lng = (truck['longitude'] ?? 121.1638).toDouble();
      final String id = (truck['truck_id'] ?? truck['internal_id'] ?? "Unknown").toString();
      try {
        await _pointAnnotationManager?.create(PointAnnotationOptions(
          geometry: Point(coordinates: Position(lng, lat)),
          textField: id,
          textOffset: [0, 2],
          textColor: Colors.blue.toARGB32(),
          iconImage: "truck-15",
        ));
      } catch (_) {}
    }

    for (final entry in _sessionStartPoints.entries) {
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
      return Scaffold(
        backgroundColor: const Color(0xFFF8F9FA),
        body: isDesktop ? _buildDesktopLayout() : _buildMobileLayout(),
      );
    });
  }

  Widget _buildDesktopLayout() {
    return Row(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(
            child: MapWidget(
              onMapCreated: _onMapCreated,
              onStyleLoadedListener: _onStyleLoaded,
              onCameraChangeListener: (e) {
                if (kIsWeb) {
                  _updateWebOverlays();
                }
              },
              viewport: CameraViewportState(center: Point(coordinates: Position(121.1638, 13.9413)), zoom: 14.0),
            ),
          ),
          if (kIsWeb) ..._buildWebOverlays(),
          _buildHeader(),
          _buildRouteProgress(true),
        ]),
      ),
      Container(
        width: 400,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 20, offset: const Offset(-5, 0)),
          ],
        ),
        child: _buildFleetStatusContent(null),
      ),
    ]);
  }

  List<Widget> _buildWebOverlays() {
    final List<Widget> overlays = [];
    overlays.add(Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: WebPathPainter(
            heatmapData: _webHeatmapData,
            heatmapPixels: _webHeatmapPixels,
            sharedRouteData: _webSharedRouteData,
            sharedRoutePixels: _webSharedRoutePixels,
            optimizedPixels: _webOptimizedPixels,
          ),
        ),
      ),
    ));
    overlays.addAll(_trucks.map((truck) {
      final String internalId = (truck['internal_id'] ?? "").toString();
      final String id = (truck['truck_id'] ?? internalId).toString();
      final offset = _webMarkerPositions[internalId];
      if (offset == null) {
        return const SizedBox.shrink();
      }
      return Positioned(
        left: offset.dx - 20,
        top: offset.dy - 40,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: Text(id, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.blue)),
          ),
          const Icon(Icons.local_shipping, color: Colors.blue, size: 28),
        ]),
      );
    }));

    _webStartPositions.forEach((truckId, offset) {
      overlays.add(Positioned(
        left: offset.dx - 15,
        top: offset.dy - 35,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: Text("START / $truckId", style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.green)),
          ),
          const Icon(Icons.location_on, color: Colors.green, size: 24),
        ]),
      ));
    });
    return overlays;
  }

  Widget _buildMobileLayout() {
    return Stack(children: [
      Positioned.fill(
        child: MapWidget(
          onMapCreated: _onMapCreated,
          onStyleLoadedListener: _onStyleLoaded,
          onCameraChangeListener: (e) {
            if (kIsWeb) {
              _updateWebOverlays();
            }
          },
          viewport: CameraViewportState(center: Point(coordinates: Position(121.1638, 13.9413)), zoom: 14.0),
        ),
      ),
      if (kIsWeb) ..._buildWebOverlays(),
      _buildHeader(),
      _buildRouteProgress(false),
      Positioned.fill(
        child: DraggableScrollableSheet(
          initialChildSize: 0.45,
          minChildSize: 0.18,
          maxChildSize: 0.95,
          snap: true,
          snapSizes: const [0.18, 0.45, 0.95],
          builder: (context, scrollController) {
            return PointerInterceptor(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 20, spreadRadius: 5, offset: const Offset(0, -5)),
                  ],
                ),
                child: _buildFleetStatusContent(scrollController, isMobile: true),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _buildHeader() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))],
        ),
        child: SafeArea(
          child: Row(children: [
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
              const SizedBox(width: 12),
            ],
            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Track Fleet", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              Text("Real-time GPS status", style: TextStyle(fontSize: 12, color: Color(0xFF757575), fontWeight: FontWeight.w500)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _buildRouteProgress(bool isDesktop) {
    double progress = 0.0;
    if (_trucks.isNotEmpty) {
      final int active = _trucks.where((t) => t['isOnline'] == true).length;
      progress = active > 0 ? 0.3 : 0.0;
    }
    return Positioned(
      top: widget.isEmbedded ? 68 : 96,
      left: 0,
      right: 0,
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: const Color(0xFFE0E0E0),
        valueColor: const AlwaysStoppedAnimation(Color(0xFF2196F3)),
        minHeight: 4,
      ),
    );
  }

  Widget _buildFleetStatusContent(ScrollController? scrollController, {bool isMobile = false}) {
    return ListView(
      controller: scrollController,
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: EdgeInsets.zero,
      children: [
        if (isMobile) const SizedBox(height: 12),
        if (isMobile)
          Center(
            child: Container(
              width: 60,
              height: 8,
              decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: BorderRadius.circular(10)),
            ),
          ),
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Fleet Status", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)),
              Icon(Icons.local_shipping_rounded, color: Colors.grey),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: _trucks.isEmpty
                ? [
                    const Padding(
                      padding: EdgeInsets.all(60),
                      child: Center(child: Text("Scanning for active units...", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500))),
                    ),
                  ]
                : _trucks.where((t) => t['isOnline'] == true).map((truck) => _buildDetailedTruckCard(truck)).toList(),
          ),
        ),
        const SizedBox(height: 120),
      ],
    );
  }

  Widget _buildDetailedTruckCard(Map<dynamic, dynamic> truck) {
    final String driverId = truck['driver_id']?.toString() ?? "";
    final String assignedTruckId = _driverCurrentTrucks[driverId] ?? truck['truck_id'] ?? truck['internal_id'] ?? "Unknown";
    
    // The ID we display should be the one CURRENTLY assigned to the driver
    final String id = assignedTruckId;
    final String internalId = (truck['internal_id'] ?? id).toString();
    
    final String status = (truck['status'] ?? "Idle").toString().toUpperCase();
    final String driver = (truck['driver_name'] ?? truck['driverName'] ?? "Unknown Driver").toString();
    
    // Resolve plate number from metadata cache using the AUTHORITATIVE ID
    final String plateNumber = _truckPlates[id.toUpperCase()] ?? 
                         (truck['plate_number'] ?? truck['plateNumber'] ?? "N/A").toString();

    final String location = (truck['purok'] ?? "Balintawak").toString();
    final String speed = "${truck['speed']?.toString() ?? "0"} km/h";
    final double distVal = double.tryParse(truck['distance_covered']?.toString() ?? "0.0") ?? 0.0;
    final String distance = "${distVal.toStringAsFixed(1)} km";
    final String lastUpdate = (truck['last_update'] ?? "Just now").toString();
    final bool isHistoryVisible = _visiblePaths.contains(internalId);
    final bool isSelected = _selectedTruckId == internalId;
    final Color statusColor = status == 'FULL' ? const Color(0xFFFF1744) : (status == 'ACTIVE' ? const Color(0xFF4CAF50) : const Color(0xFFFFAB00));
    
    return GestureDetector(
      onTap: () => _toggleTrack(internalId, (truck['latitude'] ?? 13.9402).toDouble(), (truck['longitude'] ?? 121.1638).toDouble()),
      child: Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(color: isSelected ? Colors.blue.withAlpha(40) : Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(0, 4)),
          ],
          border: Border.all(color: isSelected ? Colors.blue : const Color(0xFFF5F5F5), width: isSelected ? 2 : 1),
        ),
        child: Column(children: [
          Row(children: [
            Container(width: 52, height: 52, decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.local_shipping_rounded, color: Color(0xFF1976D2), size: 28)),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(id, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))), Text(lastUpdate, style: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 13, fontWeight: FontWeight.w600))])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), decoration: BoxDecoration(color: statusColor.withAlpha(30), borderRadius: BorderRadius.circular(12)), child: Text(status, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w900))),
          ]),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildInfoItem(Icons.location_on_rounded, const Color(0xFFFF1744), "Location", location), 
            _buildInfoItem(Icons.refresh_rounded, const Color(0xFF03A9F4), "Speed", speed), 
            _buildInfoItem(Icons.badge_rounded, Colors.orange, "Plate", plateNumber),
          ]),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildInfoItem(Icons.person_rounded, const Color(0xFF1976D2), "Driver", driver),
          ]),
          const SizedBox(height: 24),
          Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [_buildStatItem(Icons.local_shipping_outlined, "DISTANCE", distance, const Color(0xFF2E7D32))])),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: _buildSecondaryButton(
              _followedTruckId == internalId ? "TRACKING" : "TRACK TRUCK", 
              _followedTruckId == internalId ? Icons.gps_fixed : Icons.center_focus_strong_rounded, 
              () => _toggleTrack(internalId, (truck['latitude'] ?? 13.9402).toDouble(), (truck['longitude'] ?? 121.1638).toDouble()),
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildPrimaryButton(
              isHistoryVisible ? "HIDE PATH" : "PATH", 
              Icons.insights_rounded, 
              isHistoryVisible ? const Color(0xFFFFA726) : const Color(0xFF00BFA5), 
              () => _togglePath(internalId),
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _buildSecondaryButton(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF5F5F5), foregroundColor: const Color(0xFF1A1A1A), elevation: 0, padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    );
  }

  Widget _buildPrimaryButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, elevation: 6, shadowColor: color.withAlpha(100), padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    );
  }

  void _togglePath(String truckId) {
    if (!_visiblePaths.contains(truckId) && !_lastRoutePoints.containsKey(truckId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No active route available for this truck.")),
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
          if (!kIsWeb) {
            _updateSharedRoutePolyline(truckId, _lastRoutePoints[truckId]!);
          } else {
            _updateWebSharedRoute(truckId, _lastRoutePoints[truckId]!);
          }
        }
      }
    });
  }

  Widget _buildInfoItem(IconData icon, Color color, String label, String value) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFBDBDBD), fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
      ]),
    );
  }

  Widget _buildStatItem(IconData icon, String label, String value, Color color) {
    return Column(children: [
      Row(children: [
        Icon(icon, size: 12, color: const Color(0xFF757575)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF757575), fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: color)),
    ]);
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
      if (data == null || data.length != pixels.length) return;

      Color lastColor = Colors.transparent;
      Path currentPath = Path();
      bool pathStarted = false;

      for (int i = 0; i < pixels.length - 1; i++) {
        final String colorName = (data[i + 1]['color'] ?? 'GREEN').toString().toUpperCase();
        Color color = const Color(0xFF4CAF50); // Material Green
        if (colorName == "YELLOW") color = const Color(0xFFFFEB3B); // Material Yellow
        else if (colorName == "PINK") color = const Color(0xFFE91E63); // Material Pink
        else if (colorName == "BLACK") color = const Color(0xFF212121); // Dark Grey
        else if (colorName == "BLUE") color = const Color(0xFF2196F3); // Material Blue
        
        if (color != lastColor) {
          // Finish previous colored path and start a new one from the SAME transition point
          if (pathStarted) {
            final paint = Paint()
              ..strokeWidth = 8.0
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..style = PaintingStyle.stroke
              ..color = lastColor.withValues(alpha: 0.85);
            canvas.drawPath(currentPath, paint);
          }
          currentPath = Path();
          currentPath.moveTo(pixels[i].dx, pixels[i].dy); // Start at previous end
          currentPath.lineTo(pixels[i+1].dx, pixels[i+1].dy);
          lastColor = color;
          pathStarted = true;
        } else {
          if (!pathStarted) {
            currentPath.moveTo(pixels[i].dx, pixels[i].dy);
            pathStarted = true;
            lastColor = color;
          }
          currentPath.lineTo(pixels[i+1].dx, pixels[i+1].dy);
        }
      }
      
      if (pathStarted) {
        final paint = Paint()
          ..strokeWidth = 8.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke
          ..color = lastColor.withValues(alpha: 0.85);
        canvas.drawPath(currentPath, paint);
      }
    });

    optimizedPixels.forEach((truckId, pixels) {
      if (pixels.length < 2) return;
      final paint = Paint()..color = Colors.blue.withValues(alpha: 0.5)..strokeWidth = 8.0..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      final path = Path(); path.moveTo(pixels[0].dx, pixels[0].dy);
      for (int i = 1; i < pixels.length; i++) path.lineTo(pixels[i].dx, pixels[i].dy);
      canvas.drawPath(path, paint);
    });
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
