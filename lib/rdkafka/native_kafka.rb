# frozen_string_literal: true

module Rdkafka
  # @private
  # A wrapper around a native kafka that polls and cleanly exits
  class NativeKafka
    def initialize(inner, run_polling_thread:)
      @inner = inner
      # Lock around external access
      @access_mutex = Mutex.new
      # Lock around internal polling
      @poll_mutex = Mutex.new

      if run_polling_thread
        # Start thread to poll client for delivery callbacks,
        # not used in consumer.
        @polling_thread = Thread.new do
          loop do
            @poll_mutex.synchronize do
              Rdkafka::Bindings.rd_kafka_poll(inner, 100)
            end
            # Exit thread if closing and the poll queue is empty
            if Thread.current[:closing] && Rdkafka::Bindings.rd_kafka_outq_len(inner) == 0
              break
            end
          end
        end
        @polling_thread.abort_on_exception = true
        @polling_thread[:closing] = false
      end

      @closing = false
    end

    def with_inner
      return if @inner.nil?
      @access_mutex.synchronize do
        yield @inner
      end
    end

    def finalizer
      ->(_) { close }
    end

    def closed?
      @closing || @inner.nil?
    end

    def close(object_id=nil)
      return if closed?

      # Indicate to the outside world that we are closing
      @closing = true

      if @polling_thread
        # Indicate to polling thread that we're closing
        @polling_thread[:closing] = true
      end

      # Destroy the client after locking both mutexes
      @access_mutex.lock
      @poll_mutex.lock

      Rdkafka::Bindings.rd_kafka_destroy(@inner)
      @inner = nil

      if @polling_thread
        # Wait for the polling thread to finish up,
        # this can be aborted in practice if this
        # code runs from a finalizer.
        @polling_thread.join
      end
    end
  end
end
