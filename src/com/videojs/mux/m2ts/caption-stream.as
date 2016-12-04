package com.videojs.mux.m2ts {

  import com.videojs.mux.utils.Stream;

  // -----------------
  // Link To Transport
  // -----------------

  // Supplemental enhancement information (SEI) NAL units have a
  // payload type field to indicate how they are to be
  // interpreted. CEAS-708 caption content is always transmitted with
  // payload type 0x04.
  var USER_DATA_REGISTERED_ITU_T_T35:int = 4;
  var RBSP_TRAILING_BITS:int = 128;

  /**
    * Parse a supplemental enhancement information (SEI) NAL unit.
    * Stops parsing once a message of type ITU T T35 has been found.
    *
    * @param bytes {Uint8Array} the bytes of a SEI NAL unit
    * @return {object} the parsed SEI payload
    * @see Rec. ITU-T H.264, 7.3.2.3.1
    */
  // TODO Uint8Array
  function parseSei(bytes:ByteArray):Object {
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
  function parseUserData(sei:Object):Array {
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
  function parseCaptionPackets(pts:int, userData:Array):Array {
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
  };

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
      sei = parseSei(event.escapedRBSP);

      // ignore everything but user_data_registered_itu_t_t35
      if (sei.payloadType !== USER_DATA_REGISTERED_ITU_T_T35) {
        return;
      }

      // parse out the user data payload
      userData = parseUserData(sei);

      // ignore unrecognized userData
      if (!userData) {
        return;
      }

      // parse out CC data packets and save them for later
      captionPackets_ = captionPackets_.concat(parseCaptionPackets(event.pts, userData));
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

  // ----------------------
  // Session to Application
  // ----------------------

  var BASIC_CHARACTER_TRANSLATION:Object = {
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

  // TODO int?
  function getCharFromCode(code:int):String {
    if (code === null) {
      return '';
    }
    code = BASIC_CHARACTER_TRANSLATION[code] || code;
    // TODO String.fromCharCode
    return String.fromCharCode(code);
  }

  // Constants for the byte codes recognized by Cea608Stream. This
  // list is not exhaustive. For a more comprehensive listing and
  // semantics see
  // http://www.gpo.gov/fdsys/pkg/CFR-2010-title47-vol1/pdf/CFR-2010-title47-vol1-sec15-119.pdf
  var PADDING:int                    = 0x0000,
  // Pop-on Mode
  var RESUME_CAPTION_LOADING:int     = 0x1420,
  var END_OF_CAPTION:int             = 0x142f,
  // Roll-up Mode
  var ROLL_UP_2_ROWS:int             = 0x1425,
  var ROLL_UP_3_ROWS:int             = 0x1426,
  var ROLL_UP_4_ROWS:int             = 0x1427,
  var CARRIAGE_RETURN:int            = 0x142d,
  // Erasure
  var BACKSPACE:int                  = 0x1421,
  var ERASE_DISPLAYED_MEMORY:int     = 0x142c,
  var ERASE_NON_DISPLAYED_MEMORY:int = 0x142e;

  // the index of the last row in a CEA-608 display buffer
  var BOTTOM_ROW:int = 14;
  // CEA-608 captions are rendered onto a 34x15 matrix of character
  // cells. The "bottom" row is the last element in the outer array.
  function createDisplayBuffer():Array {
    var result:Array = [];
    var i:int = BOTTOM_ROW + 1;
    while (i--) {
      result.push('');
    }
    return result;
  }

  public class Cea608Stream extends Stream {
    private var mode_:String = 'popOn';
    // When in roll-up mode, the index of the last row that will
    // actually display captions. If a caption is shifted to a row
    // with a lower index than this, it is cleared from the display
    // buffer
    private var topRow_:int = 0;
    private var startPts_:int = 0;
    private var displayed_:Array = createDisplayBuffer();
    private var nonDisplayed_:Array = createDisplayBuffer();
    // TODO Byte
    private var lastControlCode_:Byte;

    public function Cea608Stream() {
      this.init();
    }

    public function push(packet:Object):void {
      // Ignore other channels
      if (packet.type !== 0) {
        return;
      }
      // TODO String?
      var data:String;
      var swap:Array:
      // TODO Char
      var char0:Char;
      var char1:Char;

      // remove the parity bits
      data = packet.ccData & 0x7f7f;

      // ignore duplicate control codes
      if (data === lastControlCode_) {
        lastControlCode_ = null;
        return;
      }

      // Store control codes
      if ((data & 0xf000) === 0x1000) {
        lastControlCode_ = data;
      } else {
        lastControlCode_ = null;
      }

      switch (data) {
      case PADDING:
        break;
      case RESUME_CAPTION_LOADING:
        mode_ = 'popOn';
        break;
      case END_OF_CAPTION:
        // if a caption was being displayed, it's gone now
        this.flushDisplayed(packet.pts);

        // flip memory
        swap = displayed_;
        displayed_ = nonDisplayed_;
        nonDisplayed_ = swap;

        // start measuring the time to display the caption
        startPts_ = packet.pts;
        break;

      case ROLL_UP_2_ROWS:
        topRow_ = BOTTOM_ROW - 1;
        mode_ = 'rollUp';
        break;
      case ROLL_UP_3_ROWS:
        topRow_ = BOTTOM_ROW - 2;
        mode_ = 'rollUp';
        break;
      case ROLL_UP_4_ROWS:
        topRow_ = BOTTOM_ROW - 3;
        mode_ = 'rollUp';
        break;
      case CARRIAGE_RETURN:
        this.flushDisplayed(packet.pts);
        this.shiftRowsUp_();
        startPts_ = packet.pts;
        break;

      case BACKSPACE:
        if (mode_ === 'popOn') {
          nonDisplayed_[BOTTOM_ROW] = nonDisplayed_[BOTTOM_ROW].slice(0, -1);
        } else {
          displayed_[BOTTOM_ROW] = displayed_[BOTTOM_ROW].slice(0, -1);
        }
        break;
      case ERASE_DISPLAYED_MEMORY:
        this.flushDisplayed(packet.pts);
        displayed_ = createDisplayBuffer();
        break;
      case ERASE_NON_DISPLAYED_MEMORY:
        nonDisplayed_ = createDisplayBuffer();
        break;
      default:
        char0 = data >>> 8;
        char1 = data & 0xff;

        // Look for a Channel 1 Preamble Address Code
        if (char0 >= 0x10 && char0 <= 0x17 &&
            char1 >= 0x40 && char1 <= 0x7F &&
            (char0 !== 0x10 || char1 < 0x60)) {
          // Follow Safari's lead and replace the PAC with a space
          char0 = 0x20;
          // we only want one space so make the second character null
          // which will get become '' in getCharFromCode
          char1 = null;
        }

        // Look for special character sets
        if ((char0 === 0x11 || char0 === 0x19) &&
            (char1 >= 0x30 && char1 <= 0x3F)) {
          // Put in eigth note and space
          char0 = 0x266A;
          char1 = '';
        }

        // ignore unsupported control codes
        if ((char0 & 0xf0) === 0x10) {
          return;
        }

        // character handling is dependent on the current mode
        this[mode_](packet.pts, char0, char1);
        break;
      }
    }

    // Trigger a cue point that captures the current state of the
    // display buffer
    public function flushDisplayed(pts:int):void {
      var content:Array = displayed_
        // remove spaces from the start and end of the string
        .map(function(row) {
          return row.trim();
        })
        // remove empty rows
        .filter(function(row) {
          return row.length;
        })
        // combine all text rows to display in one cue
        .join('\n');

      if (content.length) {
        this.trigger('data', {
          startPts: startPts_,
          endPts: pts,
          text: content
        });
      }
    }

    // Mode Implementations
    // TODO Byte?
    public function popOn(pts:int, char0:Byte, char1:Byte):void {
      var baseRow:String = this.nonDisplayed_[BOTTOM_ROW];

      // buffer characters
      baseRow += getCharFromCode(char0);
      baseRow += getCharFromCode(char1);
      nonDisplayed_[BOTTOM_ROW] = baseRow;
    }

    // TODO Byte?
    public function rollUp(pts:int, char0:Byte, char1:Byte):void {
      var baseRow:String = this.displayed_[BOTTOM_ROW];

      if (baseRow === '') {
        // we're starting to buffer new display input, so flush out the
        // current display
        this.flushDisplayed(pts);

        startPts_ = pts;
      }

      baseRow += getCharFromCode(char0);
      baseRow += getCharFromCode(char1);

      displayed_[BOTTOM_ROW] = baseRow;
    }

    public function shiftRowsUp_():void {
      var i:int;
      // clear out inactive rows
      for (i = 0; i < this.topRow_; i++) {
        displayed_[i] = '';
      }
      // shift displayed rows up
      for (i = topRow_; i < BOTTOM_ROW; i++) {
        displayed_[i] = displayed_[i + 1];
      }
      // clear out the bottom row
      displayed_[BOTTOM_ROW] = '';
    }
  }
}
