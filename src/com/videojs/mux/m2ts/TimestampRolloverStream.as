package com.videojs.mux.m2ts {

  import com.videojs.mux.utils.Stream;

  public class TimestampRolloverStream extends Stream {
    private var MAX_TS:int = 8589934592;
    private var RO_THRESH:int = 4294967296;

    private var type_:String;
    private var lastDTS:int;
    private var referenceDTS:int;

    public function TimestampRolloverStream(type:String) {
      type_ = type;
      this.init();
    }

    public function push(data:Object):void {
      if (data.type !== type_) {
        return;
      }

      // TODO undefined
      if (referenceDTS === undefined) {
        referenceDTS = data.dts;
      }

      data.dts = this.handleRollover(data.dts, referenceDTS);
      data.pts = this.handleRollover(data.pts, referenceDTS);

      lastDTS = data.dts;

      this.trigger('data', data);
    }

    public function flush():void {
      referenceDTS = lastDTS;
      this.trigger('done');
    }

    private function handleRollover(value:int, reference:int):int {
      var direction = 1;

      if (value > reference) {
        // If the current timestamp value is greater than our reference timestamp and we detect a
        // timestamp rollover, this means the roll over is happening in the opposite direction.
        // Example scenario: Enter a long stream/video just after a rollover occurred. The reference
        // point will be set to a small number, e.g. 1. The user then seeks backwards over the
        // rollover point. In loading this segment, the timestamp values will be very large,
        // e.g. 2^33 - 1. Since this comes before the data we loaded previously, we want to adjust
        // the time stamp to be `value - 2^33`.
        direction = -1;
      }

      // Note: A seek forwards or back that is greater than the RO_THRESH (2^32, ~13 hours) will
      // cause an incorrect adjustment.
      while (Math.abs(reference - value) > RO_THRESH) {
        value += (direction * MAX_TS);
      }

      return value;
    }

  }
}
