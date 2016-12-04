package com.videojs.mux.utils {

  public class Stream{
    private var listeners:Object;

    public function Stream() {}

    public function init():void {
      listeners = {};
    }

    /**
     * Add a listener for a specified event type.
     * @param type {string} the event name
     * @param listener {function} the callback to be invoked when an event of
     * the specified type occurs
     */
    public function on(type:String, listener:Function):void {
      if (!listeners[type]) {
        listeners[type] = [];
      }
      listeners[type] = listeners[type].concat(listener);
    }

    /**
     * Remove a listener for a specified event type.
     * @param type {string} the event name
     * @param listener {function} a function previously registered for this
     * type of event through `on`
     */
    public function off(type:String, listener:Function):void {
      var index:int;
      if (!listeners[type]) {
        return false;
      }
      index = listeners[type].indexOf(listener);
      listeners[type] = listeners[type].slice();
      listeners[type].splice(index, 1);
      return index > -1;
    };

    /**
     * Trigger an event of the specified type on this stream. Any additional
     * arguments to this function are passed as parameters to event listeners.
     * @param type {string} the event name
     */
    public function trigger(type, ... arguments):void {
      var callbacks:Object;
      var i:int;
      var length:int;
      var args:Array = new Array():

      callbacks = listeners[type];
      if (!callbacks) {
        return;
      }
      // Slicing the arguments on every invocation of this method
      // can add a significant amount of overhead. Avoid the
      // intermediate object creation for the common case of a
      // single callback argument
      if (arguments.length === 2) {
        length = callbacks.length;
        for (i = 0; i < length; ++i) {
          callbacks[i].call(this, arguments[1]);
        }
      } else {
        args = [];
        i = arguments.length;
        for (i = 1; i < arguments.length; ++i) {
          args.push(arguments[i]);
        }
        length = callbacks.length;
        for (i = 0; i < length; ++i) {
          callbacks[i].apply(this, args);
        }
      }
    }

    /**
     * Destroys the stream and cleans up.
     */
    public function dispose():void {
      listeners = {};
    }

    /**
     * Forwards all `data` events on this stream to the destination stream. The
     * destination stream should provide a method `push` to receive the data
     * events as they arrive.
     * @param destination {stream} the stream that will receive all `data` events
     * @param autoFlush {boolean} if false, we will not call `flush` on the destination
     *                            when the current stream emits a 'done' event
     * @see http://nodejs.org/api/stream.html#stream_readable_pipe_destination_options
     */
    public function pipe(destination:Stream):Stream {
      this.addEventListener('data', function(data:Object) {
        destination.push(data);
      });

      this.addEventListener('done', function(flushSource:Stream) {
        destination.flush(flushSource);
      });

      return destination;
    }

    // Default stream functions that are expected to be overridden to perform
    // actual work. These are provided by the prototype as a sort of no-op
    // implementation so that we don't have to check for their existence in the
    // `pipe` function above.
    public function push(data:Object):void {
      this.trigger('data', data);
    };

    public function flush(flushSource:Stream):void {
      this.trigger('done', flushSource);
    };
  }
}
