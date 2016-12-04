package com.videojs.mux.flv {
  public class Utils {
    /**
     * Store information about the start and end of the tracka and the
     * duration for each frame/sample we process in order to calculate
     * the baseMediaDecodeTime
     */
    // TODO typeof and undefined
    public static function collectTimelineInfo(track:Object, data:Object):void {
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

    public static function metaDataTag(track:Object, pts:int):FlvTag {
      var tag:FlvTag = new FlvTag(FlvTag.METADATA_TAG);

      tag.dts = pts;
      tag.pts = pts;

      tag.writeMetaDataDouble('videocodecid', 7);
      tag.writeMetaDataDouble('width', track.width);
      tag.writeMetaDataDouble('height', track.height);

      return tag;
    }

    public static function extraDataTag(track:Object, pts:int):FlvTag {
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
  }
}
