require 'socket'
require 'openssl'
require 'logger'
require 'uri'
require 'optparse'

class Request # grabs an HTTP request from the socket
  attr_accessor :contents, :method, :host, :port
  def initialize(client)
    @contents = ""
    while l = client.readpartial(4096) and not l.end_with? "\r\n"
      @contents << l
    end
    @contents << l
    @method, addr, protocol = contents.split('\n')[0].split
    if self.is_connect? #addr is host:port
      @host, @port = addr.split ':'
      if @port.nil?
        @port = 443
      else
        @port = @port.to_i
      end
    else #addr is a uri
      uri = URI(addr)
      @host = uri.host
      @port = uri.port
      if @port.nil?
        @port = 80
      end
    end
  end
  def is_connect?
    @method == "CONNECT"
  end
end


class SSLProxy
  def initialize(port, opt = {}) 
    @proxy = TCPServer.new(port)
    @invisible = opt[:invisible] || false
    @upstream_host = opt[:upstream_host] || nil
    @upstream_port = opt[:upstream_port] || nil
    # use this to cache forged ssl certs (SSLContexts)
    @ssl_contexts = Hash.new { |ssl_contexts, subject|
      #we use a previously generated root ca
      root_key = OpenSSL::PKey::RSA.new File.open("root.key")
      root_ca = OpenSSL::X509::Certificate.new File.open("root.pem")
      
      #generate the forged cert
      key = OpenSSL::PKey::RSA.new 2048
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = Random.rand(1000)
      cert.subject = subject
      cert.issuer = root_ca.subject # root CA is the issuer
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = cert.not_before + 1 * 365 * 24 * 60 * 60 # 1 years validity
      ef = OpenSSL::X509::ExtensionFactory.new cert, root_ca
      ef.create_ext("keyUsage","digitalSignature", true)
      ef.create_ext("subjectKeyIdentifier","hash",false)
      ef.create_ext("basicConstraints","CA:FALSE",false)
      cert.sign(root_key, OpenSSL::Digest::SHA256.new)

      #fill out the context
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.key = key
      ctx.cert = cert
      ctx.ca_file="root.pem"
      ssl_contexts[subject] = ctx
    }
  end

  def upstream_proxy?
    #are we forwarding traffic to an upstream proxy (vs. directly to
    #host)
    not (@upstream_host.nil? or @upstream_port.nil?)
  end

  def start
    loop do
      client = @proxy.accept
      Thread.new(client) { |client|
        begin
          request = Request.new client
          self.request_handler client, request
        rescue
          $LOG.error($!)
        end
      } 
    end
  end

  

  def connect_ssl(host, port)
    socket = TCPSocket.new(host,port)
    ssl = OpenSSL::SSL::SSLSocket.new(socket)
    ssl.sync_close = true
    ssl.connect
  end

  def grab_cert(host, port)
    c = self.connect_ssl host, port
    c.peer_cert
  end
  
  def request_handler(client, request)
    #if his is the visible proxy mode, the client will send us an
    #unencrypted CONNECT request before we begin the SSL handshake
    #we ascertain the host/port from there
    if request.is_connect?
      #connect to the server and forge the correct cert (using the same
      #subject as the server we connected to)
      if self.upstream_proxy?
        cert = self.grab_cert request.host, request.port
        server = self.connect_ssl @upstream_host, @upstream_port
      else
        server = self.connect_ssl request.host, request.port
        cert = server.peer_cert
      end
      ctx = @ssl_contexts[cert.subject]
      client.write "HTTP/1.0 200 Connection established\r\n\r\n"
      #initiate handshake
      ssl_client = OpenSSL::SSL::SSLSocket.new(client, ctx)
      ssl_client.accept
      self.create_pipe ssl_client, server, initial_request
    else
      #we're just passing through unencrypted data
      if self.upstream_proxy?
        server = TCPSocket.new(@upstream_host, @upstream_port)
      else
        server = TCPSocket.new(request.host, request.port)
        server.write request.contents
        server.write "\r\n"
      end
      #we pass along the request we cached
      self.create_pipe client, server, request
    end
  end


  def create_pipe(client, server, initial_request)
    begin
      if initial_request
        server.write initial_request.contents
        $LOG.info("#{Thread.current}: client->server (initial) #{initial_request.inspect}")
      end
      while true
        # Wait for data to be available on either socket.
        (ready_sockets, dummy, dummy) = IO.select([client, server])
        begin
          ready_sockets.each do |socket|
            if socket == client #and not socket.eof?
              # Read from client, write to server.
              request = Request.new client
              # we may get requests for another domain coming down
              # this pipe if we are a visible proxy 
              # if wer're not proxied, we restart the handler
              unless @invisible or self.upstream_proxy?
                if request.host != initial_request.host or request.port != initial_request.port
                  #we can also close the connection here??
                  #server.close
                  #client.close
                  self.request_handler client, request
                  break
                end
              end
              $LOG.info("#{Thread.current}: client->server #{request.inspect}")
              server.write request.contents
              server.flush
            else
              # Read from server, write to client.
              data = socket.readpartial(4096)
              $LOG.info("#{Thread.current}: server->client #{data.inspect}")
              client.write data
              client.flush
            end
          end
        rescue EOFError
          $LOG.debug($!)
          break
        rescue IOError
          $LOG.debug($!)
          break
        end
      end
      unless client.closed?
        client.close
      end
      unless server.closed?
        server.close
      end
    rescue EOFError
      $LOG.debug($!)
    rescue IOError
      $LOG.debug($!)
    rescue
      $LOG.error("Error: #{$!}")
    end
  end
end

$LOG = Logger.new($stdout)
$LOG.sev_threshold = Logger::ERROR

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: example.rb [options]"

  opts.on("-d", "--debug", "Enable debug output") do 
    $LOG.sev_threshold = Logger::DEBUG
  end
  opts.on("-P", "--upstream_proxy HOST:PORT", "Use an upstream proxy (host:port)") do |proxy|
    host, port = proxy.split(':')
    if host.nil? or port.nil?
      $stderr.puts "proxy must be in the form host:port"
      exit
    end
    options[:upstream_host] = host
    options[:upstream_port] = port
  end
end.parse!


s = SSLProxy.new(8008, options)
s.start

