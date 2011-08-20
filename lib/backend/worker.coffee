# Backend Server Worker
# ---------------------
# Runs server-side actions and shared code, returning the result for the website or HTTP API

zeromq = require('zeromq')

#msgpack = require('msgpack-0.4')  (Note: I tried this but it made negligible difference, in some cases slower than JSON!)

load = require('./loader.coffee')
check = require('../utils/check.coffee')
plugs = require('./plug_sockets.coffee')

# Load the async driver only for the serializer
zmqs = require('../zmq_async.coffee')
serializer = zmqs.formats[SS.config.cluster.serialization]

# Create ZMQ sockets
SS.frontend.socket = zeromq.createSocket('xrep')

# Listen for messages (unless we're running this from the console)
SS.frontend.socket.connect(SS.config.cluster.sockets.be_main) unless SS.internal.mode is 'console'

# Connect any Plug Sockets
plugs.init()

# Load any database connections
load.dbConfigFile()

# Load Event Emitter and custom server-side events
load.serverSideEvents()

# Load file 'trees' for each app folder
trees = load.fileTrees()

# Check none of the files and dirs conflict
check.forNameConflicts(trees)

# Load application files within /app/shared and /app/server
load.serverSideFiles(trees)

# Load Users Online functionality
SS.users = require('./users.coffee')

# Load Redis. Note these connections stay open so scripts will cease to terminate on their own once you call this
SS.redis = require('../redis.coffee').connect()

# Load publish API
SS.publish = require('./publish.coffee')

# Load default message responders
require('./responders')

# Listen for incoming requests and dispatch them to a responder
SS.frontend.socket.on 'message', (envelope, orig_env, request) ->
  try
    # Attempt to unpack raw binary message
    obj = serializer.unpack(request)

    # Silently drop any messages confirming to another RPC version (allows staggered upgrades)
    return false unless obj.version == SS.internal.rpc_version
    
    # First argument is the event name which a responder must listen for
    args = [obj.responder, obj]
    
    # If the request has an 'id' field it expects a callback (most system commands such as heartbeats do not)
    obj.id? && args.push ((response) -> SS.frontend.socket.send envelope, orig_env, serializer.pack(response))
    
    # Emit the request to one or more responders
    SS.backend.responders.emit.apply SS.backend.responders, args
  catch e
    SS.log.error.exception(e)
