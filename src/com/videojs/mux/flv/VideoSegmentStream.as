package com.videojs.mux.flv {

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.flv.FlvTag;
  import com.videojs.mux.flv.Utils;

  public class VideoSegmentStream extends Stream {
    private var nalUnits:Array = [];
    private var config:Object;
    private var h264Frame:FlvTag;

    /**
     * Store FlvTags for the h264 stream
     * @param track {object} track metadata configuration
     */
    public function VideoSegmentStream(track:Object) {
      this.init();
    }

    private function finishFrame(tags:Array, frame:FlvTag):void {
      if (!frame) {
        return;
      }
      // Check if keyframe and the length of tags.
      // This makes sure we write metadata on the first frame of a segment.
      if (config && track && track.newMetadata &&
          (frame.keyFrame || tags.length === 0)) {
        // Push extra data on every IDR frame in case we did a stream change + seek
        tags.push(Utils.metaDataTag(config, frame.dts));
        tags.push(Utils.extraDataTag(track, frame.dts));
        track.newMetadata = false;
      }

      frame.endNalUnit();
      tags.push(frame);
      h264Frame = null;
    }

    override public function push(data:Object):void {
      Utils.collectTimelineInfo(track, data);

      data.pts = Math.round(data.pts / 90);
      data.dts = Math.round(data.dts / 90);

      // buffer video until flush() is called
      nalUnits.push(data);
    }

    override public function flush():void {
      // TODO what is it?
      var currentNal:Object;
      var tags:Array = [];

      // Throw away nalUnits at the start of the byte stream until we find
      // the first AUD
      while (nalUnits.length) {
        if (nalUnits[0].nalUnitType === 'access_unit_delimiter_rbsp') {
          break;
        }
        nalUnits.shift();
      }

      // return early if no video data has been observed
      if (nalUnits.length === 0) {
        this.trigger('done', 'VideoSegmentStream');
        return;
      }

      while (nalUnits.length) {
        currentNal = nalUnits.shift();

        // record the track config
        if (currentNal.nalUnitType === 'seq_parameter_set_rbsp') {
          track.newMetadata = true;
          config = currentNal.config;
          track.width = config.width;
          track.height = config.height;
          track.sps = [currentNal.data];
          track.profileIdc = config.profileIdc;
          track.levelIdc = config.levelIdc;
          track.profileCompatibility = config.profileCompatibility;
          h264Frame.endNalUnit();
        } else if (currentNal.nalUnitType === 'pic_parameter_set_rbsp') {
          track.newMetadata = true;
          track.pps = [currentNal.data];
          h264Frame.endNalUnit();
        } else if (currentNal.nalUnitType === 'access_unit_delimiter_rbsp') {
          if (h264Frame) {
            this.finishFrame(tags, h264Frame);
          }
          h264Frame = new FlvTag(FlvTag.VIDEO_TAG);
          h264Frame.pts = currentNal.pts;
          h264Frame.dts = currentNal.dts;
        } else {
          if (currentNal.nalUnitType === 'slice_layer_without_partitioning_rbsp_idr') {
            // the current sample is a key frame
            h264Frame.keyFrame = true;
          }
          h264Frame.endNalUnit();
        }
        h264Frame.startNalUnit();
        h264Frame.writeBytes(currentNal.data);
      }
      if (h264Frame) {
        this.finishFrame(tags, h264Frame);
      }

      this.trigger('data', {track: track, tags: tags});

      // Continue with the flush process now
      this.trigger('done', 'VideoSegmentStream');
    }
  }
}
