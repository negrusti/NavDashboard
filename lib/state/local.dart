// Copyright Jody M Sankey 2022
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:async';

import 'package:async/async.dart';
import 'package:logging/logging.dart';
import 'package:nmea_dashboard/state/values.dart';
import 'package:geolocator/geolocator.dart';
import 'common.dart';

const _interval = Duration(seconds: 1);
final _log = Logger('Local');
bool _loggedFirstGpsFix = false;

/// Returns an infinite stream of valid values read from the local device
/// network port, logging any errors.
Stream<BoundValue> valuesFromLocalDevice() {
  return StreamGroup.merge([
    Stream.periodic(_interval, (_) {
      return BoundValue<SingleValue<DateTime>>(
          Source.local, Property.localTime, SingleValue(DateTime.now()));
    }),
    Stream.periodic(_interval, (_) {
      return BoundValue<SingleValue<DateTime>>(
          Source.local, Property.utcTime, SingleValue(DateTime.now().toUtc()));
    }),
    // GPS data (coordinates, COG, SOG)
    _gpsDataStream(),

    // Barometric pressure stream
    // _pressureDataStream(),    
  ]);
}

Stream<BoundValue> _gpsDataStream() async* {
  if (!await _hasLocationPermission()) {
    return;
  }

  final lastKnown = await Geolocator.getLastKnownPosition();
  if (lastKnown != null) {
    for (final value in _valuesFromPosition(lastKnown)) {
      yield value;
    }
  }

  try {
    final current = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    ).timeout(const Duration(seconds: 15));
    for (final value in _valuesFromPosition(current)) {
      yield value;
    }
  } on TimeoutException {
    _log.warning('Timed out waiting for local GPS position');
  } catch (e) {
    _log.warning('Error reading initial local GPS position: $e');
  }

  final positionStream = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    ),
  ).handleError((e) {
    _log.warning('Error reading local GPS data: $e');
  });

  await for (final position in positionStream) {
    for (final value in _valuesFromPosition(position)) {
      yield value;
    }
  }
}

Future<bool> _hasLocationPermission() async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    _log.warning('Location services are disabled');
    return false;
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    _log.warning('Location permissions are denied');
    return false;
  }
  if (permission == LocationPermission.deniedForever) {
    _log.warning('Location permissions are permanently denied');
    return false;
  }
  return true;
}

Iterable<BoundValue> _valuesFromPosition(Position position) {
  if (!_loggedFirstGpsFix) {
    _log.info(
        'Local GPS fix received: ${position.latitude}, ${position.longitude}, '
        'heading=${position.heading}, speed=${position.speed}');
    _loggedFirstGpsFix = true;
  }
  return [
    BoundValue<DoubleValue<double>>(
      Source.local,
      Property.gpsPosition,
      DoubleValue(position.latitude, position.longitude),
    ),
    BoundValue<SingleValue<double>>(
      Source.local,
      Property.courseOverGround,
      SingleValue(position.heading),
    ),
    BoundValue<SingleValue<double>>(
      Source.local,
      Property.speedOverGround,
      SingleValue(position.speed),
    ),
  ];
}

/*
Stream<BoundValue> _pressureDataStream() {
  return Stream.periodic(_interval, (_) async {
    double? barometricPressure;

    try {
      // Get the latest pressure event
      final barometerEvent = await barometerEvents.first;
      barometricPressure = barometerEvent.pressure;
    } catch (e) {
      throw Exception('Error accessing barometer data: $e');
    }

    // Return the pressure as a BoundValue
    return BoundValue<SingleValue<double>>(
      Source.local,
      Property.pressure,
      SingleValue(barometricPressure ?? 0.0), // Default to 0.0 if null
    );
  }).asyncMap((event) async => await event); // Handle the async result
}
*/
