package com.videojs.mux.m2ts {

  import com.videojs.mux.utils.Stream;
  import com.videojs.mux.m2ts.Utils;

  // ----------------------
  // Session to Application
  // ----------------------

  public class Cea608Stream extends Stream {
    private var mode_:String = 'popOn';
    // When in roll-up mode, the index of the last row that will
    // actually display captions. If a caption is shifted to a row
    // with a lower index than this, it is cleared from the display
    // buffer
    private var topRow_:int = 0;
    private var startPts_:int = 0;
    private var displayed_:Array = Utils.createDisplayBuffer();
    private var nonDisplayed_:Array = Utils.createDisplayBuffer();
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
      case Utils.PADDING:
        break;
      case Utils.RESUME_CAPTION_LOADING:
        mode_ = 'popOn';
        break;
      case Utils.END_OF_CAPTION:
        // if a caption was being displayed, it's gone now
        this.flushDisplayed(packet.pts);

        // flip memory
        swap = displayed_;
        displayed_ = nonDisplayed_;
        nonDisplayed_ = swap;

        // start measuring the time to display the caption
        startPts_ = packet.pts;
        break;

      case Utils.ROLL_UP_2_ROWS:
        topRow_ = Utils.BOTTOM_ROW - 1;
        mode_ = 'rollUp';
        break;
      case Utils.ROLL_UP_3_ROWS:
        topRow_ = Utils.BOTTOM_ROW - 2;
        mode_ = 'rollUp';
        break;
      case Utils.ROLL_UP_4_ROWS:
        topRow_ = Utils.BOTTOM_ROW - 3;
        mode_ = 'rollUp';
        break;
      case Utils.CARRIAGE_RETURN:
        this.flushDisplayed(packet.pts);
        this.shiftRowsUp_();
        startPts_ = packet.pts;
        break;

      case Utils.BACKSPACE:
        if (mode_ === 'popOn') {
          nonDisplayed_[Utils.BOTTOM_ROW] = nonDisplayed_[Utils.BOTTOM_ROW].slice(0, -1);
        } else {
          displayed_[Utils.BOTTOM_ROW] = displayed_[Utils.BOTTOM_ROW].slice(0, -1);
        }
        break;
      case Utils.ERASE_DISPLAYED_MEMORY:
        this.flushDisplayed(packet.pts);
        displayed_ = Utils.createDisplayBuffer();
        break;
      case Utils.ERASE_NON_DISPLAYED_MEMORY:
        nonDisplayed_ = Utils.createDisplayBuffer();
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
      var baseRow:String = this.nonDisplayed_[Utils.BOTTOM_ROW];

      // buffer characters
      baseRow += Utils.getCharFromCode(char0);
      baseRow += Utils.getCharFromCode(char1);
      nonDisplayed_[Utils.BOTTOM_ROW] = baseRow;
    }

    // TODO Byte?
    public function rollUp(pts:int, char0:Byte, char1:Byte):void {
      var baseRow:String = this.displayed_[Utils.BOTTOM_ROW];

      if (baseRow === '') {
        // we're starting to buffer new display input, so flush out the
        // current display
        this.flushDisplayed(pts);

        startPts_ = pts;
      }

      baseRow += Utils.getCharFromCode(char0);
      baseRow += Utils.getCharFromCode(char1);

      displayed_[Utils.BOTTOM_ROW] = baseRow;
    }

    public function shiftRowsUp_():void {
      var i:int;
      // clear out inactive rows
      for (i = 0; i < this.topRow_; i++) {
        displayed_[i] = '';
      }
      // shift displayed rows up
      for (i = topRow_; i < Utils.BOTTOM_ROW; i++) {
        displayed_[i] = displayed_[i + 1];
      }
      // clear out the bottom row
      displayed_[Utils.BOTTOM_ROW] = '';
    }
  }
}
