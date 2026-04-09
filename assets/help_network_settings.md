This form is where you define how to read NMEA data from a network.

The settings you use here should match those on whichever device is sending your
NMEA data. You'll also need to be connected to the same WiFi network as the
device sending the NMEA data.  

# Controls

* **Mode**: Either listen for broadcast UDP packets, or connect to a TCP port.

* **Protocol**: Choose whether the incoming data is ASCII NMEA 0183 sentences
  or binary NMEA 2000 assembled packets. Use the NMEA 2000 option for gateways
  that forward complete PGNs over UDP instead of converting them to 0183 text.

* **IP Address**: Which IP address to connect to (only used when Mode is
  "Connect to TCP port").

* **Port number**: The port number to listen on (when Mode is "Listen on UDP
  port") or to connect to (when Mode is "Connect to TCP port").

* **Require checksum**: Most NMEA messages contain a checksum that lets us
  detect and ignore corrupted data, but sometimes corruption might delete that
  checksum. When "require checksum" is on, any messages without a checksum are
  assumed to be corrupted and are ignored. When "require checksum" is off,
  messages without a checksum are used if possible. You may need to turn off
  "require checksum" if a device on your network does not generate checksums but
  doing so will potentially allow corrupted data. This setting only applies to
  NMEA 0183.

* **Staleness**: The time to wait before removing old data from the display and
  replacing it with dashes. For example, if a depth has not been recieved for
  longer than this time then everywhere depth is displayed will be replaced with
  dashes. Different boats send different data at different rates so you may need
  to change this value. It should be large enough that you don't see dashes
  while everything is working fine and small enough that you notice in a
  reasonably short time if something does fail.

* **Save**: Save the changes and close the form. Alternatively tap the back
  arrow (at the top left) to close the form without saving changes.
