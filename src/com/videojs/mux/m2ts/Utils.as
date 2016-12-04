package com.videojs.mux.m2ts {

  import flash.utils.ByteArray;

  private static var MP2T_PACKET_LENGTH:int = 188; // bytes

  // Supplemental enhancement information (SEI) NAL units have a
  // payload type field to indicate how they are to be
  // interpreted. CEAS-708 caption content is always transmitted with
  // payload type 0x04.
  public static var USER_DATA_REGISTERED_ITU_T_T35:int = 4;
  public static var RBSP_TRAILING_BITS:int = 128;

  public static var StreamTypes:Object = {
    H264_STREAM_TYPE: 0x1B,
    ADTS_STREAM_TYPE: 0x0F,
    METADATA_STREAM_TYPE: 0x15
  };

  public static var BASIC_CHARACTER_TRANSLATION:Object = {
    0x2a: 0xe1,
    0x5c: 0xe9,
    0x5e: 0xed,
    0x5f: 0xf3,
    0x60: 0xfa,
    0x7b: 0xe7,
    0x7c: 0xf7,
    0x7d: 0xd1,
    0x7e: 0xf1,
    0x7f: 0x2588
  };

  // Constants for the byte codes recognized by Cea608Stream. This
  // list is not exhaustive. For a more comprehensive listing and
  // semantics see
  // http://www.gpo.gov/fdsys/pkg/CFR-2010-title47-vol1/pdf/CFR-2010-title47-vol1-sec15-119.pdf
  public static var PADDING:int                    = 0x0000,
  // Pop-on Mode
  public static var RESUME_CAPTION_LOADING:int     = 0x1420,
  public static var END_OF_CAPTION:int             = 0x142f,
  // Roll-up Mode
  public static var ROLL_UP_2_ROWS:int             = 0x1425,
  public static var ROLL_UP_3_ROWS:int             = 0x1426,
  public static var ROLL_UP_4_ROWS:int             = 0x1427,
  public static var CARRIAGE_RETURN:int            = 0x142d,
  // Erasure
  public static var BACKSPACE:int                  = 0x1421,
  public static var ERASE_DISPLAYED_MEMORY:int     = 0x142c,
  public static var ERASE_NON_DISPLAYED_MEMORY:int = 0x142e;

  // the index of the last row in a CEA-608 display buffer
  public static var BOTTOM_ROW:int = 14;

  public class Utils {
    /**
      * Parse a supplemental enhancement information (SEI) NAL unit.
      * Stops parsing once a message of type ITU T T35 has been found.
      *
      * @param bytes {Uint8Array} the bytes of a SEI NAL unit
      * @return {object} the parsed SEI payload
      * @see Rec. ITU-T H.264, 7.3.2.3.1
      */
    // TODO Uint8Array
    public static function parseSei(bytes:ByteArray):Object {
      var i:int = 0;
      var result:Object = {
        payloadType: -1,
        payloadSize: 0
      };
      var payloadType:int = 0;
      var payloadSize:int = 0;

      // go through the sei_rbsp parsing each each individual sei_message
      while (i < bytes.byteLength) {
        // stop once we have hit the end of the sei_rbsp
        if (bytes[i] === RBSP_TRAILING_BITS) {
          break;
        }

        // Parse payload type
        while (bytes[i] === 0xFF) {
          payloadType += 255;
          i++;
        }
        payloadType += bytes[i++];

        // Parse payload size
        while (bytes[i] === 0xFF) {
          payloadSize += 255;
          i++;
        }
        payloadSize += bytes[i++];

        // this sei_message is a 608/708 caption so save it and break
        // there can only ever be one caption message in a frame's sei
        if (!result.payload && payloadType === USER_DATA_REGISTERED_ITU_T_T35) {
          result.payloadType = payloadType;
          result.payloadSize = payloadSize;
          result.payload = bytes.subarray(i, i + payloadSize);
          break;
        }

        // skip the payload and parse the next message
        i += payloadSize;
        payloadType = 0;
        payloadSize = 0;
      }

      return result;
    }

    // see ANSI/SCTE 128-1 (2013), section 8.1
    // TODO Array or ByteArray?
    public static function parseUserData(sei:Object):Array {
      // itu_t_t35_contry_code must be 181 (United States) for
      // captions
      if (sei.payload[0] !== 181) {
        return null;
      }

      // itu_t_t35_provider_code should be 49 (ATSC) for captions
      if (((sei.payload[1] << 8) | sei.payload[2]) !== 49) {
        return null;
      }

      // the user_identifier should be "GA94" to indicate ATSC1 data
      // TODO yeah...this'll work...
      if (String.fromCharCode(sei.payload[3],
                              sei.payload[4],
                              sei.payload[5],
                              sei.payload[6]) !== 'GA94') {
        return null;
      }

      // finally, user_data_type_code should be 0x03 for caption data
      if (sei.payload[7] !== 0x03) {
        return null;
      }

      // return the user_data_type_structure and strip the trailing
      // marker bits
      return sei.payload.subarray(8, sei.payload.length - 1);
    }

    // see CEA-708-D, section 4.4
    // TODO Array or ByteArray?
    public static function parseCaptionPackets(pts:int, userData:Array):Array {
      var results:Array = [];
      var i:int;
      var count:int;
      var offset:int;
      var data:Object;

      // if this is just filler, return immediately
      if (!(userData[0] & 0x40)) {
        return results;
      }

      // parse out the cc_data_1 and cc_data_2 fields
      count = userData[0] & 0x1f;
      for (i = 0; i < count; i++) {
        offset = i * 3;
        data = {
          type: userData[offset + 2] & 0x03,
          pts: pts
        };

        // capture cc data when cc_valid is 1
        if (userData[offset + 2] & 0x04) {
          data.ccData = (userData[offset + 3] << 8) | userData[offset + 4];
          results.push(data);
        }
      }
      return results;
    }

    // TODO int?
    public static function getCharFromCode(code:int):String {
      if (code === null) {
        return '';
      }
      code = BASIC_CHARACTER_TRANSLATION[code] || code;
      // TODO String.fromCharCode
      return String.fromCharCode(code);
    }

    // CEA-608 captions are rendered onto a 34x15 matrix of character
    // cells. The "bottom" row is the last element in the outer array.
    public function createDisplayBuffer():Array {
      var result:Array = [];
      var i:int = BOTTOM_ROW + 1;
      while (i--) {
        result.push('');
      }
      return result;
    }
  }
}
