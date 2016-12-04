package com.videojs.mux.m2ts {

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.m2ts.Utils;
  import com.videojs.mux.m2ts.Cea608Stream;

  // -----------------
  // Link To Transport
  // -----------------

  public class CaptionStream extends Stream {
    private var captionPackets_:Array = [];
    private var field1_:Cea608Stream = new Cea608Stream();

    public function CaptionStream() {
      this.init();
      // forward data and done events from field1_ to this CaptionStream
      this.field1_.on('data', this.trigger.bind(this, 'data'));
      this.field1_.on('done', this.trigger.bind(this, 'done'));
    }

    public function push(event:Object):void {
      var sei:Object;
      var userData:Array;

      // only examine SEI NALs
      if (event.nalUnitType !== 'sei_rbsp') {
        return;
      }

      // parse the sei
      sei = Utils.parseSei(event.escapedRBSP);

      // ignore everything but user_data_registered_itu_t_t35
      if (sei.payloadType !== Utils.USER_DATA_REGISTERED_ITU_T_T35) {
        return;
      }

      // parse out the user data payload
      userData = Utils.parseUserData(sei);

      // ignore unrecognized userData
      if (!userData) {
        return;
      }

      // parse out CC data packets and save them for later
      captionPackets_ = captionPackets_.concat(Utils.parseCaptionPackets(event.pts, userData));
    }

    public function flush():void {
      // make sure we actually parsed captions before proceeding
      if (!captionPackets_.length) {
        field1_.flush();
        return;
      }

      // In Chrome, the Array#sort function is not stable so add a
      // presortIndex that we can use to ensure we get a stable-sort
      captionPackets_.forEach(function(elem, idx) {
        elem.presortIndex = idx;
      });

      // sort caption byte-pairs based on their PTS values
      captionPackets_.sort(function(a, b) {
        if (a.pts === b.pts) {
          return a.presortIndex - b.presortIndex;
        }
        return a.pts - b.pts;
      });

      // Push each caption into Cea608Stream
      captionPackets_.forEach(field1_.push, field1_);

      captionPackets_.length = 0;
      field1_.flush();
      return;
    }
  }
}
