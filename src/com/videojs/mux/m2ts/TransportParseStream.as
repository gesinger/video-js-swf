package com.videojs.mux.m2ts {

  import com.videojs.mux.utils.Stream;

  public class TransportParseStream extends Stream {
    private var self:TransportParseStream;
    // TODO int?
    private var pmtPid:int;
    private var packetsWaitingForPmt:Array = [];
    private var programMapTable:Object;

    public static var STREAM_TYPES:Object = {
      h264: 0x1b,
      adts: 0x0f
    };

    /**
     * Accepts an MP2T TransportPacketStream and emits data events with parsed
     * forms of the individual transport stream packets.
     */
    public function TransportParseStream() {
      self = this;
      this.init();
    }

    private function parsePsi(payload:ByteArray, psi:Object):void {
      var offset:int = 0;

      // PSI packets may be split into multiple sections and those
      // sections may be split into multiple packets. If a PSI
      // section starts in this packet, the payload_unit_start_indicator
      // will be true and the first byte of the payload will indicate
      // the offset from the current position to the start of the
      // section.
      if (psi.payloadUnitStartIndicator) {
        offset += payload[offset] + 1;
      }

      if (psi.type === 'pat') {
        this.parsePat(payload.subarray(offset), psi);
      } else {
        this.parsePmt(payload.subarray(offset), psi);
      }
    }

    private function parsePat(payload:ByteArray, pat:Object):void {
      pat.section_number = payload[7]; // eslint-disable-line camelcase
      pat.last_section_number = payload[8]; // eslint-disable-line camelcase

      // skip the PSI header and parse the first PMT entry
      pmtPid = (payload[10] & 0x1F) << 8 | payload[11];
      pat.pmtPid = pmtPid;
    }

    /**
     * Parse out the relevant fields of a Program Map Table (PMT).
     * @param payload {Uint8Array} the PMT-specific portion of an MP2T
     * packet. The first byte in this array should be the table_id
     * field.
     * @param pmt {object} the object that should be decorated with
     * fields parsed from the PMT.
     */
    private function parsePmt(payload:ByteArray, pmt:Object):void {
      var sectionLength:int;
      var tableEnd:int;
      var programInfoLength:int;
      var offset:int;

      // PMTs can be sent ahead of the time when they should actually
      // take effect. We don't believe this should ever be the case
      // for HLS but we'll ignore "forward" PMT declarations if we see
      // them. Future PMT declarations have the current_next_indicator
      // set to zero.
      if (!(payload[5] & 0x01)) {
        return;
      }

      // overwrite any existing program map table
      programMapTable = {};

      // the mapping table ends at the end of the current section
      sectionLength = (payload[1] & 0x0f) << 8 | payload[2];
      tableEnd = 3 + sectionLength - 4;

      // to determine where the table is, we have to figure out how
      // long the program info descriptors are
      programInfoLength = (payload[10] & 0x0f) << 8 | payload[11];

      // advance the offset to the first entry in the mapping table
      offset = 12 + programInfoLength;
      while (offset < tableEnd) {
        // add an entry that maps the elementary_pid to the stream_type
        programMapTable[(payload[offset + 1] & 0x1F) << 8 | payload[offset + 2]] = payload[offset];

        // move to the next table entry
        // skip past the elementary stream descriptors, if present
        offset += ((payload[offset + 3] & 0x0F) << 8 | payload[offset + 4]) + 5;
      }

      // record the map on the packet as well
      pmt.programMapTable = programMapTable;

      // if there are any packets waiting for a PMT to be found, process them now
      while (packetsWaitingForPmt.length) {
        this.processPes_.apply(self, self.packetsWaitingForPmt.shift());
      }
    }

    /**
     * Deliver a new MP2T packet to the stream.
     */
    // TODO ByteArray?
    override public function push(packet:ByteArray):void {
      var result:Object = {};
      var offset:int = 4;

      result.payloadUnitStartIndicator = !!(packet[1] & 0x40);

      // pid is a 13-bit field starting at the last bit of packet[1]
      result.pid = packet[1] & 0x1f;
      result.pid <<= 8;
      result.pid |= packet[2];

      // if an adaption field is present, its length is specified by the
      // fifth byte of the TS packet header. The adaptation field is
      // used to add stuffing to PES packets that don't fill a complete
      // TS packet, and to specify some forms of timing and control data
      // that we do not currently use.
      if (((packet[3] & 0x30) >>> 4) > 0x01) {
        offset += packet[offset] + 1;
      }

      // parse the rest of the packet based on the type
      if (result.pid === 0) {
        result.type = 'pat';
        this.parsePsi(packet.subarray(offset), result);
        this.trigger('data', result);
      } else if (result.pid === this.pmtPid) {
        result.type = 'pmt';
        this.parsePsi(packet.subarray(offset), result);
        this.trigger('data', result);
      // TODO undefined
      } else if (this.programMapTable === undefined) {
        // When we have not seen a PMT yet, defer further processing of
        // PES packets until one has been parsed
        packetsWaitingForPmt.push([packet, offset, result]);
      } else {
        this.processPes_(packet, offset, result);
      }
    }

    private function processPes_(packet:ByteArray, offset:int, result:Object):void {
      result.streamType = this.programMapTable[result.pid];
      result.type = 'pes';
      result.data = packet.subarray(offset);

      this.trigger('data', result);
    };
  }
}
