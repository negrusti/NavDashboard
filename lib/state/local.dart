// Copyright Jody M Sankey 2022
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:async';

import 'package:async/async.dart';
import 'package:nmea_dashboard/state/values.dart';
import 'package:geolocator/geolocator.dart';
import 'common.dart';

const _interval = Duration(seconds: 1);

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
  ]);
}

/// Creates a stream of GPS data including coordinates (latitude and longitude),
/// COG (Course Over Ground), and SOG (Speed Over Ground).
Stream<BoundValue> _gpsDataStream() async* {
  // Ensure location permissions are granted
  bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw Exception('Location services are disabled.');
  }

  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      throw Exception('Location permissions are denied.');
    }
  }

  if (permission == LocationPermission.deniedForever) {
    throw Exception(
        'Location permissions are permanently denied, we cannot request permissions.');
  }

  // Listen to GPS updates
  Geolocator.getPositionStream(locationSettings: const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10, // Update every 10 meters
  )).listen((Position position) {
    if (position != null) {
      // Yield latitude and longitude
      yield BoundValue<SingleValue<Map<String, double>>>(
        Source.local,
        Property.gpsCoordinates,
        SingleValue({
          'latitude': position.latitude,
          'longitude': position.longitude,
        }),
      );

      // Yield Course Over Ground (COG)
      yield BoundValue<SingleValue<double>>(
        Source.local,
        Property.cog,
        SingleValue(position.heading), // Heading is equivalent to COG
      );

      // Yield Speed Over Ground (SOG)
      yield BoundValue<SingleValue<double>>(
        Source.local,
        Property.sog,
        SingleValue(position.speed), // Speed in meters/second
      );
    }
  });
}