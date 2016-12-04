package com.videojs.mux.codecs {

  import flash.utils.ByteArray;

  /**
   * Accepts a NAL unit byte stream and unpacks the embedded NAL units.
   */
  public class NalByteStream extends Stream{

    private var syncPoint:int = 0;
    private var i:int;
    private var buffer:ByteArray;

    public function NalByteStream() {
      this.init();
    }

    override public function push(data:Object):void {
      var swapBuffer:ByteArray;

      if (!buffer) {
        buffer = data.data;
      } else {
        // TODO Uint8Array
        swapBuffer = new ByteArray(buffer.byteLength + data.data.byteLength);
        swapBuffer.set(buffer);
        swapBuffer.set(data.data, buffer.byteLength);
        buffer = swapBuffer;
      }

      // Rec. ITU-T H.264, Annex B
      // scan for NAL unit boundaries

      // a match looks like this:
      // 0 0 1 .. NAL .. 0 0 1
      // ^ sync point        ^ i
      // or this:
      // 0 0 1 .. NAL .. 0 0 0
      // ^ sync point        ^ i

      // advance the sync point to a NAL start, if necessary
      for (; syncPoint < buffer.byteLength - 3; syncPoint++) {
        if (buffer[syncPoint + 2] === 1) {
          // the sync point is properly aligned
          i = syncPoint + 5;
          break;
        }
      }

      while (i < buffer.byteLength) {
        // look at the current byte to determine if we've hit the end of
        // a NAL unit boundary
        switch (buffer[i]) {
        case 0:
          // skip past non-sync sequences
          if (buffer[i - 1] !== 0) {
            i += 2;
            break;
          } else if (buffer[i - 2] !== 0) {
            i++;
            break;
          }

          // deliver the NAL unit if it isn't empty
          if (syncPoint + 3 !== i - 2) {
            this.trigger('data', buffer.subarray(syncPoint + 3, i - 2));
          }

          // drop trailing zeroes
          do {
            i++;
          } while (buffer[i] !== 1 && i < buffer.length);
          syncPoint = i - 2;
          i += 3;
          break;
        case 1:
          // skip past non-sync sequences
          if (buffer[i - 1] !== 0 ||
              buffer[i - 2] !== 0) {
            i += 3;
            break;
          }

          // deliver the NAL unit
          this.trigger('data', buffer.subarray(syncPoint + 3, i - 2));
          syncPoint = i - 2;
          i += 3;
          break;
        default:
          // the current byte isn't a one or zero, so it cannot be part
          // of a sync sequence
          i += 3;
          break;
        }
      }
      // filter out the NAL units that were delivered
      buffer = buffer.subarray(syncPoint);
      i -= syncPoint;
      syncPoint = 0;
    }

    override public function flush():void {
      // deliver the last buffered NAL unit
      if (buffer && buffer.byteLength > 3) {
        this.trigger('data', buffer.subarray(syncPoint + 3));
      }
      // reset the stream state
      buffer = null;
      syncPoint = 0;
      this.trigger('done');
    }
  }
}
