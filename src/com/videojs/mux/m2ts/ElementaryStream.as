package com.videojs.mux.m2ts {

  import flash.utils.ByteArray;

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.m2ts.CaptionStream;
  import com.videojs.mux.m2ts.TimestampRolloverStream;
  import com.videojs.mux.m2ts.Utils;

  /**
   * Reconsistutes program elementary stream (PES) packets from parsed
   * transport stream packets. That is, if you pipe an
   * mp2t.TransportParseStream into a mp2t.ElementaryStream, the output
   * events will be events which capture the bytes for individual PES
   * packets plus relevant metadata that has been extracted from the
   * container.
   */
  public class ElementaryStream extends Stream {
    private var self:ElementaryStream;
    // PES packet fragments
    private var video:Object = {
      data: [],
      size: 0
    };
    private var audio:Object = {
      data: [],
      size: 0
    };
    private var timedMetadata:Object = {
      data: [],
      size: 0
    };

    public function ElementaryStream() {
      self = this;
      this.init();
    }

    public function parsePes(payload:ByteArray, pes:Object):void {
      // TODO int?
      var ptsDtsFlags:int;

      // find out if this packets starts a new keyframe
      pes.dataAlignmentIndicator = (payload[6] & 0x04) !== 0;
      // PES packets may be annotated with a PTS value, or a PTS value
      // and a DTS value. Determine what combination of values is
      // available to work with.
      ptsDtsFlags = payload[7];

      // PTS and DTS are normally stored as a 33-bit number.  Javascript
      // performs all bitwise operations on 32-bit integers but javascript
      // supports a much greater range (52-bits) of integer using standard
      // mathematical operations.
      // We construct a 31-bit value using bitwise operators over the 31
      // most significant bits and then multiply by 4 (equal to a left-shift
      // of 2) before we add the final 2 least significant bits of the
      // timestamp (equal to an OR.)
      if (ptsDtsFlags & 0xC0) {
        // the PTS and DTS are not written out directly. For information
        // on how they are encoded, see
        // http://dvd.sourceforge.net/dvdinfo/pes-hdr.html
        pes.pts = (payload[9] & 0x0E) << 27 |
          (payload[10] & 0xFF) << 20 |
          (payload[11] & 0xFE) << 12 |
          (payload[12] & 0xFF) <<  5 |
          (payload[13] & 0xFE) >>>  3;
        pes.pts *= 4; // Left shift by 2
        pes.pts += (payload[13] & 0x06) >>> 1; // OR by the two LSBs
        pes.dts = pes.pts;
        if (ptsDtsFlags & 0x40) {
          pes.dts = (payload[14] & 0x0E) << 27 |
            (payload[15] & 0xFF) << 20 |
            (payload[16] & 0xFE) << 12 |
            (payload[17] & 0xFF) << 5 |
            (payload[18] & 0xFE) >>> 3;
          pes.dts *= 4; // Left shift by 2
          pes.dts += (payload[18] & 0x06) >>> 1; // OR by the two LSBs
        }
      }
      // the data section starts immediately after the PES header.
      // pes_header_data_length specifies the number of header bytes
      // that follow the last byte of the field.
      pes.data = payload.subarray(9 + payload[8]);
    }

    public function flushStream(stream:Object, type:String):void {
      // TODO Uint8Array
      var packetData:ByteArray = new ByteArray(stream.size),
      var event:Object = {
        type: type
      };
      var i:int = 0;
      var fragment:Object;

      // do nothing if there is no buffered data
      if (!stream.data.length) {
        return;
      }
      event.trackId = stream.data[0].pid;

      // reassemble the packet
      while (stream.data.length) {
        fragment = stream.data.shift();

        packetData.set(fragment.data, i);
        i += fragment.data.byteLength;
      }

      // parse assembled packet's PES header
      parsePes(packetData, event);

      stream.size = 0;

      this..trigger('data', event);
    }

    // TODO ugh
    override public function push(data:Object):void {
      ({
        pat: function() {
          // we have to wait for the PMT to arrive as well before we
          // have any meaningful metadata
        },
        pes: function() {
          var stream, streamType;

          switch (data.streamType) {
          case Utils.StreamTypes.H264_STREAM_TYPE:
          case Utils.StreamTypes.H264_STREAM_TYPE:
            stream = video;
            streamType = 'video';
            break;
          case Utils.StreamTypes.ADTS_STREAM_TYPE:
            stream = audio;
            streamType = 'audio';
            break;
          case Utils.StreamTypes.METADATA_STREAM_TYPE:
            stream = timedMetadata;
            streamType = 'timed-metadata';
            break;
          default:
            // ignore unknown stream types
            return;
          }

          // if a new packet is starting, we can flush the completed
          // packet
          if (data.payloadUnitStartIndicator) {
            flushStream(stream, streamType);
          }

          // buffer this fragment until we are sure we've received the
          // complete payload
          stream.data.push(data);
          stream.size += data.data.byteLength;
        },
        pmt: function() {
          var
            event = {
              type: 'metadata',
              tracks: []
            },
            programMapTable = data.programMapTable,
            k,
            track;

          // translate streams to tracks
          for (k in programMapTable) {
            if (programMapTable.hasOwnProperty(k)) {
              track = {
                timelineStartInfo: {
                  baseMediaDecodeTime: 0
                }
              };
              track.id = +k;
              if (programMapTable[k] === Utils.StreamTypes.H264_STREAM_TYPE) {
                track.codec = 'avc';
                track.type = 'video';
              } else if (programMapTable[k] === Utils.StreamTypes.ADTS_STREAM_TYPE) {
                track.codec = 'adts';
                track.type = 'audio';
              }
              event.tracks.push(track);
            }
          }
          self.trigger('data', event);
        }
      })[data.type]();
    }

    /**
     * Flush any remaining input. Video PES packets may be of variable
     * length. Normally, the start of a new video packet can trigger the
     * finalization of the previous packet. That is not possible if no
     * more video is forthcoming, however. In that case, some other
     * mechanism (like the end of the file) has to be employed. When it is
     * clear that no additional data is forthcoming, calling this method
     * will flush the buffered packets.
     */
    override public function flush():void {
      // !!THIS ORDER IS IMPORTANT!!
      // video first then audio
      flushStream(video, 'video');
      flushStream(audio, 'audio');
      flushStream(timedMetadata, 'timed-metadata');
      this.trigger('done');
    }
  }

  // TODO ugh
  var m2ts = {
    PAT_PID: 0x0000,
    MP2T_PACKET_LENGTH: Utils.MP2T_PACKET_LENGTH,
    TransportPacketStream: TransportPacketStream,
    TransportParseStream: TransportParseStream,
    ElementaryStream: ElementaryStream,
    TimestampRolloverStream: TimestampRolloverStream,
    CaptionStream: CaptionStream.CaptionStream,
    Cea608Stream: CaptionStream.Cea608Stream,
    MetadataStream: require('./metadata-stream')
  };

  for (var type in Utils.StreamTypes) {
    if (Utils.StreamTypes.hasOwnProperty(type)) {
      m2ts[type] = Utils.StreamTypes[type];
    }
  }
}
