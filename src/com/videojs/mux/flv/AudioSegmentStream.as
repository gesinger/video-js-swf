package com.videojs.mux.flv {

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.flv.FlvTag;
  import com.videojs.mux.flv.Utils;

  /**
   * Constructs a single-track, media segment from AAC data
   * events. The output of this stream can be fed to flash.
   */
  public class AudioSegmentStream extends Stream {
    private var adtsFrames:Array = [];
    private var oldExtraData:Object;

    public function AudioSegmentStream(track:Object) {
      this.init();
    }

    override public function push(data:Object):void {
      Utils.collectTimelineInfo(track, data);

      if (track && track.channelcount === undefined) {
        track.audioobjecttype = data.audioobjecttype;
        track.channelcount = data.channelcount;
        track.samplerate = data.samplerate;
        track.samplingfrequencyindex = data.samplingfrequencyindex;
        track.samplesize = data.samplesize;
        track.extraData = (track.audioobjecttype << 11) |
                          (track.samplingfrequencyindex << 7) |
                          (track.channelcount << 3);
      }

      data.pts = Math.round(data.pts / 90);
      data.dts = Math.round(data.dts / 90);

      // buffer audio data until end() is called
      adtsFrames.push(data);
    }

    override public function flush():void {
      var currentFrame:Object;
      var adtsFrame:FlvTag;
      var lastMetaPts:int;
      var tags:Array = [];

      // return early if no audio data has been observed
      if (adtsFrames.length === 0) {
        this.trigger('done', 'AudioSegmentStream');
        return;
      }

      lastMetaPts = -Infinity;

      while (adtsFrames.length) {
        currentFrame = adtsFrames.shift();

        // write out metadata tags every 1 second so that the decoder
        // is re-initialized quickly after seeking into a different
        // audio configuration
        if (track.extraData !== oldExtraData || currentFrame.pts - lastMetaPts >= 1000) {
         adtsFrame = new FlvTag(FlvTag.METADATA_TAG);
          adtsFrame.pts = currentFrame.pts;
          adtsFrame.dts = currentFrame.dts;

          // AAC is always 10
          adtsFrame.writeMetaDataDouble('audiocodecid', 10);
          adtsFrame.writeMetaDataBoolean('stereo', track.channelcount === 2);
          adtsFrame.writeMetaDataDouble('audiosamplerate', track.samplerate);
          // Is AAC always 16 bit?
          adtsFrame.writeMetaDataDouble('audiosamplesize', 16);

          tags.push(adtsFrame);

          oldExtraData = track.extraData;

          adtsFrame = new FlvTag(FlvTag.AUDIO_TAG, true);
          // For audio, DTS is always the same as PTS. We want to set the DTS
          // however so we can compare with video DTS to determine approximate
          // packet order
          adtsFrame.pts = currentFrame.pts;
          adtsFrame.dts = currentFrame.dts;

          adtsFrame.view.setUint16(adtsFrame.position, track.extraData);
          adtsFrame.position += 2;
          adtsFrame.length = Math.max(adtsFrame.length, adtsFrame.position);

          tags.push(adtsFrame);

          lastMetaPts = currentFrame.pts;
        }
        adtsFrame = new FlvTag(FlvTag.AUDIO_TAG);
        adtsFrame.pts = currentFrame.pts;
        adtsFrame.dts = currentFrame.dts;

        adtsFrame.writeBytes(currentFrame.data);

        tags.push(adtsFrame);
      }

      oldExtraData = null;
      this.trigger('data', {track: track, tags: tags});

      this.trigger('done', 'AudioSegmentStream');
    }
  }
}
