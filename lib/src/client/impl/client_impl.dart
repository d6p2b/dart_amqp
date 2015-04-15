part of dart_amqp.client;

class _ClientImpl implements Client {

  // Configuration options
  ConnectionSettings settings;

  // Tuning settings
  TuningSettings get tuningSettings => settings.tuningSettings;

  // The connection to the server
  int _connectionAttempt;
  Socket _socket;

  // The list of open channels. Channel 0 is always reserved for signaling
  Map<int, _ChannelImpl> _channels = new Map<int, _ChannelImpl>();

  // Connection status
  Completer _connected;
  Completer _clientClosed;

  _ClientImpl({ConnectionSettings settings}) {

    // Use defaults if no settings specified
    this.settings = settings == null
    ? new ConnectionSettings()
    : settings;
  }

  /**
   * Attempt to reconnect to the server. If the attempt fails, it will be retried after
   * [reconnectWaitTime] ms up to [maxConnectionAttempts] times. If all connection attempts
   * fail, then the [_connected] [Future] returned by a call to [open[ will also fail
   */

  Future _reconnect() {
    if (_connected == null) {
      _connected = new Completer();
    }

    connectionLogger.info("Trying to connect to ${settings.host}:${settings.port} [attempt ${_connectionAttempt + 1}/${settings.maxConnectionAttempts}]");
    Socket.connect(settings.host, settings.port).then((Socket s) {
      _socket = s;

      // Bind processors and initiate handshake
      _socket
      .transform(new RawFrameParser(tuningSettings).transformer)
      .transform(new AmqpMessageDecoder().transformer)
      .listen(_handleMessage, onError : _handleException, onDone : _onSocketClosed);

      // Allocate channel 0 for handshaking and transmit the AMQP header to bootstrap the handshake
      _channels.clear();
      _channels.putIfAbsent(0, () => new _ChannelImpl(0, this));

    })
    .catchError((err, trace) {

      // Connection attempt completed with an error (probably protocol mismatch)
      if (_connected.isCompleted) {
        return;
      }

      if (++_connectionAttempt >= settings.maxConnectionAttempts) {
        String errorMessage = "Could not connect to ${settings.host}:${settings.port} after ${settings.maxConnectionAttempts} attempts. Giving up";
        connectionLogger.severe(errorMessage);
        _connected.completeError(new ConnectionFailedException(errorMessage));

        // Clear _connected future so the client can invoke open() in the future
        _connected = null;
      } else {
        // Retry after reconnectWaitTime ms
        new Timer(settings.reconnectWaitTime, _reconnect);
      }
    });

    return _connected.future;
  }

  /**
   * Check if a connection is currently in handshake state
   */
  bool get handshaking => _socket != null && _connected != null && !_connected.isCompleted;

  void _onSocketClosed() {
    // If we are still handshaking, it could be that the server disconnected us
    // due to a failed SASL auth atttempt. In this case we should trigger a connection
    // exception
    if (handshaking && _channels.containsKey(0) &&
    (_channels[0]._lastHandshakeMessage is ConnectionStartOk ||
    _channels[0]._lastHandshakeMessage is ConnectionSecureOk)
    ) {
      _handleException(new FatalException("Authentication failed"));
    } else {
      _handleException(new FatalException("Lost connection to the server"));
    }
  }

  void _handleMessage(DecodedMessage serverMessage) {
    try {
      // Heartbeat frames should be received on channel 0
      if (serverMessage is HeartbeatFrameImpl && serverMessage.channel != 0) {
        throw new ConnectionException("Received HEARTBEAT message on a channel > 0", ErrorType.COMMAND_INVALID, 0, 0);
      }

      // If we are still handshaking and we receive a message on another channel this is an error
      if (!_connected.isCompleted && serverMessage.channel != 0) {
        throw new FatalException("Received message for channel ${serverMessage.channel} while still handshaking");
      }

      // Connection-class messages should only be received on channel 0
      if (serverMessage.message.msgClassId == 10 && serverMessage.channel != 0) {
        throw new ConnectionException("Received CONNECTION class message on a channel > 0", ErrorType.COMMAND_INVALID, serverMessage.message.msgClassId, serverMessage.message.msgMethodId);
      }

      // Fetch target channel and forward frame for processing
      _ChannelImpl target = _channels[ serverMessage.channel ];
      if (target == null) {
        // message on unknown channel; ignore
        return;
      }

      // If we got a ConnectionClose message from the server, throw the appropriate exception
      if (serverMessage.message is ConnectionClose) {
        // Ack the closing of the connection
        _channels[0].writeMessage(new ConnectionCloseOk());

        ConnectionClose serverResponse = (serverMessage.message as ConnectionClose);
        throw new ConnectionException(serverResponse.replyText, ErrorType.valueOf(serverResponse.replyCode), serverResponse.msgClassId, serverResponse.msgMethodId);
      }

      // Deliver to channel
      target.handleMessage(serverMessage);

      // If we got a ConnectionCloseOk message before a pending ChannelCloseOk message
      // force the other channels to close
      if (serverMessage.message is ConnectionCloseOk) {
        _channels.values
        .where((_ChannelImpl channel) => channel._channelClosed != null && !channel._channelClosed.isCompleted)
        .forEach((_ChannelImpl channel) => channel._completeOperation(serverMessage.message));
      }

    } catch (e) {
      _handleException(e);
    }
  }

  void _handleException(ex) {
    // Ignore exceptions while shutting down
    if (_clientClosed != null) {
      return;
    }

    connectionLogger.severe(ex);

    // If we are still handshaking, abort the connection; flush the channels and shut down
    if (handshaking) {
      _channels.clear();
      _connected.completeError(ex);
      close();
      return;
    }

    switch (ex.runtimeType) {
      case FatalException:
      case ConnectionException:

      // Forward to all channels and then shutdown
        _channels
        .values.toList()
        .reversed
        .forEach((_ChannelImpl channel) => channel.handleException(ex));

        _close();
        break;
      case ChannelException:
      // Forward to the appropriate channel and remove it from our list
        _ChannelImpl target = _channels[ ex.channel ];
        if (target != null) {
          target.handleException(ex);
          _channels.remove(ex.channel);
        }

        break;
    }
  }

  Future _close() {

    if (_socket == null) {
      return new Future.value();
    }

    // Already shutting down
    if (_clientClosed != null) {
      return _clientClosed.future;
    }

    // Close all channels in reverse order so we send a connection close message when we close channel 0
    _clientClosed = new Completer();
    Future.wait(
        _channels
        .values
        .toList()
        .reversed
        .map((_ChannelImpl channel) => channel.close())
    )
    .then((_) => _socket.flush())
    .then((_) => _socket.close())
    .then((_) {
      _socket.destroy();
      _socket = null;
      _connected = null;
      _clientClosed.complete();
    });

    return _clientClosed.future;
  }

  /**
   * Open a working connection to the server using [config.cqlVersion] and optionally select
   * keyspace [defaultKeyspace]. Returns a [Future] to be completed on a successful protocol handshake
   */

  Future open() {
    // Prevent multiple connection attempts
    if (_connected != null) {
      return _connected.future;
    }

    _connectionAttempt = 0;
    return _reconnect();
  }

  /**
   * Shutdown any open channels and disconnect the socket. Return a [Future] to be completed
   * when the client has shut down
   */
  Future close() => _close();

  Future<Channel> channel() {
    return open()
    .then((_) {
      // Check if we have exceeded our channel limit (open channels excluding channel 0)
      if (tuningSettings.maxChannels > 0 && _channels.length - 1 >= tuningSettings.maxChannels) {
        return new Future.error(new StateError("Cannot allocate channel; channel limit exceeded (max ${tuningSettings.maxChannels})"));
      }

      // Find next available channel
      _ChannelImpl userChannel = null;
      int nextChannelId = 0;
      while (nextChannelId < 65536) {
        if (!_channels.containsKey(++nextChannelId)) {
          // Found empty slot
          userChannel = new _ChannelImpl(nextChannelId, this);
          _channels[ nextChannelId ] = userChannel;
          break;
        }
      }

      // Run out of slots?
      if (userChannel == null) {
        return new Future.error(new StateError("Cannot allocate channel; all channels are currently in use"));
      }

      return userChannel._channelOpened.future;
    });
  }
}