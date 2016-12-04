package com.videojs.mux.codecs{

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.utils.ExpGolomb;
  import com.videojs.mux.codecs.NalByteStream;

  // values of profile_idc that indicate additional fields are included in the SPS
  // see Recommendation ITU-T H.264 (4/2013),
  // 7.3.2.1.1 Sequence parameter set data syntax
  var PROFILES_WITH_OPTIONAL_SPS_DATA:Object = {
    100: true,
    110: true,
    122: true,
    244: true,
    44: true,
    83: true,
    86: true,
    118: true,
    128: true,
    138: true,
    139: true,
    134: true
  };

  /**
   * Accepts input from a ElementaryStream and produces H.264 NAL unit data
   * events.
   */
  public class H264Stream extends Stream{

    private var nalByteStream:NalByteStream = new NalByteStream();
    private var self:H264Stream;
    // TODO correct?
    private var trackId:String;
    private var currentPts:int;
    private var currentDts:int;

    public function H264Stream() {
      this.init();
      self = this;

      nalByteStream.on('data', function(data:Object):void {
        var event = {
          trackId: trackId,
          pts: currentPts,
          dts: currentDts,
          data: data
        };

        switch (data[0] & 0x1f) {
        case 0x05:
          event.nalUnitType = 'slice_layer_without_partitioning_rbsp_idr';
          break;
        case 0x06:
          event.nalUnitType = 'sei_rbsp';
          event.escapedRBSP = this.discardEmulationPreventionBytes(data.subarray(1));
          break;
        case 0x07:
          event.nalUnitType = 'seq_parameter_set_rbsp';
          event.escapedRBSP = this.discardEmulationPreventionBytes(data.subarray(1));
          event.config = this.readSequenceParameterSet(event.escapedRBSP);
          break;
        case 0x08:
          event.nalUnitType = 'pic_parameter_set_rbsp';
          break;
        case 0x09:
          event.nalUnitType = 'access_unit_delimiter_rbsp';
          break;

        default:
          break;
        }

        self.trigger('data', event);
      });

      nalByteStream.on('done', function():void {
        self.trigger('done');
      });
    }

    override public function push(packet:Object):void {
      if (packet.type !== 'video') {
        return;
      }
      trackId = packet.trackId;
      currentPts = packet.pts;
      currentDts = packet.dts;

      nalByteStream.push(packet);
    };


    override public function flush():void {
      nalByteStream.flush();
    };

    /**
     * Advance the ExpGolomb decoder past a scaling list. The scaling
     * list is optionally transmitted as part of a sequence parameter
     * set and is not relevant to transmuxing.
     * @param count {number} the number of entries in this scaling list
     * @param expGolombDecoder {object} an ExpGolomb pointed to the
     * start of a scaling list
     * @see Recommendation ITU-T H.264, Section 7.3.2.1.1.1
     */
    private function skipScalingList(count:int, expGolombDecoder:ExpGolomb):void {
      var lastScale:int = 8;
      var nextScale:int = 8;
      var j:int;
      var deltaScale:int;

      for (j = 0; j < count; j++) {
        if (nextScale !== 0) {
          deltaScale = expGolombDecoder.readExpGolomb();
          nextScale = (lastScale + deltaScale + 256) % 256;
        }

        lastScale = (nextScale === 0) ? lastScale : nextScale;
      }
    }

    /**
     * Expunge any "Emulation Prevention" bytes from a "Raw Byte
     * Sequence Payload"
     * @param data {Uint8Array} the bytes of a RBSP from a NAL
     * unit
     * @return {Uint8Array} the RBSP without any Emulation
     * Prevention Bytes
     */
    private function discardEmulationPreventionBytes(data:ByteArray):ByteArray {
      var length:int = data.byteLength;
      var emulationPreventionBytesPositions:Array = [];
      var i:int = 1;
      var newLength:int;
      var newData:ByteArray;

      // Find all `Emulation Prevention Bytes`
      while (i < length - 2) {
        if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0x03) {
          emulationPreventionBytesPositions.push(i + 2);
          i += 2;
        } else {
          i++;
        }
      }

      // If no Emulation Prevention Bytes were found just return the original
      // array
      if (emulationPreventionBytesPositions.length === 0) {
        return data;
      }

      // Create a new array to hold the NAL unit data
      newLength = length - emulationPreventionBytesPositions.length;
      // TODO Uint8Array
      newData = new ByteArray(newLength);
      var sourceIndex = 0;

      for (i = 0; i < newLength; sourceIndex++, i++) {
        if (sourceIndex === emulationPreventionBytesPositions[0]) {
          // Skip this byte
          sourceIndex++;
          // Remove this position index
          emulationPreventionBytesPositions.shift();
        }
        newData[i] = data[sourceIndex];
      }

      return newData;
    }

    /**
     * Read a sequence parameter set and return some interesting video
     * properties. A sequence parameter set is the H264 metadata that
     * describes the properties of upcoming video frames.
     * @param data {Uint8Array} the bytes of a sequence parameter set
     * @return {object} an object with configuration parsed from the
     * sequence parameter set, including the dimensions of the
     * associated video frames.
     */
    private function readSequenceParameterSet(data:ByteArray):Object {
      var frameCropLeftOffset:int = 0;
      var frameCropRightOffset:int = 0;
      var frameCropTopOffset:int = 0;
      var frameCropBottomOffset:int = 0;
      var sarScale:int = 1;
      var expGolombDecoder:ExpGolomb;
      // TODO Bytes?
      var profileIdc:Byte;
      var levelIdc:Byte;
      var profileCompatibility:Byte;
      var chromaFormatIdc:Byte;
      var picOrderCntType:Byte;
      var numRefFramesInPicOrderCntCycle:Byte;
      var picWidthInMbsMinus1:Byte;
      var picHeightInMapUnitsMinus1:Byte;
      // TODO bits?
      var frameMbsOnlyFlag:Bit;
      var scalingListCount:int;
      var sarRatio:Array;
      var aspectRatioIdc:Byte;
      var i:int;

      expGolombDecoder = new ExpGolomb(data);
      profileIdc = expGolombDecoder.readUnsignedByte(); // profile_idc
      profileCompatibility = expGolombDecoder.readUnsignedByte(); // constraint_set[0-5]_flag
      levelIdc = expGolombDecoder.readUnsignedByte(); // level_idc u(8)
      expGolombDecoder.skipUnsignedExpGolomb(); // seq_parameter_set_id

      // some profiles have more optional data we don't need
      if (PROFILES_WITH_OPTIONAL_SPS_DATA[profileIdc]) {
        chromaFormatIdc = expGolombDecoder.readUnsignedExpGolomb();
        if (chromaFormatIdc === 3) {
          expGolombDecoder.skipBits(1); // separate_colour_plane_flag
        }
        expGolombDecoder.skipUnsignedExpGolomb(); // bit_depth_luma_minus8
        expGolombDecoder.skipUnsignedExpGolomb(); // bit_depth_chroma_minus8
        expGolombDecoder.skipBits(1); // qpprime_y_zero_transform_bypass_flag
        if (expGolombDecoder.readBoolean()) { // seq_scaling_matrix_present_flag
          scalingListCount = (chromaFormatIdc !== 3) ? 8 : 12;
          for (i = 0; i < scalingListCount; i++) {
            if (expGolombDecoder.readBoolean()) { // seq_scaling_list_present_flag[ i ]
              if (i < 6) {
                this.skipScalingList(16, expGolombDecoder);
              } else {
                this.skipScalingList(64, expGolombDecoder);
              }
            }
          }
        }
      }

      expGolombDecoder.skipUnsignedExpGolomb(); // log2_max_frame_num_minus4
      picOrderCntType = expGolombDecoder.readUnsignedExpGolomb();

      if (picOrderCntType === 0) {
        expGolombDecoder.readUnsignedExpGolomb(); // log2_max_pic_order_cnt_lsb_minus4
      } else if (picOrderCntType === 1) {
        expGolombDecoder.skipBits(1); // delta_pic_order_always_zero_flag
        expGolombDecoder.skipExpGolomb(); // offset_for_non_ref_pic
        expGolombDecoder.skipExpGolomb(); // offset_for_top_to_bottom_field
        numRefFramesInPicOrderCntCycle = expGolombDecoder.readUnsignedExpGolomb();
        for (i = 0; i < numRefFramesInPicOrderCntCycle; i++) {
          expGolombDecoder.skipExpGolomb(); // offset_for_ref_frame[ i ]
        }
      }

      expGolombDecoder.skipUnsignedExpGolomb(); // max_num_ref_frames
      expGolombDecoder.skipBits(1); // gaps_in_frame_num_value_allowed_flag

      picWidthInMbsMinus1 = expGolombDecoder.readUnsignedExpGolomb();
      picHeightInMapUnitsMinus1 = expGolombDecoder.readUnsignedExpGolomb();

      frameMbsOnlyFlag = expGolombDecoder.readBits(1);
      if (frameMbsOnlyFlag === 0) {
        expGolombDecoder.skipBits(1); // mb_adaptive_frame_field_flag
      }

      expGolombDecoder.skipBits(1); // direct_8x8_inference_flag
      if (expGolombDecoder.readBoolean()) { // frame_cropping_flag
        frameCropLeftOffset = expGolombDecoder.readUnsignedExpGolomb();
        frameCropRightOffset = expGolombDecoder.readUnsignedExpGolomb();
        frameCropTopOffset = expGolombDecoder.readUnsignedExpGolomb();
        frameCropBottomOffset = expGolombDecoder.readUnsignedExpGolomb();
      }
      if (expGolombDecoder.readBoolean()) {
        // vui_parameters_present_flag
        if (expGolombDecoder.readBoolean()) {
          // aspect_ratio_info_present_flag
          aspectRatioIdc = expGolombDecoder.readUnsignedByte();
          switch (aspectRatioIdc) {
            case 1: sarRatio = [1, 1]; break;
            case 2: sarRatio = [12, 11]; break;
            case 3: sarRatio = [10, 11]; break;
            case 4: sarRatio = [16, 11]; break;
            case 5: sarRatio = [40, 33]; break;
            case 6: sarRatio = [24, 11]; break;
            case 7: sarRatio = [20, 11]; break;
            case 8: sarRatio = [32, 11]; break;
            case 9: sarRatio = [80, 33]; break;
            case 10: sarRatio = [18, 11]; break;
            case 11: sarRatio = [15, 11]; break;
            case 12: sarRatio = [64, 33]; break;
            case 13: sarRatio = [160, 99]; break;
            case 14: sarRatio = [4, 3]; break;
            case 15: sarRatio = [3, 2]; break;
            case 16: sarRatio = [2, 1]; break;
            case 255: {
              sarRatio = [expGolombDecoder.readUnsignedByte() << 8 |
                          expGolombDecoder.readUnsignedByte(),
                          expGolombDecoder.readUnsignedByte() << 8 |
                          expGolombDecoder.readUnsignedByte() ];
              break;
            }
          }
          if (sarRatio) {
            sarScale = sarRatio[0] / sarRatio[1];
          }
        }
      }
      return {
        profileIdc: profileIdc,
        levelIdc: levelIdc,
        profileCompatibility: profileCompatibility,
        width: Math.ceil((((picWidthInMbsMinus1 + 1) * 16) - frameCropLeftOffset * 2 - frameCropRightOffset * 2) * sarScale),
        height: ((2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1) * 16) - (frameCropTopOffset * 2) - (frameCropBottomOffset * 2)
      };
    }
  }
}
