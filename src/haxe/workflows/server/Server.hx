package workflows.server;

import haxe.remoting.JsonRpc;

import t9.js.jsonrpc.Routes;

import js.node.stream.Writable;
import js.node.stream.Readable;

import js.Error;
import js.Node;
import js.node.Fs;
import js.node.Path;
import js.node.Process;
import js.node.http.*;
import js.node.http.ServerResponse;
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
			.then(function(_) {
				appSetUp(injector);
				appAddPaths(injector);
				setupServer(injector);
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

		//Convert PDB id
		app.get('/pdb_convert/:pdbid', function(req, res, next) {
			var pdbid = req.params.pdbid;
			var workflowUuid = js.npm.shortid.ShortId.generate();
			var hostWorkflowPath = Node.process.env["HOST_PWD"] + '/tmp/$workflowUuid/';
			var containerWorkflowPath = 'tmp/$workflowUuid/';
			FsExtended.copyDirSync('/app/client/workflow_convert_pdb', containerWorkflowPath);
			ServiceCwlExecutor.runWorkflow(hostWorkflowPath, containerWorkflowPath, "download_and_clean.cwl", null, ["--pdbcode", pdbid])
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

		//Convert uploaded PDB
		app.post('/pdb_convert', function(req, res :js.npm.express.Response, next) {
			traceCyan('/pdb_convert');

			var workflowUuid = js.npm.shortid.ShortId.generate();
			var hostWorkflowPath = Node.process.env["HOST_PWD"] + '/tmp/$workflowUuid/';
			var containerWorkflowPath = 'tmp/$workflowUuid/';
			FsExtended.ensureDirSync(containerWorkflowPath);
			FsExtended.copyDirSync('/app/client/workflow_convert_pdb/workflows', containerWorkflowPath);
			var pdbfileName = 'upload.pdb';
			var pdbfilePath = Path.join(containerWorkflowPath, pdbfileName);

			function cleanup() {
				try {
					FsExtended.deleteDirSync(containerWorkflowPath);
				} catch(err :Dynamic) {
					//Ignored
				}
			}
			var infileContent = '
infile:
  class: File
  path: $pdbfileName
';
			var infileYamlName = 'pdbfile.yml';
			FsExtended.writeFileSync(Path.join(containerWorkflowPath, infileYamlName), infileContent);

			var writeStream = Fs.createWriteStream(pdbfilePath);
			req.pipe(writeStream);

			writeStream.on(WritableEvent.Finish, function() {
				//Now run the workflow
				ServiceCwlExecutor.runWorkflow(hostWorkflowPath, containerWorkflowPath, "read_and_clean.cwl", infileYamlName)
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
						res.status(500).send(Json.stringify(err));
					});
			});
			writeStream.on(WritableEvent.Error, function(err) {
				traceRed(err);
				cleanup();
				res.status(500).send(Json.stringify({error:err}));
			});
			req.on(ReadableEvent.Error, function(err) {
				traceRed(ReadableEvent.Error);
				traceRed(err);
				cleanup();
				res.status(500).send(Json.stringify({error:err}));
			});
			res.on(ServerResponseEvent.Finish, function() {
				cleanup();
			});




			












			// var tempPdb = '/tmp/' + js.npm.shortid.ShortId.generate() + '.pdb';
			// var writeStream = Fs.createWriteStream(tempPdb);
			// req.pipe(writeStream);

			// function cleanup() {
			// 	try {
			// 		Fs.unlinkSync(tempPdb);
			// 	} catch(err :Dynamic) {
			// 		//Ignored
			// 	}
			// }

			// writeStream.on(WritableEvent.Finish, function() {
			// 	traceGreen('Finished file writing');
			// 	var readable = Fs.createReadStream(tempPdb);
			// 	readable.on(ReadableEvent.Error, function(err) {
			// 		traceRed(err);
			// 		cleanup();
			// 		res.status(500).send(Json.stringify({error:err}));
			// 	});
			// 	untyped res.on(WritableEvent.Finish, function() {
			// 		traceGreen("Finish");
			// 		cleanup();
			// 	});
			// 	readable.pipe(cast res);
			// });
			// writeStream.on(WritableEvent.Error, function(err) {
			// 	traceRed(err);
			// 	cleanup();
			// 	res.status(500).send(Json.stringify({error:err}));
			// });
			// req.on(ReadableEvent.Error, function(err) {
			// 	traceRed(ReadableEvent.Error);
			// 	traceRed(err);
			// 	cleanup();
			// 	res.status(500).send(Json.stringify({error:err}));
			// });
			// req.pipe(writeStream);
		});

		//Static file server for client files
		app.use(js.node.express.Express.Static('../client/dist'));
		app.use('/client', js.node.express.Express.Static('/app/client'));

	}

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
		// Log.debug('Running server functional tests');
		// workflows.server.services.execution.cwl.ServiceCwlExecutorTests.testMultipartRPCSubmission();
	}

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
