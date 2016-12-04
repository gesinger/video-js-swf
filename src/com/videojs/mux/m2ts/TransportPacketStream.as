package com.videojs.mux.m2ts {

  import flash.utils.ByteArray;
  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.m2ts.Utils;

  /**
   * Splits an incoming stream of binary data into MPEG-2 Transport
   * Stream packets.
   */
  public class TransportPacketStream extends Stream {
    // TODO int?
    private var SYNC_BYTE:int = 0x47;

    // TODO Uint8Array
    private buffer:ByteArray = new ByteArray(Utils.MP2T_PACKET_LENGTH);
    private bytesInBuffer:int = 0;

    public function TransportPacketStream() {
      this.init();
    }

   // Deliver new bytes to the stream.
   // TODO ByteArray?
    override public function push(bytes:ByteArray):void {
      var startIndex:int = 0;
      var endIndex:int = Utils.MP2T_PACKET_LENGTH;
      // TODO Uint8Array
      var everything:ByteArray;

      // If there are bytes remaining from the last segment, prepend them to the
      // bytes that were pushed in
      if (bytesInBuffer) {
        everything = new ByteArray(bytes.byteLength + bytesInBuffer);
        everything.set(buffer.subarray(0, bytesInBuffer));
        everything.set(bytes, bytesInBuffer);
        bytesInBuffer = 0;
      } else {
        everything = bytes;
      }

      // While we have enough data for a packet
      while (endIndex < everything.byteLength) {
        // Look for a pair of start and end sync bytes in the data..
        if (everything[startIndex] === SYNC_BYTE && everything[endIndex] === SYNC_BYTE) {
          // We found a packet so emit it and jump one whole packet forward in
          // the stream
          this.trigger('data', everything.subarray(startIndex, endIndex));
          startIndex += Utils.MP2T_PACKET_LENGTH;
          endIndex += Utils.MP2T_PACKET_LENGTH;
          continue;
        }
        // If we get here, we have somehow become de-synchronized and we need to step
        // forward one byte at a time until we find a pair of sync bytes that denote
        // a packet
        startIndex++;
        endIndex++;
      }

      // If there was some data left over at the end of the segment that couldn't
      // possibly be a whole packet, keep it because it might be the start of a packet
      // that continues in the next segment
      if (startIndex < everything.byteLength) {
        buffer.set(everything.subarray(startIndex), 0);
        bytesInBuffer = everything.byteLength - startIndex;
      }
    }

    override public function flush():void {
      // If the buffer contains a whole packet when we are being flushed, emit it
      // and empty the buffer. Otherwise hold onto the data because it may be
      // important for decoding the next segment
      if (bytesInBuffer === Utils.MP2T_PACKET_LENGTH && buffer[0] === SYNC_BYTE) {
        this.trigger('data', buffer);
        bytesInBuffer = 0;
      }
      this.trigger('done');
    }
  }
}
