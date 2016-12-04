package com.videojs.mux.flv {

  import flash.utils.ByteArray;

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.flv.FlvTag;
  import com.videojs.mux.flv.Utils;
  import com.videojs.mux.flv.AudioSegmentStream;
  import com.videojs.mux.flv.VideoSegmentStream;
  import com.videojs.mux.m2ts.M2tsMetadataStream;
  import com.videojs.mux.m2ts.M2tsTransportPacketStream;
  import com.videojs.mux.m2ts.M2tsTransportParseStream;
  import com.videojs.mux.m2ts.M2tsElementaryStream;
  import com.videojs.mux.m2ts.M2tsTimestampRolloverStream;
  import com.videojs.mux.m2ts.M2tsCaptionStream;
  import com.videojs.mux.codecs.AdtsStream;
  import com.videojs.mux.codecs.H264Stream;
  import com.videojs.mux.flv.CoalesceStream;

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
    override public function push(data:Object):void {
      packetStream.push(data);
    }

    // flush any buffered data
    override public function flush():void {
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
