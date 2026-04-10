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

Stream<BoundValue> _gpsDataStream() {
  return Stream.periodic(_interval, (_) async {
    try {
      // Ensure location permissions are granted
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _log.warning('Location services are disabled');
        return <BoundValue>[];
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _log.warning('Location permissions are denied');
          return <BoundValue>[];
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _log.warning('Location permissions are permanently denied');
        return <BoundValue>[];
      }

      // Get the latest position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Create a list of BoundValue objects for all GPS-related properties
      return [
        BoundValue<DoubleValue<double>>(
          Source.local,
          Property.gpsPosition,
          DoubleValue(position.latitude, position.longitude),
        ),
        BoundValue<SingleValue<double>>(
          Source.local,
          Property.courseOverGround,
          SingleValue(position.heading), // Heading (COG)
        ),
        BoundValue<SingleValue<double>>(
          Source.local,
          Property.speedOverGround,
          SingleValue(position.speed), // Speed (SOG)
        ),
      ];
    } catch (e) {
      _log.warning('Error reading local GPS data: $e');
      return <BoundValue>[];
    }
  })
      .asyncMap((values) async => await values) // Handle futures in the periodic stream
      .expand((values) => values); // Flatten the list of BoundValue into individual stream events
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
