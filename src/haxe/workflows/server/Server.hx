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
import js.npm.fsextended.FsExtended;

import minject.Injector;

import promhx.RequestPromises;
import promhx.RetryPromise;

import workflows.server.services.execution.cwl.ServiceCwlExecutor;

/**
 * Represents a queue of compute jobs in Redis
 * Lots of ideas taken from http://blogs.bronto.com/engineering/reliable-queueing-in-redis-part-1/
 */
class Server
{
	static function main()
	{
		trace(Node.process.env);
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

		//TEMP
		app.get('/pdb_convert/:pdbid', function(req, res, next) {
			var pdbid = req.params.pdbid;
			var workflowUuid = js.npm.shortid.ShortId.generate();
			var hostWorkflowPath = Node.process.env["HOST_PWD"] + '/tmp/$workflowUuid/';
			var containerWorkflowPath = 'tmp/$workflowUuid/';
			FsExtended.copyDirSync('/app/client/workflow_convert_pdb', containerWorkflowPath);
			ServiceCwlExecutor.runWorkflow(hostWorkflowPath, containerWorkflowPath, "download_and_clean.cwl", null, ["--pdbcode", "1c7d"])
				.then(function(result) {
					var stdout = result.stdout.replace('\\n', '\n').replace('\\r', '').replace('\\\n', '\n');
					var startIndex = stdout.indexOf('\n{');
					stdout = stdout.substr(startIndex);
					traceGreen('stdout=\n$stdout');
					var fsOut = ccc.storage.ServiceStorageLocalFileSystem.getService('output/');
					var outputs :DynamicAccess<CwlFileOutput> = Json.parse(stdout);
					for (key in outputs.keys()) {
						var file = outputs.get(key);
						var newLocation = 'output/$workflowUuid/${file.basename}';
						trace('${containerWorkflowPath}${file.basename}=>$newLocation');
						FsExtended.copyFileSync('${containerWorkflowPath}${file.basename}', newLocation);
						file.location = newLocation;
					}

					res.send(FsExtended.readFileSync(outputs.get("pdbfile").location).toString());
				})
				.catchError(function(err) {
					res.send(Json.stringify(err));
				});
		});
		//Static file server for client files
		app.use(js.node.express.Express.Static('/app/client/dist'));
		app.use('/client', js.node.express.Express.Static('/app/client'));



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
