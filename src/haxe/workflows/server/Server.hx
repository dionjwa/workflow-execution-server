package workflows.server;

import haxe.remoting.JsonRpc;

import t9.js.jsonrpc.Routes;

import js.Error;
import js.Node;
import js.node.Fs;
import js.node.Path;
import js.node.Process;
import js.node.http.*;
import js.node.Http;
import js.node.Url;
import js.node.stream.Readable;
import js.node.express.Express;
import js.node.express.Application;

import minject.Injector;

import promhx.RequestPromises;
import promhx.RetryPromise;

/**
 * Represents a queue of compute jobs in Redis
 * Lots of ideas taken from http://blogs.bronto.com/engineering/reliable-queueing-in-redis-part-1/
 */
class Server
{

	static function main2()
	{
		var stdout = '
al/bin/cwltool 1.0
[\'docker\', \'pull\', \'docker.io/busybox:latest\']
latest: Pulling from library/busybox
Digest: sha256:29f5d56d12684887bdfa50dcd29fc31eea4aaf4ad3bec43daf19026a7ce69912
Status: Image is up to date for busybox:latest
src=file:///app/hello.tar
[job untar] /tmp/tmp0UpXVn$ docker \\
    run \\
    -i \\
    --volume=/Users/dionamago/autodesk/workflow-execution-server/tmp/ryo4-Vb-g//hello.tar:/var/lib/cwl/stg87cb41dd-d4eb-44ad-b518-99c0d11a9012/hello.tar:ro \\
    --volume=/Users/dionamago/autodesk/workflow-execution-server/tmp/ryo4-Vb-g/:/var/spool/cwl:rw \\
    --volume=/Users/dionamago/autodesk/workflow-execution-server/tmp/ryo4-Vb-g/:/tmp:rw \\
    --workdir=/var/spool/cwl \\
    --read-only=true \\
    --user=0 \\
    --rm \\
    --env=TMPDIR=/tmp \\
    --env=HOME=/var/spool/cwl \\
    docker.io/busybox:latest \\
    tar \\
    xf \\
    /var/lib/cwl/stg87cb41dd-d4eb-44ad-b518-99c0d11a9012/hello.tar \\
    Hello.java
self.outdir=/tmp/tmp0UpXVn
self.successCodes=None
rcode=0
(\'self.generatefiles=%s\', [])
collect_outputs
outputs={u\'example_out\': {\'checksum\': \'sha1$084144159163a53537389bf205dce76ba47ff7c2\', \'basename\': \'Hello.java\', \'size\': 22, \'location\': \'file:///app/Hello.java\', \'class\': \'File\'}}
self.output_callback
[step untar] completion status is success
cleanup
done cleanup
[\'docker\', \'pull\', \'docker.io/java:7\']
7: Pulling from library/java
Digest: sha256:9190fed946554cbd6e9922eb478b6417f37b8a2b02067ab1ab5876c42afa432c
Status: Image is up to date for java:7
src=file:///app/Hello.java
    /var/lib/cwl/stg9d44bf05-da04-4809-967a-3b0f90227f2c/Hello.java
self.outdir=/tmp/tmpfPNyG9
self.successCodes=None
rcode=0
(\'self.generatefiles=%s\', [])
collect_outputs
outputs={u\'classfile\': {\'checksum\': \'sha1$$e68df795c0686e9aa1a1195536bd900f5f417b18\', \'basename\': \'Hello.class\', \'size\': 184, \'location\': \'file:///app/Hello.class\', \'class\': \'File\'}}
self.output_callback
[step compile] completion status is success
cleanup
done cleanup
[workflow workflow.cwl] outdir is /tmp/tmpAz9cFb
Final process status is success
stageFiles
stageFiles file:///app/Hello.class MapperEnt(resolved=\'/app/Hello.class\', target=u\'/app/Hello.class\', type=\'File\')
{
    "classout": {
        "checksum": "sha1$$e68df795c0686e9aa1a1195536bd900f5f417b18",
        "basename": "Hello.class",
        "location": "file:///app/Hello.class",
        "path": "/app/Hello.class",
        "class": "File",
        "size": 184
    }
}
';

		var regex = new EReg("(?:.|\n)*({\n(?:.|\n)*classout(?:.|\n)*}).*", '');
		// var regex = new EReg(".*(classout).*", '');
		traceYellow('regex=${regex}');
		if (regex.match(stdout)) {
			traceGreen('matched!');
			trace('matched');
			var jsonResultString = regex.matched(1);
			trace('jsonResultString=$jsonResultString');
		} else {
			traceRed('not matched');
		}
	}

	static function main()
	{
		Node.process.on(ProcessEvent.UncaughtException, function(err) {
			traceRed('UncaughtException');
			var errObj = {
				stack:try err.stack catch(e :Dynamic){null;},
				error:err,
				errorJson: try untyped err.toJSON() catch(e :Dynamic){null;},
				errorString: try untyped err.toString() catch(e :Dynamic){null;},
				message:'crash'
			}
			//Ensure crash is logged before exiting.
			// Log.critical(errObj);
			traceRed(Std.string(errObj));
			Node.process.exit(1);
		});

		//Required for source mapping
		js.npm.sourcemapsupport.SourceMapSupport;
		ErrorToJson;
		Node.process.stdout.setMaxListeners(100);
		Node.process.stderr.setMaxListeners(100);

		//Begin building everything
		var injector = new Injector();
		injector.map(Injector).toValue(injector); //Map itself

		Promise.promise(true)
			// .pipe(function(_) {
			// 	return setupRedis(injector);
			// })
			// .pipe(function(_) {
			// 	return verifyCCC(injector);
			// })
			.then(function(_) {
				appSetUp(injector);
				appAddPaths(injector);
				setupServer(injector);
				// ServerWebsocket.createWebsocketServer(injector);
				runTests(injector);
			});
	}

	static function appSetUp(injector :Injector)
	{
		// //Load env vars from an .env file if present
		// Node.require('dotenv').config({path: '.env', silent: true});
		// Node.require('dotenv').config({path: 'config/.env', silent: true});

		var app :Application = Express.GetApplication();

		// Your own super cool function
		var logger = function(req, res, next) {
			traceGreen('req url=${req.originalUrl} hostname=${req.hostname} method=${req.method}');
			next(); // Passing the request to the next handler in the stack.
		}
		app.use('*/', cast logger);
		untyped __js__('app.use(require("cors")())');
		trace('loaded cors');
		injector.map(Application).toValue(app);
	}

	static function appAddPaths(injector :Injector)
	{
		var app :Application = injector.getValue(Application);

		app.get('/test', function (req, res) {
	        res.send('OK but currently no tests set up');
	    });

		var router = js.node.express.Express.GetRouter();

		/* @rpc */
		var serverContext = new t9.remoting.jsonrpc.Context();
		injector.map(t9.remoting.jsonrpc.Context).toValue(serverContext);

		//Tests
		// var serviceTests = new workflows.server.tests.ServiceTests();
		// injector.injectInto(serviceTests);
		// serverContext.registerService(serviceTests);

		//Workflows
		var serviceWorkflows = new workflows.server.services.execution.cwl.ServiceCwlExecutor();
		injector.injectInto(serviceWorkflows);
		serverContext.registerService(serviceWorkflows);
		router.post(SERVER_API_RPC_URL_FRAGMENT, Routes.generatePostRequestHandler(serverContext));
		app.post(MULTIPART_API_WORKFLOW_RUN, serviceWorkflows.multiFormJobSubmissionRouter());
		// router.post(SERVER_API_RPC_URL_FRAGMENT, serviceWorkflows.multiFormJobSubmissionRouter());
		// router.get(SERVER_API_RPC_URL_FRAGMENT + '*', Routes.generateGetRequestHandler(serverContext, SERVER_API_RPC_URL_FRAGMENT));

		//Server infrastructure. This automatically handles client JSON-RPC remoting and other API requests
		app.use(SERVER_API_URL, cast router);

		// var computeURL = 'http://ccc:9000';
	 //    Log.info('computeURL:'+ computeURL);
	 //    var computeProxy = js.npm.httpproxy.HttpProxy.createProxyServer({target: computeURL});
	 //    app.get('/*', function (req, res) {
	 //        computeProxy.web(req, res);
	 //    });
	}

	// static function setupRedis(injector :Injector) :Promise<Bool>
	// {
	// 	return getRedisClient()
	// 		.then(function(redis) {
	// 			injector.map(RedisClient).toValue(redis);
	// 			return true;
	// 		});
	// }

	static function setupServer(injector :Injector)
	{
		var env = Node.process.env;
		var app :Application = injector.getValue(Application);
		//Actually create the server and start listening
		var appHandler :IncomingMessage->ServerResponse->(Error->Void)->Void = cast app;
		// var server = Http.createServer(function(req, res) {
		// 	appHandler(req, res, function(err :Dynamic) {
		// 		traceRed(Std.string(err));
		// 		traceRed(err);
		// 		Log.error({error:err != null && err.stack != null ? err.stack : err, message:'Uncaught error'});
		// 	});
		// });
		var server = Http.createServer(cast app);
		injector.map(js.node.http.Server).toValue(server);

		traceYellow('SERVER_PORT=${SERVER_PORT}');
		var PORT :Int = Reflect.hasField(env, 'PORT') ? Std.int(Reflect.field(env, 'PORT')) : SERVER_PORT;
		traceYellow('PORT=${PORT}');
		server.listen(PORT, function() {
			Log.info('Listening http://localhost:$PORT');
		});
		app.use('/output', js.node.express.Express.Static('output'));

		var closing = false;
		Node.process.on('SIGINT', function() {
			Log.warn("Caught interrupt signal");
			if (closing) {
				return;
			}
			closing = true;
			untyped server.close(function() {
				Node.process.exit(0);
			});
		});
	}

	static function runTests(injector :Injector)
	{
		//Run internal tests
		Log.debug('Running server functional tests');
		workflows.server.services.execution.cwl.ServiceCwlExecutorTests.testMultipartRPCSubmission();
	}

	// static function getRedisClient() :Promise<RedisClient>
	// {
	// 	return promhx.RetryPromise.pollDecayingInterval(getRedisClientInternal, 6, 500, 'getRedisClient');
	// }

	// static function getRedisClientInternal() :Promise<RedisClient>
	// {
	// 	var redisParams = {host:'redis', port:6379};
	// 	var client = RedisClient.createClient(redisParams.port, redisParams.host);
	// 	var promise = new DeferredPromise();
	// 	client.once(RedisEvent.Connect, function() {
	// 		Log.debug({system:'redis', event:RedisEvent.Connect, redisParams:redisParams});
	// 		//Only resolve once connected
	// 		if (!promise.boundPromise.isResolved()) {
	// 			promise.resolve(client);
	// 		} else {
	// 			Log.error({log:'Got redis connection, but our promise is already resolved ${redisParams.host}:${redisParams.port}'});
	// 		}
	// 	});
	// 	client.on(RedisEvent.Error, function(err) {
	// 		if (!promise.boundPromise.isResolved()) {
	// 			client.end();
	// 			promise.boundPromise.reject(err);
	// 		} else {
	// 			Log.warn({error:err, system:'redis', event:RedisEvent.Error, redisParams:redisParams});
	// 		}
	// 	});
	// 	client.on(RedisEvent.Reconnecting, function(msg) {
	// 		Log.warn({system:'redis', event:RedisEvent.Reconnecting, reconnection:msg, redisParams:redisParams});
	// 	});
	// 	client.on(RedisEvent.End, function() {
	// 		Log.warn({system:'redis', event:RedisEvent.End, redisParams:redisParams});
	// 	});
	// 	return promise.boundPromise;
	// }

	/**
	 * Help logging by JSON'ifying error objects.
	 * @return [description]
	 */
	static function __init__()
	{
#if js
		untyped __js__("
			if (!('toJSON' in Error.prototype))
				Object.defineProperty(Error.prototype, 'toJSON', {
				value: function () {
					var alt = {};

					Object.getOwnPropertyNames(this).forEach(function (key) {
						alt[key] = this[key];
					}, this);

					return alt;
				},
				configurable: true,
				writable: true
			})
		");
#end
	}
}
