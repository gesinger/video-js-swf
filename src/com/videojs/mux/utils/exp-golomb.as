package com.videojs.mux.utils {

  import flash.utils.ByteArray;

  public class ExpGolomb{

    private var _workingData:ByteArray;
    // the number of bytes left to examine in workingData
    private var _workingBytesAvailable:int;
    // the current word being examined
    private var _workingWord:int = 0;
    // the number of bits left to examine in the current word
    private var _workingBitsAvailable:int = 0;

    public function ExpGolomb(workingData:ByteArray){
      _workingData = workingData;
      _workingBytesAvailable = workingData.length;

      this.loadWord();
    }

    public function length():int {
      return (8 * _workingBytesAvailable);
    }

    public function bitsAvailable():int {
      return (8 * _workingBytesAvailable) + _workingBitsAvailable;
    }

    public function loadWord():void {
      var position:int = _workingData.byteLength - _workingBytesAvailable;
      var workingBytes:ByteArray = new ByteArray(4);
      var availableBytes:int = Math.min(4, _workingBytesAvailable);

      if (availableBytes === 0) {
        throw new Error('no bytes available');
      }

      workingBytes.set(_workingData.subarray(position, position + availableBytes));
      // TODO DataView
      workingWord = new DataView(workingBytes.buffer).getUint32(0);

      // track the amount of workingData that has been processed
      _workingBitsAvailable = availableBytes * 8;
      _workingBytesAvailable -= availableBytes;
    }

    public function skipBits(count:int):void {
      var skipBytes:int;
      if (_workingBitsAvailable > count) {
        _workingWord          <<= count;
        _workingBitsAvailable -= count;
      } else {
        count -= workingBitsAvailable;
        skipBytes = Math.floor(count / 8);

        count -= (skipBytes * 8);
        _workingBytesAvailable -= skipBytes;

        this.loadWord();

        _workingWord <<= count;
        _workingBitsAvailable -= count;
      }
    }

    public function readBits(size:int):uint {
      var bits:int = Math.min(_workingBitsAvailable, size);
      var valu = _workingWord >>> (32 - bits);
      // if size > 31, handle error
      _workingBitsAvailable -= bits;
      if (_workingBitsAvailable > 0) {
        _workingWord <<= bits;
      } else if (_workingBytesAvailable > 0) {
        this.loadWord();
      }

      bits = size - bits;
      if (bits > 0) {
        return valu << bits | this.readBits(bits);
      }
      return valu;
    }

    public function skipLeadingZeros():int {
      var leadingZeroCount:int;
      for (leadingZeroCount = 0; leadingZeroCount < _workingBitsAvailable; ++leadingZeroCount) {
        if ((_workingWord & (0x80000000 >>> leadingZeroCount)) !== 0) {
          // the first bit of working word is 1
          _workingWord <<= leadingZeroCount;
          _workingBitsAvailable -= leadingZeroCount;
          return leadingZeroCount;
        }
      }

      // we exhausted workingWord and still have not found a 1
      this.loadWord();
      return leadingZeroCount + this.skipLeadingZeros();
    };

    public function skipUnsignedExpGolomb():void {
      this.skipBits(1 + this.skipLeadingZeros());
    };

    public function skipExpGolomb():void {
      this.skipBits(1 + this.skipLeadingZeros());
    };

    public function readUnsignedExpGolomb():int {
      var clz:int = this.skipLeadingZeros();
      return this.readBits(clz + 1) - 1;
    };

    public function readExpGolomb():int {
      var valu = this.readUnsignedExpGolomb();
      if (0x01 & valu) {
        // the number is odd if the low order bit is set
        return (1 + valu) >>> 1; // add 1 to make it even, and divide by 2
      }
      return -1 * (valu >>> 1); // divide by two then make it negative
    };

    // Some convenience functions
    public function readBoolean():Boolean {
      return this.readBits(1) === 1;
    };

    public function readUnsignedByte():int {
      return this.readBits(8);
    };
  }
}
