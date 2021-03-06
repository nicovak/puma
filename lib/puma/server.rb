# frozen_string_literal: true

require 'stringio'

require 'puma/thread_pool'
require 'puma/const'
require 'puma/events'
require 'puma/null_io'
require 'puma/reactor'
require 'puma/client'
require 'puma/binder'
require 'puma/util'
require 'puma/io_buffer'

require 'socket'
require 'forwardable'

module Puma

  # The HTTP Server itself. Serves out a single Rack app.
  #
  # This class is used by the `Puma::Single` and `Puma::Cluster` classes
  # to generate one or more `Puma::Server` instances capable of handling requests.
  # Each Puma process will contain one `Puma::Server` instance.
  #
  # The `Puma::Server` instance pulls requests from the socket, adds them to a
  # `Puma::Reactor` where they get eventually passed to a `Puma::ThreadPool`.
  #
  # Each `Puma::Server` will have one reactor and one thread pool.
  class Server

    include Puma::Const
    extend Forwardable

    attr_reader :thread
    attr_reader :events
    attr_reader :min_threads, :max_threads  # for #stats
    attr_reader :requests_count             # @version 5.0.0

    # @todo the following may be deprecated in the future
    attr_reader :auto_trim_time, :early_hints, :first_data_timeout,
      :leak_stack_on_error,
      :persistent_timeout, :reaping_time

    # @deprecated v6.0.0
    attr_writer :auto_trim_time, :early_hints, :first_data_timeout,
      :leak_stack_on_error, :min_threads, :max_threads,
      :persistent_timeout, :reaping_time

    attr_accessor :app
    attr_accessor :binder

    def_delegators :@binder, :add_tcp_listener, :add_ssl_listener,
      :add_unix_listener, :connected_ports

    ThreadLocalKey = :puma_server

    # Create a server for the rack app +app+.
    #
    # +events+ is an object which will be called when certain error events occur
    # to be handled. See Puma::Events for the list of current methods to implement.
    #
    # Server#run returns a thread that you can join on to wait for the server
    # to do its work.
    #
    # @note Several instance variables exist so they are available for testing,
    #   and have default values set via +fetch+.  Normally the values are set via
    #   `::Puma::Configuration.puma_default_options`.
    #
    def initialize(app, events=Events.stdio, options={})
      @app = app
      @events = events

      @check, @notify = nil
      @status = :stop

      @auto_trim_time = 30
      @reaping_time = 1

      @thread = nil
      @thread_pool = nil

      @options = options

      @early_hints        = options.fetch :early_hints, nil
      @first_data_timeout = options.fetch :first_data_timeout, FIRST_DATA_TIMEOUT
      @min_threads        = options.fetch :min_threads, 0
      @max_threads        = options.fetch :max_threads , (Puma.mri? ? 5 : 16)
      @persistent_timeout = options.fetch :persistent_timeout, PERSISTENT_TIMEOUT
      @queue_requests     = options.fetch :queue_requests, true

      temp = !!(@options[:environment] =~ /\A(development|test)\z/)
      @leak_stack_on_error = @options[:environment] ? temp : true

      @binder = Binder.new(events)

      ENV['RACK_ENV'] ||= "development"

      @mode = :http

      @precheck_closing = true

      @requests_count = 0
    end

    def inherit_binder(bind)
      @binder = bind
    end

    class << self
      # @!attribute [r] current
      def current
        Thread.current[ThreadLocalKey]
      end

      # :nodoc:
      # @version 5.0.0
      def tcp_cork_supported?
        RbConfig::CONFIG['host_os'] =~ /linux/ &&
          Socket.const_defined?(:IPPROTO_TCP) &&
          Socket.const_defined?(:TCP_CORK)
      end

      # :nodoc:
      # @version 5.0.0
      def closed_socket_supported?
        RbConfig::CONFIG['host_os'] =~ /linux/ &&
          Socket.const_defined?(:IPPROTO_TCP) &&
          Socket.const_defined?(:TCP_INFO)
      end
      private :tcp_cork_supported?
      private :closed_socket_supported?
    end

    # On Linux, use TCP_CORK to better control how the TCP stack
    # packetizes our stream. This improves both latency and throughput.
    #
    if tcp_cork_supported?
      UNPACK_TCP_STATE_FROM_TCP_INFO = "C".freeze

      # 6 == Socket::IPPROTO_TCP
      # 3 == TCP_CORK
      # 1/0 == turn on/off
      def cork_socket(socket)
        begin
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 1) if socket.kind_of? TCPSocket
        rescue IOError, SystemCallError
          Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
        end
      end

      def uncork_socket(socket)
        begin
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 0) if socket.kind_of? TCPSocket
        rescue IOError, SystemCallError
          Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
        end
      end
    else
      def cork_socket(socket)
      end

      def uncork_socket(socket)
      end
    end

    if closed_socket_supported?
      def closed_socket?(socket)
        return false unless socket.kind_of? TCPSocket
        return false unless @precheck_closing

        begin
          tcp_info = socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_INFO)
        rescue IOError, SystemCallError
          Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
          @precheck_closing = false
          false
        else
          state = tcp_info.unpack(UNPACK_TCP_STATE_FROM_TCP_INFO)[0]
          # TIME_WAIT: 6, CLOSE: 7, CLOSE_WAIT: 8, LAST_ACK: 9, CLOSING: 11
          (state >= 6 && state <= 9) || state == 11
        end
      end
    else
      def closed_socket?(socket)
        false
      end
    end

    # @!attribute [r] backlog
    def backlog
      @thread_pool and @thread_pool.backlog
    end

    # @!attribute [r] running
    def running
      @thread_pool and @thread_pool.spawned
    end


    # This number represents the number of requests that
    # the server is capable of taking right now.
    #
    # For example if the number is 5 then it means
    # there are 5 threads sitting idle ready to take
    # a request. If one request comes in, then the
    # value would be 4 until it finishes processing.
    # @!attribute [r] pool_capacity
    def pool_capacity
      @thread_pool and @thread_pool.pool_capacity
    end

    # Runs the server.
    #
    # If +background+ is true (the default) then a thread is spun
    # up in the background to handle requests. Otherwise requests
    # are handled synchronously.
    #
    def run(background=true)
      BasicSocket.do_not_reverse_lookup = true

      @events.fire :state, :booting

      @status = :run

      @thread_pool = ThreadPool.new(
        @min_threads,
        @max_threads,
        ::Puma::IOBuffer,
        &method(:process_client)
      )

      @thread_pool.out_of_band_hook = @options[:out_of_band]
      @thread_pool.clean_thread_locals = @options[:clean_thread_locals]

      if @queue_requests
        @reactor = Reactor.new(&method(:reactor_wakeup))
        @reactor.run
      end

      if @reaping_time
        @thread_pool.auto_reap!(@reaping_time)
      end

      if @auto_trim_time
        @thread_pool.auto_trim!(@auto_trim_time)
      end

      @events.fire :state, :running

      if background
        @thread = Thread.new do
          Puma.set_thread_name "server"
          handle_servers
        end
        return @thread
      else
        handle_servers
      end
    end

    # This method is called from the Reactor thread when a queued Client receives data,
    # times out, or when the Reactor is shutting down.
    #
    # It is responsible for ensuring that a request has been completely received
    # before it starts to be processed by the ThreadPool. This may be known as read buffering.
    # If read buffering is not done, and no other read buffering is performed (such as by an application server
    # such as nginx) then the application would be subject to a slow client attack.
    #
    # For a graphical representation of how the request buffer works see [architecture.md](https://github.com/puma/puma/blob/master/docs/architecture.md#connection-pipeline).
    #
    # The method checks to see if it has the full header and body with
    # the `Puma::Client#try_to_finish` method. If the full request has been sent,
    # then the request is passed to the ThreadPool (`@thread_pool << client`)
    # so that a "worker thread" can pick up the request and begin to execute application logic.
    # The Client is then removed from the reactor (return `true`).
    #
    # If a client object times out, a 408 response is written, its connection is closed,
    # and the object is removed from the reactor (return `true`).
    #
    # If the Reactor is shutting down, all Clients are either timed out or passed to the
    # ThreadPool, depending on their current state (#can_close?).
    #
    # Otherwise, if the full request is not ready then the client will remain in the reactor
    # (return `false`). When the client sends more data to the socket the `Puma::Client` object
    # will wake up and again be checked to see if it's ready to be passed to the thread pool.
    def reactor_wakeup(client)
      shutdown = !@queue_requests
      if client.try_to_finish || (shutdown && !client.can_close?)
        @thread_pool << client
      elsif shutdown || client.timeout == 0
        client.timeout!
      end
    rescue StandardError => e
      client_error(e, client)
      client.close
      true
    end

    def handle_servers
      @check, @notify = Puma::Util.pipe unless @notify
      begin
        check = @check
        sockets = [check] + @binder.ios
        pool = @thread_pool
        queue_requests = @queue_requests

        remote_addr_value = nil
        remote_addr_header = nil

        case @options[:remote_address]
        when :value
          remote_addr_value = @options[:remote_address_value]
        when :header
          remote_addr_header = @options[:remote_address_header]
        end

        while @status == :run
          begin
            ios = IO.select sockets
            ios.first.each do |sock|
              if sock == check
                break if handle_check
              else
                pool.wait_until_not_full
                pool.wait_for_less_busy_worker(
                  @options[:wait_for_less_busy_worker].to_f)

                io = begin
                  sock.accept_nonblock
                rescue IO::WaitReadable
                  next
                end
                client = Client.new io, @binder.env(sock)
                if remote_addr_value
                  client.peerip = remote_addr_value
                elsif remote_addr_header
                  client.remote_addr_header = remote_addr_header
                end
                pool << client
              end
            end
          rescue Object => e
            @events.unknown_error e, nil, "Listen loop"
          end
        end

        @events.fire :state, @status

        if queue_requests
          @queue_requests = false
          @reactor.shutdown
        end
        graceful_shutdown if @status == :stop || @status == :restart
      rescue Exception => e
        @events.unknown_error e, nil, "Exception handling servers"
      ensure
        begin
          @check.close unless @check.closed?
        rescue Errno::EBADF, RuntimeError
          # RuntimeError is Ruby 2.2 issue, can't modify frozen IOError
          # Errno::EBADF is infrequently raised
        end
        @notify.close
        @notify = nil
        @check = nil
      end

      @events.fire :state, :done
    end

    # :nodoc:
    def handle_check
      cmd = @check.read(1)

      case cmd
      when STOP_COMMAND
        @status = :stop
        return true
      when HALT_COMMAND
        @status = :halt
        return true
      when RESTART_COMMAND
        @status = :restart
        return true
      end

      return false
    end

    # Given a connection on +client+, handle the incoming requests,
    # or queue the connection in the Reactor if no request is available.
    #
    # This method is called from a ThreadPool worker thread.
    #
    # This method supports HTTP Keep-Alive so it may, depending on if the client
    # indicates that it supports keep alive, wait for another request before
    # returning.
    #
    # Return true if one or more requests were processed.
    def process_client(client, buffer)
      # Advertise this server into the thread
      Thread.current[ThreadLocalKey] = self

      clean_thread_locals = @options[:clean_thread_locals]
      close_socket = true

      requests = 0

      begin
        if @queue_requests &&
          !client.eagerly_finish

          client.set_timeout(@first_data_timeout)
          if @reactor.add client
            close_socket = false
            return false
          end
        end

        with_force_shutdown(client) do
          client.finish(@first_data_timeout)
        end

        while true
          case handle_request(client, buffer)
          when false
            break
          when :async
            close_socket = false
            break
          when true
            buffer.reset

            ThreadPool.clean_thread_locals if clean_thread_locals

            requests += 1

            check_for_more_data = @status == :run

            if requests >= MAX_FAST_INLINE
              # This will mean that reset will only try to use the data it already
              # has buffered and won't try to read more data. What this means is that
              # every client, independent of their request speed, gets treated like a slow
              # one once every MAX_FAST_INLINE requests.
              check_for_more_data = false
            end

            next_request_ready = with_force_shutdown(client) do
              client.reset(check_for_more_data)
            end

            unless next_request_ready
              break unless @queue_requests
              client.set_timeout @persistent_timeout
              if @reactor.add client
                close_socket = false
                break
              end
            end
          end
        end
        true
      rescue StandardError => e
        client_error(e, client)
        # The ensure tries to close +client+ down
        requests > 0
      ensure
        buffer.reset

        begin
          client.close if close_socket
        rescue IOError, SystemCallError
          Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
          # Already closed
        rescue StandardError => e
          @events.unknown_error e, nil, "Client"
        end
      end
    end

    # Triggers a client timeout if the thread-pool shuts down
    # during execution of the provided block.
    def with_force_shutdown(client, &block)
      @thread_pool.with_force_shutdown(&block)
    rescue ThreadPool::ForceShutdown
      client.timeout!
    end

    # Given a Hash +env+ for the request read from +client+, add
    # and fixup keys to comply with Rack's env guidelines.
    #
    def normalize_env(env, client)
      if host = env[HTTP_HOST]
        if colon = host.index(":")
          env[SERVER_NAME] = host[0, colon]
          env[SERVER_PORT] = host[colon+1, host.bytesize]
        else
          env[SERVER_NAME] = host
          env[SERVER_PORT] = default_server_port(env)
        end
      else
        env[SERVER_NAME] = LOCALHOST
        env[SERVER_PORT] = default_server_port(env)
      end

      unless env[REQUEST_PATH]
        # it might be a dumbass full host request header
        uri = URI.parse(env[REQUEST_URI])
        env[REQUEST_PATH] = uri.path

        raise "No REQUEST PATH" unless env[REQUEST_PATH]

        # A nil env value will cause a LintError (and fatal errors elsewhere),
        # so only set the env value if there actually is a value.
        env[QUERY_STRING] = uri.query if uri.query
      end

      env[PATH_INFO] = env[REQUEST_PATH]

      # From https://www.ietf.org/rfc/rfc3875 :
      # "Script authors should be aware that the REMOTE_ADDR and
      # REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      # may not identify the ultimate source of the request.
      # They identify the client for the immediate request to the
      # server; that client may be a proxy, gateway, or other
      # intermediary acting on behalf of the actual source client."
      #

      unless env.key?(REMOTE_ADDR)
        begin
          addr = client.peerip
        rescue Errno::ENOTCONN
          # Client disconnects can result in an inability to get the
          # peeraddr from the socket; default to localhost.
          addr = LOCALHOST_IP
        end

        # Set unix socket addrs to localhost
        addr = LOCALHOST_IP if addr.empty?

        env[REMOTE_ADDR] = addr
      end
    end

    def default_server_port(env)
      if ['on', HTTPS].include?(env[HTTPS_KEY]) || env[HTTP_X_FORWARDED_PROTO].to_s[0...5] == HTTPS || env[HTTP_X_FORWARDED_SCHEME] == HTTPS || env[HTTP_X_FORWARDED_SSL] == "on"
        PORT_443
      else
        PORT_80
      end
    end

    # Takes the request +req+, invokes the Rack application to construct
    # the response and writes it back to +req.io+.
    #
    # The second parameter +lines+ is a IO-like object unique to this thread.
    # This is normally an instance of Puma::IOBuffer.
    #
    # It'll return +false+ when the connection is closed, this doesn't mean
    # that the response wasn't successful.
    #
    # It'll return +:async+ if the connection remains open but will be handled
    # elsewhere, i.e. the connection has been hijacked by the Rack application.
    #
    # Finally, it'll return +true+ on keep-alive connections.
    def handle_request(req, lines)
      @requests_count +=1

      env = req.env
      client = req.io

      return false if closed_socket?(client)

      normalize_env env, req

      env[PUMA_SOCKET] = client

      if env[HTTPS_KEY] && client.peercert
        env[PUMA_PEERCERT] = client.peercert
      end

      env[HIJACK_P] = true
      env[HIJACK] = req

      body = req.body

      head = env[REQUEST_METHOD] == HEAD

      env[RACK_INPUT] = body
      env[RACK_URL_SCHEME] = default_server_port(env) == PORT_443 ? HTTPS : HTTP

      if @early_hints
        env[EARLY_HINTS] = lambda { |headers|
          begin
            fast_write client, str_early_hints(headers)
          rescue ConnectionError => e
            @events.debug_error e
            # noop, if we lost the socket we just won't send the early hints
          end
        }
      end

      # Fixup any headers with , in the name to have _ now. We emit
      # headers with , in them during the parse phase to avoid ambiguity
      # with the - to _ conversion for critical headers. But here for
      # compatibility, we'll convert them back. This code is written to
      # avoid allocation in the common case (ie there are no headers
      # with , in their names), that's why it has the extra conditionals.

      to_delete = nil
      to_add = nil

      env.each do |k,v|
        if k.start_with?("HTTP_") and k.include?(",") and k != "HTTP_TRANSFER,ENCODING"
          if to_delete
            to_delete << k
          else
            to_delete = [k]
          end

          unless to_add
            to_add = {}
          end

          to_add[k.tr(",", "_")] = v
        end
      end

      if to_delete
        to_delete.each { |k| env.delete(k) }
        env.merge! to_add
      end

      # A rack extension. If the app writes #call'ables to this
      # array, we will invoke them when the request is done.
      #
      after_reply = env[RACK_AFTER_REPLY] = []

      begin
        begin
          status, headers, res_body = @thread_pool.with_force_shutdown do
            @app.call(env)
          end

          return :async if req.hijacked

          status = status.to_i

          if status == -1
            unless headers.empty? and res_body == []
              raise "async response must have empty headers and body"
            end

            return :async
          end
        rescue ThreadPool::ForceShutdown => e
          @events.unknown_error e, req, "Rack app"
          @events.log "Detected force shutdown of a thread"

          status, headers, res_body = lowlevel_error(e, env, 503)
        rescue Exception => e
          @events.unknown_error e, req, "Rack app"

          status, headers, res_body = lowlevel_error(e, env, 500)
        end

        content_length = nil
        no_body = head

        if res_body.kind_of? Array and res_body.size == 1
          content_length = res_body[0].bytesize
        end

        cork_socket client

        line_ending = LINE_END
        colon = COLON

        http_11 = env[HTTP_VERSION] == HTTP_11
        if http_11
          allow_chunked = true
          keep_alive = env.fetch(HTTP_CONNECTION, "").downcase != CLOSE

          # An optimization. The most common response is 200, so we can
          # reply with the proper 200 status without having to compute
          # the response header.
          #
          if status == 200
            lines << HTTP_11_200
          else
            lines.append "HTTP/1.1 ", status.to_s, " ",
                         fetch_status_code(status), line_ending

            no_body ||= status < 200 || STATUS_WITH_NO_ENTITY_BODY[status]
          end
        else
          allow_chunked = false
          keep_alive = env.fetch(HTTP_CONNECTION, "").downcase == KEEP_ALIVE

          # Same optimization as above for HTTP/1.1
          #
          if status == 200
            lines << HTTP_10_200
          else
            lines.append "HTTP/1.0 ", status.to_s, " ",
                         fetch_status_code(status), line_ending

            no_body ||= status < 200 || STATUS_WITH_NO_ENTITY_BODY[status]
          end
        end

        # regardless of what the client wants, we always close the connection
        # if running without request queueing
        keep_alive &&= @queue_requests

        response_hijack = nil

        headers.each do |k, vs|
          case k.downcase
          when CONTENT_LENGTH2
            next if possible_header_injection?(vs)
            content_length = vs
            next
          when TRANSFER_ENCODING
            allow_chunked = false
            content_length = nil
          when HIJACK
            response_hijack = vs
            next
          end

          if vs.respond_to?(:to_s) && !vs.to_s.empty?
            vs.to_s.split(NEWLINE).each do |v|
              next if possible_header_injection?(v)
              lines.append k, colon, v, line_ending
            end
          else
            lines.append k, colon, line_ending
          end
        end

        # HTTP/1.1 & 1.0 assume different defaults:
        # - HTTP 1.0 assumes the connection will be closed if not specified
        # - HTTP 1.1 assumes the connection will be kept alive if not specified.
        # Only set the header if we're doing something which is not the default
        # for this protocol version
        if http_11
          lines << CONNECTION_CLOSE if !keep_alive
        else
          lines << CONNECTION_KEEP_ALIVE if keep_alive
        end

        if no_body
          if content_length and status != 204
            lines.append CONTENT_LENGTH_S, content_length.to_s, line_ending
          end

          lines << line_ending
          fast_write client, lines.to_s
          return keep_alive
        end

        if content_length
          lines.append CONTENT_LENGTH_S, content_length.to_s, line_ending
          chunked = false
        elsif !response_hijack and allow_chunked
          lines << TRANSFER_ENCODING_CHUNKED
          chunked = true
        end

        lines << line_ending

        fast_write client, lines.to_s

        if response_hijack
          response_hijack.call client
          return :async
        end

        begin
          res_body.each do |part|
            next if part.bytesize.zero?
            if chunked
              str = part.bytesize.to_s(16) << line_ending << part << line_ending
              fast_write client, str
            else
              fast_write client, part
            end
            client.flush
          end

          if chunked
            fast_write client, CLOSE_CHUNKED
            client.flush
          end
        rescue SystemCallError, IOError
          raise ConnectionError, "Connection error detected during write"
        end

      ensure
        uncork_socket client

        body.close
        req.tempfile.unlink if req.tempfile
        res_body.close if res_body.respond_to? :close

        after_reply.each { |o| o.call }
      end

      return keep_alive
    end

    def fetch_status_code(status)
      HTTP_STATUS_CODES.fetch(status) { 'CUSTOM' }
    end
    private :fetch_status_code

    # Given the request +env+ from +client+ and the partial body +body+
    # plus a potential Content-Length value +cl+, finish reading
    # the body and return it.
    #
    # If the body is larger than MAX_BODY, a Tempfile object is used
    # for the body, otherwise a StringIO is used.
    #
    def read_body(env, client, body, cl)
      content_length = cl.to_i

      remain = content_length - body.bytesize

      return StringIO.new(body) if remain <= 0

      # Use a Tempfile if there is a lot of data left
      if remain > MAX_BODY
        stream = Tempfile.new(Const::PUMA_TMP_BASE)
        stream.binmode
      else
        # The body[0,0] trick is to get an empty string in the same
        # encoding as body.
        stream = StringIO.new body[0,0]
      end

      stream.write body

      # Read an odd sized chunk so we can read even sized ones
      # after this
      chunk = client.readpartial(remain % CHUNK_SIZE)

      # No chunk means a closed socket
      unless chunk
        stream.close
        return nil
      end

      remain -= stream.write(chunk)

      # Raed the rest of the chunks
      while remain > 0
        chunk = client.readpartial(CHUNK_SIZE)
        unless chunk
          stream.close
          return nil
        end

        remain -= stream.write(chunk)
      end

      stream.rewind

      return stream
    end

    # Handle various error types thrown by Client I/O operations.
    def client_error(e, client)
      # Swallow, do not log
      return if [ConnectionError, EOFError].include?(e.class)

      lowlevel_error(e, client.env)
      case e
      when MiniSSL::SSLError
        @events.ssl_error e, client.io
      when HttpParserError
        client.write_error(400)
        @events.parse_error e, client
      else
        client.write_error(500)
        @events.unknown_error e, nil, "Read"
      end
    end

    # A fallback rack response if +@app+ raises as exception.
    #
    def lowlevel_error(e, env, status=500)
      if handler = @options[:lowlevel_error_handler]
        if handler.arity == 1
          return handler.call(e)
        elsif handler.arity == 2
          return handler.call(e, env)
        else
          return handler.call(e, env, status)
        end
      end

      if @leak_stack_on_error
        [status, {}, ["Puma caught this error: #{e.message} (#{e.class})\n#{e.backtrace.join("\n")}"]]
      else
        [status, {}, ["An unhandled lowlevel error occurred. The application logs may have details.\n"]]
      end
    end

    # Wait for all outstanding requests to finish.
    #
    def graceful_shutdown
      if @options[:shutdown_debug]
        threads = Thread.list
        total = threads.size

        pid = Process.pid

        $stdout.syswrite "#{pid}: === Begin thread backtrace dump ===\n"

        threads.each_with_index do |t,i|
          $stdout.syswrite "#{pid}: Thread #{i+1}/#{total}: #{t.inspect}\n"
          $stdout.syswrite "#{pid}: #{t.backtrace.join("\n#{pid}: ")}\n\n"
        end
        $stdout.syswrite "#{pid}: === End thread backtrace dump ===\n"
      end

      if @options[:drain_on_shutdown]
        count = 0

        while true
          ios = IO.select @binder.ios, nil, nil, 0
          break unless ios

          ios.first.each do |sock|
            begin
              if io = sock.accept_nonblock
                count += 1
                client = Client.new io, @binder.env(sock)
                @thread_pool << client
              end
            rescue SystemCallError
            end
          end
        end

        @events.debug "Drained #{count} additional connections."
      end

      if @status != :restart
        @binder.close
      end

      if @thread_pool
        if timeout = @options[:force_shutdown_after]
          @thread_pool.shutdown timeout.to_f
        else
          @thread_pool.shutdown
        end
      end
    end

    def notify_safely(message)
      @check, @notify = Puma::Util.pipe unless @notify
      begin
        @notify << message
      rescue IOError, NoMethodError, Errno::EPIPE
         # The server, in another thread, is shutting down
        Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
      rescue RuntimeError => e
        # Temporary workaround for https://bugs.ruby-lang.org/issues/13239
        if e.message.include?('IOError')
          Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
        else
          raise e
        end
      end
    end
    private :notify_safely

    # Stops the acceptor thread and then causes the worker threads to finish
    # off the request queue before finally exiting.

    def stop(sync=false)
      notify_safely(STOP_COMMAND)
      @thread.join if @thread && sync
    end

    def halt(sync=false)
      notify_safely(HALT_COMMAND)
      @thread.join if @thread && sync
    end

    def begin_restart(sync=false)
      notify_safely(RESTART_COMMAND)
      @thread.join if @thread && sync
    end

    def fast_write(io, str)
      n = 0
      while true
        begin
          n = io.syswrite str
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK
          if !IO.select(nil, [io], nil, WRITE_TIMEOUT)
            raise ConnectionError, "Socket timeout writing data"
          end

          retry
        rescue  Errno::EPIPE, SystemCallError, IOError
          raise ConnectionError, "Socket timeout writing data"
        end

        return if n == str.bytesize
        str = str.byteslice(n..-1)
      end
    end
    private :fast_write

    def shutting_down?
      @status == :stop || @status == :restart
    end

    def possible_header_injection?(header_value)
      HTTP_INJECTION_REGEX =~ header_value.to_s
    end
    private :possible_header_injection?

    # List of methods invoked by #stats.
    # @version 5.0.0
    STAT_METHODS = [:backlog, :running, :pool_capacity, :max_threads, :requests_count].freeze

    # Returns a hash of stats about the running server for reporting purposes.
    # @version 5.0.0
    # @!attribute [r] stats
    def stats
      STAT_METHODS.map {|name| [name, send(name) || 0]}.to_h
    end

    def str_early_hints(headers)
      eh_str = "HTTP/1.1 103 Early Hints\r\n".dup
      headers.each_pair do |k, vs|
        if vs.respond_to?(:to_s) && !vs.to_s.empty?
          vs.to_s.split(NEWLINE).each do |v|
            next if possible_header_injection?(v)
            eh_str << "#{k}: #{v}\r\n"
          end
        else
          eh_str << "#{k}: #{vs}\r\n"
        end
      end
      "#{eh_str}\r\n".freeze
    end
    private :str_early_hints
  end
end
