package com.videojs.mux.flv {

  import com.videojs.mux.utils.Stream;

  /**
   * The final stage of the transmuxer that emits the flv tags
   * for audio, video, and metadata. Also tranlates in time and
   * outputs caption data and id3 cues.
   */
  public class CoalesceStream extends Stream {
    // Number of Tracks per output segment
    // If greater than 1, we combine multiple
    // tracks into a single segment
    private var numberOfTracks:int = 0;
    private var metadataStream:Stream
    private var videoTags:Array = [];
    private var audioTags:Array = [];
    private var videoTrack:Object;
    private var audioTrack:Object;
    private var pendingCaptions:Array = [];
    private var pendingMetadata:Array = [];
    private var pendingTracks:int = 0;
    private var processedTracks:int = 0;

    public function CoalesceStream(options:Object) {
      this.init();
      metadataStream = options.metadataStream;
    }

    // Take output from multiple
    override public function push(output:Object):void {
      // buffer incoming captions until the associated video segment
      // finishes
      if (output.text) {
        return pendingCaptions.push(output);
      }
      // buffer incoming id3 tags until the final flush
      if (output.frames) {
        return pendingMetadata.push(output);
      }

      if (output.track.type === 'video') {
        videoTrack = output.track;
        videoTags = output.tags;
        pendingTracks++;
      }
      if (output.track.type === 'audio') {
        audioTrack = output.track;
        audioTags = output.tags;
        pendingTracks++;
      }
    }

    override public function flush(flushSource:Stream):void {
      var id3:Object;
      var caption:Object;
      var i:int;
      var timelineStartPts:int;
      var event:Object = {
        tags: {},
        captions: [],
        metadata: []
      };

      if (pendingTracks < numberOfTracks) {
        if (flushSource !== 'VideoSegmentStream' &&
            flushSource !== 'AudioSegmentStream') {
          // Return because we haven't received a flush from a data-generating
          // portion of the segment (meaning that we have only recieved meta-data
          // or captions.)
          return;
        } else if (pendingTracks === 0) {
          // In the case where we receive a flush without any data having been
          // received we consider it an emitted track for the purposes of coalescing
          // `done` events.
          // We do this for the case where there is an audio and video track in the
          // segment but no audio data. (seen in several playlists with alternate
          // audio tracks and no audio present in the main TS segments.)
          processedTracks++;

          if (processedTracks < numberOfTracks) {
            return;
          }
        }
      }

      processedTracks += pendingTracks;
      pendingTracks = 0;

      if (processedTracks < numberOfTracks) {
        return;
      }

      if (videoTrack) {
        timelineStartPts = videoTrack.timelineStartInfo.pts;
      } else if (audioTrack) {
        timelineStartPts = audioTrack.timelineStartInfo.pts;
      }

      event.tags.videoTags = videoTags;
      event.tags.audioTags = audioTags;

      // Translate caption PTS times into second offsets into the
      // video timeline for the segment
      for (i = 0; i < pendingCaptions.length; i++) {
        caption = pendingCaptions[i];
        caption.startTime = caption.startPts - timelineStartPts;
        caption.startTime /= 90e3;
        caption.endTime = caption.endPts - timelineStartPts;
        caption.endTime /= 90e3;
        event.captions.push(caption);
      }

      // Translate ID3 frame PTS times into second offsets into the
      // video timeline for the segment
      for (i = 0; i < pendingMetadata.length; i++) {
        id3 = pendingMetadata[i];
        id3.cueTime = id3.pts - timelineStartPts;
        id3.cueTime /= 90e3;
        event.metadata.push(id3);
      }
      // We add this to every single emitted segment even though we only need
      // it for the first
      event.metadata.dispatchType = metadataStream.dispatchType;

      // Reset stream state
      videoTrack = null;
      audioTrack = null;
      videoTags = [];
      audioTags = [];
      pendingCaptions.length = 0;
      pendingMetadata.length = 0;
      pendingTracks = 0;
      processedTracks = 0;

      // Emit the final segment
      this.trigger('data', event);

      this.trigger('done');
    }
  }
}
