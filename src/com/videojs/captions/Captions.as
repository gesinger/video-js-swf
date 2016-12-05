package com.videojs.captions {

  import flash.utils.ByteArray;

  import org.mangui.hls.utils.Log;

  import mx.utils.StringUtil;

  public class Captions {
    // Constants for the byte codes recognized by Cea608Stream. This
    // list is not exhaustive. For a more comprehensive listing and
    // semantics see
    // http://www.gpo.gov/fdsys/pkg/CFR-2010-title47-vol1/pdf/CFR-2010-title47-vol1-sec15-119.pdf
    public static var PADDING:int                    = 0x0000;
    // Pop-on Mode
    public static var RESUME_CAPTION_LOADING:int     = 0x1420;
    public static var END_OF_CAPTION:int             = 0x142f;
    // Roll-up Mode
    public static var ROLL_UP_2_ROWS:int             = 0x1425;
    public static var ROLL_UP_3_ROWS:int             = 0x1426;
    public static var ROLL_UP_4_ROWS:int             = 0x1427;
    public static var CARRIAGE_RETURN:int            = 0x142d;
    // Erasure
    public static var BACKSPACE:int                  = 0x1421;
    public static var ERASE_DISPLAYED_MEMORY:int     = 0x142c;
    public static var ERASE_NON_DISPLAYED_MEMORY:int = 0x142e;

    // the index of the last row in a CEA-608 display buffer
    public static var BOTTOM_ROW:int = 14;

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
    private var lastControlCode_:int;

    // CEA-608 captions are rendered onto a 34x15 matrix of character
    // cells. The "bottom" row is the last element in the outer array.
    public static function createDisplayBuffer():Array {
      var result:Array = [];
      var i:uint = BOTTOM_ROW + 1;
      while (i--) {
        result.push('');
      }
      return result;
    }

    public static function getCharFromCode(code:int):String {
      if (code === 0) {
        return '';
      }
      code = BASIC_CHARACTER_TRANSLATION[code] || code;
      return String.fromCharCode(code);
    }

    public function Captions(type:String, userData:ByteArray):void {
      // parse out CC data packets and save them for later
      var captionPackets:Array = parseCaptionPackets(userData);

      for each (var captionPacket:Object in captionPackets) {
        pushCaption(captionPacket);
      }
    }

    public function get displayed():Array {
      return displayed_;
    }

    private function pushCaption(packet:Object):void {
      // Ignore other channels
      if (packet.type !== 0) {
        return;
      }

      var swap:Array;
      var data: int;
      var char0:int;
      var char1:int;

      // remove the parity bits
      data = packet.ccData & 0x7f7f;

      // ignore duplicate control codes
      if (data === lastControlCode_) {
        lastControlCode_ = 0;
        return;
      }

      // Store control codes
      if ((data & 0xf000) === 0x1000) {
        lastControlCode_ = data;
      } else {
        lastControlCode_ = 0;
      }

      switch (data) {
      case PADDING:
        break;
      case RESUME_CAPTION_LOADING:
        mode_ = 'popOn';
        break;
      case END_OF_CAPTION:
        // if a caption was being displayed, it's gone now
        flushDisplayed();

        // flip memory
        swap = displayed_;
        displayed_ = nonDisplayed_;
        nonDisplayed_ = swap;

        Log.info('SWAP: ' + displayed_.join('|'));

        // TODO
        // start measuring the time to display the caption
        // startPts_ = packet.pts;
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
        flushDisplayed();
        shiftRowsUp_();
        // TODO
        // startPts_ = packet.pts;
        break;

      case BACKSPACE:
        if (mode_ === 'popOn') {
          nonDisplayed_[BOTTOM_ROW] = nonDisplayed_[BOTTOM_ROW].slice(0, -1);
        } else {
          displayed_[BOTTOM_ROW] = displayed_[BOTTOM_ROW].slice(0, -1);
        }
        break;
      case ERASE_DISPLAYED_MEMORY:
        flushDisplayed();
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
          char1 = 0;
        }

        // Look for special character sets
        if ((char0 === 0x11 || char0 === 0x19) &&
            (char1 >= 0x30 && char1 <= 0x3F)) {
          // Put in eigth note and space
          char0 = 0x266A;
          char1 = ('').charCodeAt(0);
        }

        // ignore unsupported control codes
        if ((char0 & 0xf0) === 0x10) {
          return;
        }

        // character handling is dependent on the current mode
        this[mode_](char0, char1);
        break;
      }
    }

    // Trigger a cue point that captures the current state of the
    // display buffer
    // TODO pts
    private function flushDisplayed():void {
      Log.info('FLUSHING');
      Log.info(displayed_.join('|'));

      var content:String = displayed_
        // remove spaces from the start and end of the string
        .map(function(row:String):String {
          return StringUtil.trim(row);
        })
        // remove empty rows
        .filter(function(row:String):Boolean {
          return row.length > 0;
        })
        // combine all text rows to display in one cue
        .join('\n');

      if (content.length) {
        Log.info('CONTENT: ' + content);
      }
    }

    // Mode Implementations

    // TODO pts
    public function popOn(char0:int, char1:int):void {
      var baseRow:String = nonDisplayed_[BOTTOM_ROW];

      // buffer characters
      baseRow += getCharFromCode(char0);
      baseRow += getCharFromCode(char1);
      nonDisplayed_[BOTTOM_ROW] = baseRow;
      Log.info('POP ON: ' + nonDisplayed_[BOTTOM_ROW]);
    }

    // TODO pts
    public function rollUp(char0:int, char1:int):void {
      var baseRow:String = displayed_[BOTTOM_ROW];

      if (baseRow === '') {
        // we're starting to buffer new display input, so flush out the
        // current display
        flushDisplayed();

        // startPts_ = pts;
      }

      baseRow += getCharFromCode(char0);
      baseRow += getCharFromCode(char1);

      displayed_[BOTTOM_ROW] = baseRow;
      Log.info('ROLL UP: ' + displayed_[BOTTOM_ROW]);
    }

    public function shiftRowsUp_():void {
      var i:uint;
      // clear out inactive rows
      for (i = 0; i < topRow_; i++) {
        displayed_[i] = '';
      }
      // shift displayed rows up
      for (i = topRow_; i < BOTTOM_ROW; i++) {
        displayed_[i] = displayed_[i + 1];
      }
      // clear out the bottom row
      displayed_[BOTTOM_ROW] = '';
    }

    // see CEA-708-D, section 4.4
    private function parseCaptionPackets(userData: ByteArray):Array {
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
      Log.info("Count: " + count);
      for (i = 0; i < count; i++) {
        offset = i * 3;
        data = {
          type: userData[offset + 2] & 0x03
        };

        // capture cc data when cc_valid is 1
        if (userData[offset + 2] & 0x04) {
          data.ccData = (userData[offset + 3] << 8) | userData[offset + 4];
          Log.info("Captions: " +  data.type + ' ' + data.ccData);
          results.push(data);
        }
      }
      return results;
    }

    // see ANSI/SCTE 128-1 (2013), section 8.1
    private function parseUserData(sei: ByteArray):ByteArray {
      // itu_t_t35_contry_code must be 181 (United States) for
      // captions
      if (sei[0] !== 181) {
        return null;
      }

      // itu_t_t35_provider_code should be 49 (ATSC) for captions
      if (((sei[1] << 8) | sei[2]) !== 49) {
        return null;
      }

      // the user_identifier should be "GA94" to indicate ATSC1 data
      // TODO yeah...this'll work...
      if (String.fromCharCode(sei[3],
                              sei[4],
                              sei[5],
                              sei[6]) !== 'GA94') {
        return null;
      }

      // finally, user_data_type_code should be 0x03 for caption data
      if (sei[7] !== 0x03) {
        return null;
      }

      // return the user_data_type_structure and strip the trailing
      // marker bits
      var subarray:ByteArray = new ByteArray();
      subarray.position = 8;
      sei.readBytes(subarray, 0, sei.length - 1);

      return subarray;
    }
  }
}
