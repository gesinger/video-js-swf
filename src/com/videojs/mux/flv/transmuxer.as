package com.videojs.mux.flv {

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.flv.FlvTag;
  import com.videojs.mux.m2ts.M2tsMetadataStream;
  import com.videojs.mux.m2ts.M2tsTransportPacketStream;
  import com.videojs.mux.m2ts.M2tsTransportParseStream;
  import com.videojs.mux.m2ts.M2tsElementaryStream;
  import com.videojs.mux.m2ts.M2tsTimestampRolloverStream;
  import com.videojs.mux.m2ts.M2tsCaptionStream;
  import com.videojs.mux.codecs.AdtsStream;
  import com.videojs.mux.codecs.H264Stream;
  import com.videojs.mux.flv.CoalesceStream;

  /**
   * Store information about the start and end of the tracka and the
   * duration for each frame/sample we process in order to calculate
   * the baseMediaDecodeTime
   */
  // TODO typeof and undefined
  function collectTimelineInfo(track:Object, data:Object):void {
    if (typeof data.pts === 'number') {
      if (track.timelineStartInfo.pts === undefined) {
        track.timelineStartInfo.pts = data.pts;
      } else {
        track.timelineStartInfo.pts =
          Math.min(track.timelineStartInfo.pts, data.pts);
      }
    }

    if (typeof data.dts === 'number') {
      if (track.timelineStartInfo.dts === undefined) {
        track.timelineStartInfo.dts = data.dts;
      } else {
        track.timelineStartInfo.dts =
          Math.min(track.timelineStartInfo.dts, data.dts);
      }
    }
  }

  function metaDataTag(track:Object, pts:int):FlvTag {
    var tag:FlvTag = new FlvTag(FlvTag.METADATA_TAG);

    tag.dts = pts;
    tag.pts = pts;

    tag.writeMetaDataDouble('videocodecid', 7);
    tag.writeMetaDataDouble('width', track.width);
    tag.writeMetaDataDouble('height', track.height);

    return tag;
  }

  function extraDataTag(track:Object, pts:int):FlvTag {
    var i:int;
    var tag:FlvTag = new FlvTag(FlvTag.VIDEO_TAG, true);

    tag.dts = pts;
    tag.pts = pts;

    tag.writeByte(0x01);// version
    tag.writeByte(track.profileIdc);// profile
    tag.writeByte(track.profileCompatibility);// compatibility
    tag.writeByte(track.levelIdc);// level
    tag.writeByte(0xFC | 0x03); // reserved (6 bits), NULA length size - 1 (2 bits)
    tag.writeByte(0xE0 | 0x01); // reserved (3 bits), num of SPS (5 bits)
    tag.writeShort(track.sps[0].length); // data of SPS
    tag.writeBytes(track.sps[0]); // SPS

    tag.writeByte(track.pps.length); // num of PPS (will there ever be more that 1 PPS?)
    for (i = 0; i < track.pps.length; ++i) {
      tag.writeShort(track.pps[i].length); // 2 bytes for length of PPS
      tag.writeBytes(track.pps[i]); // data of PPS
    }

    return tag;
  }

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

    public function push(data:Object):void {
      collectTimelineInfo(track, data);

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

    public function flush():void {
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
        tags.push(metaDataTag(config, frame.dts));
        tags.push(extraDataTag(track, frame.dts));
        track.newMetadata = false;
      }

      frame.endNalUnit();
      tags.push(frame);
      h264Frame = null;
    }

    private function push(data:Object):void {
      collectTimelineInfo(track, data);

      data.pts = Math.round(data.pts / 90);
      data.dts = Math.round(data.dts / 90);

      // buffer video until flush() is called
      nalUnits.push(data);
    }

    private function flush():void {
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

  public class Transmuxer extends Stream {
    private var self:Transmuxer;
    private var options:Object;

    private var packetStream:M2tsTransportPacketStream = new M2tsTransportPacketStream();
    private var parseStream:M2tsTransportParseStream = new M2tsTransportParseStream();
    private var elementaryStream:M2tsElementaryStream = new M2tsElementaryStream();
    private var videoTimestampRolloverStream:M2tsTimestampRolloverStream = new M2tsTimestampRolloverStream('video');
    private var audioTimestampRolloverStream:M2tsTimestampRolloverStream = new M2tsTimestampRolloverStream('audio');
    private var timedMetadataTimestampRolloverStream:M2tsTimestampRolloverStream = new M2tsTimestampRolloverStream('timed-metadata');
    private var captionStream:M2tsCaptionStream = new M2tsCaptionStream();

    private var adtsStream:AdtsStream = new AdtsStream();
    private var h264Stream:H264Stream = new H264Stream();

    private var coalesceStream:CoalesceStream;
    private var videoSegmentStream:VideoSegmentStream;
    private var audioSegmentStream:AudioSegmentStream;

    public var metadataStream:M2tsMetadataStream = new M2tsMetadataStream();

    public function Transmuxer(setOptions:Object) {
      self = this;
      this.init();
      options = setOptions || {};

      options.metadataStream = metadataStream;

      coalesceStream = new CoalesceStream(options);

      // disassemble MPEG2-TS packets into elementary streams
      packetStream
        .pipe(parseStream)
        .pipe(elementaryStream);

      // !!THIS ORDER IS IMPORTANT!!
      // demux the streams
      elementaryStream
        .pipe(videoTimestampRolloverStream)
        .pipe(h264Stream);
      elementaryStream
        .pipe(audioTimestampRolloverStream)
        .pipe(adtsStream);

      elementaryStream
        .pipe(timedMetadataTimestampRolloverStream)
        .pipe(metadataStream)
        .pipe(coalesceStream);

      // if CEA-708 parsing is available, hook up a caption stream
      h264Stream.pipe(captionStream)
        .pipe(coalesceStream);

      // hook up the segment streams once track metadata is delivered
      elementaryStream.on('data', function(data:Object) {
        var i:int;
        var videoTrack:Object;
        var audioTrack:Object;

        if (data.type === 'metadata') {
          i = data.tracks.length;

          // scan the tracks listed in the metadata
          while (i--) {
            if (data.tracks[i].type === 'video') {
              videoTrack = data.tracks[i];
            } else if (data.tracks[i].type === 'audio') {
              audioTrack = data.tracks[i];
            }
          }

          // hook up the video segment stream to the first track with h264 data
          if (videoTrack && !videoSegmentStream) {
            coalesceStream.numberOfTracks++;
            videoSegmentStream = new VideoSegmentStream(videoTrack);

            // Set up the final part of the video pipeline
            h264Stream
              .pipe(videoSegmentStream)
              .pipe(coalesceStream);
          }

          if (audioTrack && !audioSegmentStream) {
            // hook up the audio segment stream to the first track with aac data
            coalesceStream.numberOfTracks++;
            audioSegmentStream = new AudioSegmentStream(audioTrack);

            // Set up the final part of the audio pipeline
            adtsStream
              .pipe(audioSegmentStream)
              .pipe(coalesceStream);
          }
        }
      });

      // Re-emit any data coming from the coalesce stream to the outside world
      coalesceStream.on('data', function(event:Object):void {
        self.trigger('data', event);
      });

      // Let the consumer know we have finished flushing the entire pipeline
      coalesceStream.on('done', function():void {
        self.trigger('done');
      });
    }

    // feed incoming data to the front of the parsing pipeline
    public function push(data:Object):void {
      packetStream.push(data);
    }

    // flush any buffered data
    public function flush():void {
      // Start at the top of the pipeline and flush all pending work
      packetStream.flush();
    }

    // For information on the FLV format, see
    // http://download.macromedia.com/f4v/video_file_format_spec_v10_1.pdf.
    // Technically, this function returns the header and a metadata FLV tag
    // if duration is greater than zero
    // duration in seconds
    // @return {object} the bytes of the FLV header as a Uint8Array
    public function getFlvHeader(duration:int, audio:Object, video:Object):ByteArray {
      // TODO Uint8
      var headBytes:ByteArray = new ByteArray(3 + 1 + 1 + 4);
      // TODO DataView
      var head:DataView = new DataView(headBytes.buffer);
      var metadata:FlvTag;
      // TODO Uint8Array
      var result:ByteArray;
      var metadataLength:int;

      // default arguments
      duration = duration || 0;
      audio = audio === undefined ? true : audio;
      video = video === undefined ? true : video;

      // signature
      head.setUint8(0, 0x46); // 'F'
      head.setUint8(1, 0x4c); // 'L'
      head.setUint8(2, 0x56); // 'V'

      // version
      head.setUint8(3, 0x01);

      // flags
      head.setUint8(4, (audio ? 0x04 : 0x00) | (video ? 0x01 : 0x00));

      // data offset, should be 9 for FLV v1
      head.setUint32(5, headBytes.byteLength);

      // init the first FLV tag
      if (duration <= 0) {
        // no duration available so just write the first field of the first
        // FLV tag
        result = new ByteArray(headBytes.byteLength + 4);
        result.set(headBytes);
        result.set([0, 0, 0, 0], headBytes.byteLength);
        return result;
      }

      // write out the duration metadata tag
      metadata = new FlvTag(FlvTag.METADATA_TAG);
      metadata.pts = metadata.dts = 0;
      metadata.writeMetaDataDouble('duration', duration);
      metadataLength = metadata.finalize().length;
      result = new ByteArray(headBytes.byteLength + metadataLength);
      result.set(headBytes);
      result.set(head.byteLength, metadataLength);

      return result;
    }
  }
}
