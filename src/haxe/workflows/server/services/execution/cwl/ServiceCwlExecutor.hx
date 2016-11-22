package workflows.server.services.execution.cwl;

import haxe.remoting.JsonRpc;
import t9.js.jsonrpc.Routes;

import js.Node;
import js.node.stream.Readable;
import js.node.Fs;
import js.node.Http;
import js.node.http.*;
import js.node.Path;
import js.npm.docker.Docker;
import js.npm.busboy.Busboy;
import js.npm.shortid.ShortId;
import js.npm.fsextended.FsExtended;
import js.npm.streamifier.Streamifier;

/**
 * "classout": {
        "checksum": "sha1$e68df795c0686e9aa1a1195536bd900f5f417b18",
        "basename": "Hello.class",
        "location": "file:///app/Hello.class",
        "path": "/app/Hello.class",
        "class": "File",
        "size": 184
    }
 */
typedef CwlFileOutput = {
	var checksum :String;
	var basename :String;
	var location :String;
	var path :String;
	var size :Int;
}

class ServiceCwlExecutor
{
	inline public static var CWL = 'workflow.cwl';
	inline public static var JOB_YAML = 'job.yml';
	inline public static var CWLTOOL_DOCKER_IMAGE = 'docker.io/dionjwa/cwltool:7daa0e3f';

	public static function runWorkflow(hostWorkflowPath :String, containerWorkflowPath, workflowFile :String, jobFile :String, ?args :Array<String>) :Promise<{stdout:String,stderr:String}>
	{
		var docker = new Docker({socketPath:'/var/run/docker.sock'});

		return promhx.DockerPromises.ensureImage(docker, CWLTOOL_DOCKER_IMAGE)
			.pipe(function(_) {
				//Run the workflow
				var Mounts = [
					{
						Source: '/var/run/docker.sock',
						Destination: '/var/run/docker.sock',
						Mode: 'rw',//https://docs.docker.com/engine/userguide/dockervolumes/#volume-labels
						RW: true
					},
					{
						Source: hostWorkflowPath,
						Destination: '/app',
						Mode: 'rw',
						RW: true
					},
				];
				var hostConfig :CreateContainerHostConfig = {};
				hostConfig.Binds = [];
				for (mount in Mounts) {
					hostConfig.Binds.push(mount.Source + ':' + mount.Destination + ':rw');
				}

				var opts :CreateContainerOptions = {
					Image: CWLTOOL_DOCKER_IMAGE,
					HostConfig: hostConfig,
					Env:[
						'HOST_PWD=$hostWorkflowPath'
					],
					WorkingDir: '/app',
					Cmd:[workflowFile].concat(jobFile != null ? [jobFile] : []).concat(args != null ? args : []),
					AttachStdout: false,
					AttachStderr: false,
					Tty: true,
				};

				var promise = new DeferredPromise();

				Log.debug({log:'run_docker_container', opts:opts});
				docker.createContainer(opts, function(createContainerError, container) {
					if (createContainerError != null) {
						Log.error({log:'error_creating_container', opts:opts, error:createContainerError});
						promise.boundPromise.reject({dockerCreateContainerOpts:opts, error:createContainerError});
						return;
					}
					Log.info('Created container ${container.id}');


					container.attach({logs:true, stream:true, stdout:true, stderr:true}, function(err, stream) {
						if (err != null) {
							promise.boundPromise.reject(err);
							return;
						}

						var stdoutBuf = new StringBuf();
						var stdout = util.streams.StreamTools.createTransformStream(function(s :String) {
							stdoutBuf.add(s);
							return s;
						});

						var stderrBuf = new StringBuf();
						var stderr = util.streams.StreamTools.createTransformStream(function(s :String) {
							stderrBuf.add(s);
							return s;
						});
						stdout.pipe(Node.process.stdout);
						stderr.pipe(Node.process.stderr);

						untyped __js__('container.modem.demuxStream({0}, {1}, {2})', stream, stdout, stderr);
						container.start(function(err, data) {
							if (err != null) {
								promise.boundPromise.reject(err);
								return;
							}
						});
						stream.once('end', function() {
							promise.resolve({stdout:stdoutBuf.toString(), stderr:stderrBuf.toString()});
						});
					});
				});
				return promise.boundPromise;
			});
	}

	public function new ()
	{
	}

	@rpc({
		alias:'execute-cwl-workflow',
		doc:'Runs a CWL workflow'
	})
	public function executeCwlWorkflowRpc(cwl :Dynamic, ?jobYaml :Dynamic, ?wait :Bool = false) :Promise<Dynamic>
	{
		return Promise.promise(false);
	}

	//This will eventually go to CCC or whatever, but for now, just do it locally
	public function executeCwlWorkflow(cwl :Dynamic, jobYaml :Dynamic, ?files :Dynamic) :Promise<Dynamic>
	{
		var promise = new DeferredPromise();
		return promise.boundPromise;
	}

	public function multiFormJobSubmissionRouter() :IncomingMessage->ServerResponse->(?Dynamic->Void)->Void
	{
		return function(req, res, next) {
			traceYellow('${req.url}');
			var contentType :String = req.headers['content-type'];
			traceYellow('contentType=$contentType');
			var isMultiPart = contentType != null && contentType.indexOf('multipart/form-data') > -1;
			traceYellow('isMultiPart=${isMultiPart}');
			if (isMultiPart) {
				traceYellow('req.query.git=${untyped req.query.git}');
				if (untyped req.query != null && untyped req.query.git != null) {
					handleGitCwlExecute(req, res, next);
				} else {
					handleMultiformCwlExecution(req, res, next);
				}
			} else {
				next();
			}
		}
	}

	/**
	 * The git url parameter defines the path of the CWL repo
	 * The extra multipart bodies are the inputs
	 * The path to the files are passed on to the main executor
	 * @param  req  :IncomingMessage [description]
	 * @param  res  :ServerResponse  [description]
	 * @param  next :?Dynamic->Void  [description]
	 * @return      [description]
	 */
	public static function handleGitCwlExecute(req :IncomingMessage, res :ServerResponse, next :?Dynamic->Void) :Void
	{
		traceYellow('handleGitCwlExecute2');
		var gitUrl = untyped req.query.git;
		var cwlFile = untyped req.query.cwl;
		var cwlRunFile = untyped req.query.cwlyml;

		var workflowUuid = ShortId.generate();
		var hostWorkflowPath = Node.process.env["HOST_PWD"] + '/tmp/$workflowUuid';
		var containerWorkflowPath = 'tmp/$workflowUuid';
		traceYellow('hostWorkflowPath=${hostWorkflowPath}');
		traceYellow('containerWorkflowPath=${containerWorkflowPath}');
		var fs = ccc.storage.ServiceStorageLocalFileSystem.getService(containerWorkflowPath);

		var responded = false;
		function onError(err, ?statusCode :Int = 500) {
			if (responded) {
				Log.error(err);
				return;
			}
			responded = true;
			res.writeHead(statusCode, {'content-type': 'application/json'});
			res.end(Json.stringify({error:Json.stringify(err)}, null, '  '));
		}

		var formData :DynamicAccess<Dynamic> = {};
		// formData[ServiceCwlExecutor.CWL] = Fs.createReadStream(Path.join(baseDir, cwlFile));
		// formData[ServiceCwlExecutor.JOB_YAML] = Fs.createReadStream(Path.join(baseDir, cwlRunFile));

		

		
		//When the git repo is cloned, add all the files
		var gitDownloadPromise = GitDownloadTools.getGithubUrl('./gitcache', gitUrl)
			.pipe(function(baseGitDir) {
				traceYellow('gotGithubUrl=$gitUrl');
				var promise = new DeferredPromise();
				FsExtended.copyDir(baseGitDir, containerWorkflowPath, function(err) {
					traceGreen('Copied dir $baseGitDir-> $hostWorkflowPath');
					if (err != null) {
						promise.boundPromise.reject(err);
					} else {
						// FsExtended.copyFileSync(Path.join(hostWorkflowPath, cwlFile), Path.join(hostWorkflowPath, CWL));
						promise.resolve(true);
					}
				});
				return promise.boundPromise;
			});
		gitDownloadPromise.catchError(onError.bind(_, 500));

			// .pipe(function(workflowPath) {
			// 	return runLocalWorkflow(workflowPath, untyped req.query.cwl, untyped req.query.run)
			// 	traceGreen('s=${s}');
			// 	res.writeHead(200, {'content-type': 'application/json'});
			// 	res.end(Json.stringify(s, null, '  '));
			// })
		var promises = [gitDownloadPromise];

		var inputFileNames :Array<String> = [];
		var tenGBInBytes = 10737418240;
		var busboy = new Busboy({headers:req.headers, limits:{fieldNameSize:500, fieldSize:tenGBInBytes}});
		var inputPath = null;
		var deferredFieldHandling = [];//If the fields come in out of order, we'll have to handle the non-JSON-RPC subsequently
		busboy.on(BusboyEvent.File, function(fieldName, stream, fileName, encoding, mimetype) {
			if (responded) {
				return;
			}

			stream.on(ReadableEvent.Error, function(err) {
				Log.error('Error in Busboy reading field=$fieldName fileName=$fileName mimetype=$mimetype error=$err');
			});
			stream.on('limit', function() {
				Log.error('Limit event in Busboy reading field=$fieldName fileName=$fileName mimetype=$mimetype');
			});

			formData[fieldName] = stream;

			var containerInputFilePath = containerWorkflowPath + fieldName;
			var fileWritePromise = fs.writeFile(fieldName, stream);
			fileWritePromise
				.then(function(_) {
					Log.info('    finished writing input file $fieldName to $containerInputFilePath');
					return true;
				})
				.errorThen(function(err) {
					Log.info('    error writing input file $fieldName to $containerInputFilePath err=$err');
					throw err;
					return true;
				});
			promises.push(fileWritePromise);
		});
		busboy.on(BusboyEvent.Field, function(fieldName, val, fieldnameTruncated, valTruncated) {
			if (responded) {
				return;
			}
			var containerInputFilePath = containerWorkflowPath + fieldName;
			var fileWritePromise = fs.writeFile(fieldName, Streamifier.createReadStream(val));
			fileWritePromise
				.then(function(_) {
					Log.info('    finished writing input file $fieldName tp $containerInputFilePath');
					return true;
				})
				.errorThen(function(err) {
					Log.info('    error writing input file $fieldName tp $containerInputFilePath err=$err');
					throw err;
					return true;
				});
			promises.push(fileWritePromise);
			inputFileNames.push(fieldName);
		});

		busboy.on(BusboyEvent.Finish, function() {
			if (responded) {
				return;
			}
			Promise.promise(true)
				.pipe(function(_) {
					return Promise.whenAll(promises);
				})
				.pipe(function(_) {
					return runWorkflow(hostWorkflowPath, containerWorkflowPath, cwlFile, cwlRunFile);
					// return runLocalWorkflow(formData);
				})
				.then(function(result :{stdout:String,stderr:String}) {
					var stdout = result.stdout.replace('\\n', '\n').replace('\\r', '').replace('\\\n', '\n');
					var startIndex = stdout.indexOf('\n{');
					stdout = stdout.substr(startIndex);
					traceGreen('stdout=\n$stdout');
					var basePath = 'output';
					var fsOut = ccc.storage.ServiceStorageLocalFileSystem.getService(basePath);
					try {
						var outputs :DynamicAccess<CwlFileOutput> = Json.parse(stdout);
						for (key in outputs.keys()) {
							var file = outputs.get(key);
							var newLocation = Path.join(basePath, workflowUuid, file.basename);
							trace('${Path.join(containerWorkflowPath, file.basename)}=>$newLocation');
							FsExtended.copyFileSync(Path.join(containerWorkflowPath, file.basename), newLocation);
							file.location = newLocation;
						}
						return outputs;
					} catch(err :Dynamic) {
						Log.error({error:err, stdout:result.stdout, stderr:result.stderr});
						return {};
					}
				})
				.pipe(function(outputs) {
					responded = true;
					traceGreen('final outputs $outputs writing response');
					res.writeHead(200, {'content-type': 'application/json'});
					res.end(Json.stringify(outputs, null, '  '));
					return Promise.promise(true);
				})
				.catchError(onError.bind(_, 500));
		});
		busboy.on(BusboyEvent.PartsLimit, function() {
			Log.error('BusboyEvent ${BusboyEvent.PartsLimit}');
		});
		busboy.on(BusboyEvent.FilesLimit, function() {
			Log.error('BusboyEvent ${BusboyEvent.FilesLimit}');
		});
		busboy.on(BusboyEvent.FieldsLimit, function() {
			Log.error('BusboyEvent ${BusboyEvent.FieldsLimit}');
		});
		req.pipe(busboy);
	}

	static function runLocalWorkflow(formData :DynamicAccess<Dynamic>) :Promise<Bool>
	{
		var url = 'http://localhost:${SERVER_PORT}${MULTIPART_API_WORKFLOW_RUN}';

		var promise = new DeferredPromise();
		js.npm.request.Request.post({url:url, formData: formData},
			function(err, httpResponse, body) {
				if (err != null) {
					promise.boundPromise.reject(err);
					return;
				}
				traceYellow('httpResponse.statusCode=${httpResponse.statusCode}');
				traceYellow('body=${body}');
				if (httpResponse.statusCode == 200) {
					try {
						promise.resolve(true);
					} catch (err :Dynamic) {
						promise.boundPromise.reject(err);
					}
				} else {
					promise.boundPromise.reject('non-200 response body=' + body);
				}
			});

		return promise.boundPromise;
	}

	public function handleMultiformCwlExecution(req :IncomingMessage, res :ServerResponse, next :?Dynamic->Void) :Void
	{
		traceYellow('handleMultiformCwlExecution ');
		var workflowUuid = ShortId.generate();
		var hostWorkflowPath = Node.process.env["HOST_PWD"] + '/tmp/$workflowUuid';
		var containerWorkflowPath = 'tmp/$workflowUuid';
		traceYellow('hostWorkflowPath=${hostWorkflowPath}');
		traceYellow('containerWorkflowPath=${containerWorkflowPath}');
		var fs = ccc.storage.ServiceStorageLocalFileSystem.getService(containerWorkflowPath);
		Promise.promise(true)
			.then(function(_) {
				var promises = [];
				var returned = false;
				var jsonrpc :RequestDefTyped<Dynamic> = null;
				function returnError(err :haxe.extern.EitherType<String, js.Error>) {
					Log.error('err=$err\njsonrpc=${jsonrpc}');
					if (returned) return;
					returned = true;
					res.writeHead(500, {'content-type': 'application/json'});
					res.end(Json.stringify({error: err}));
					//Cleanup
					Promise.whenAll(promises)
						.then(function(_) {
							try {
								FsExtended.deleteDirSync(containerWorkflowPath);
							} catch(deleteErr :Dynamic) {
								Log.error(deleteErr);
							}
							Log.info('Deleted job dir $containerWorkflowPath err=$err');
						});
				}

				var inputFileNames :Array<String> = [];
				var tenGBInBytes = 10737418240;
				var busboy = new Busboy({headers:req.headers, limits:{fieldNameSize:500, fieldSize:tenGBInBytes}});
				var inputPath = null;
				var deferredFieldHandling = [];//If the fields come in out of order, we'll have to handle the non-JSON-RPC subsequently
				busboy.on(BusboyEvent.File, function(fieldName, stream, fileName, encoding, mimetype) {
					if (returned) {
						return;
					}
					var containerInputFilePath = Path.join(containerWorkflowPath, fieldName);
					Log.info('BusboyEvent.File writing input file $fieldName to $containerInputFilePath encoding=$encoding mimetype=$mimetype stream=${stream != null}');

					stream.on(ReadableEvent.Error, function(err) {
						Log.error('Error in Busboy reading field=$fieldName fileName=$fileName mimetype=$mimetype error=$err');
					});
					stream.on('limit', function() {
						Log.error('Limit event in Busboy reading field=$fieldName fileName=$fileName mimetype=$mimetype');
					});

					var fileWritePromise = fs.writeFile(fieldName, stream);
					fileWritePromise
						.then(function(_) {
							Log.info('    finished writing input file $fieldName to $containerInputFilePath');
							return true;
						})
						.errorThen(function(err) {
							Log.info('    error writing input file $fieldName to $containerInputFilePath err=$err');
							throw err;
							return true;
						});
					promises.push(fileWritePromise);
					inputFileNames.push(fieldName);
				});
				busboy.on(BusboyEvent.Field, function(fieldName, val, fieldnameTruncated, valTruncated) {
					if (returned) {
						return;
					}
					var hostInputFilePath = hostWorkflowPath + fieldName;
					var containerInputFilePath = containerWorkflowPath + fieldName;
					var fileWritePromise = fs.writeFile(fieldName, Streamifier.createReadStream(val));
					fileWritePromise
						.then(function(_) {
							Log.info('    finished writing input file $fieldName tp $containerInputFilePath');
							return true;
						})
						.errorThen(function(err) {
							Log.info('    error writing input file $fieldName tp $containerInputFilePath err=$err');
							throw err;
							return true;
						});
					promises.push(fileWritePromise);
					inputFileNames.push(fieldName);
				});

				busboy.on(BusboyEvent.Finish, function() {
					if (returned) {
						return;
					}
					Promise.promise(true)
						.pipe(function(_) {
							return Promise.whenAll(promises);
						})
						.pipe(function(_) {
							return runWorkflow(hostWorkflowPath, containerWorkflowPath, CWL, JOB_YAML);
						})
						.then(function(result :{stdout:String,stderr:String}) {
							var stdout = result.stdout.replace('\\n', '\n').replace('\\r', '').replace('\\\n', '\n');
							var startIndex = stdout.indexOf('\n{');
							stdout = stdout.substr(startIndex);
							traceGreen('stdout=\n$stdout');
							var basePath = 'output';
							var fsOut = ccc.storage.ServiceStorageLocalFileSystem.getService(basePath);
							try {
								var outputs :DynamicAccess<CwlFileOutput> = Json.parse(stdout);
								for (key in outputs.keys()) {
									var file = outputs.get(key);
									var newLocation = Path.join(basePath, workflowUuid, file.basename);
									trace('${Path.join(containerWorkflowPath, file.basename)}=>$newLocation');
									FsExtended.copyFileSync(Path.join(containerWorkflowPath, file.basename), newLocation);
									file.location = newLocation;
								}
								return outputs;
							} catch(err :Dynamic) {
								Log.error({error:err, stdout:result.stdout, stderr:result.stderr});
								return {};
							}
						})
						.pipe(function(outputs) {
							returned = true;
							traceGreen('final outputs $outputs writing response');
							res.writeHead(200, {'content-type': 'application/json'});
							res.end(Json.stringify(outputs, null, '  '));
							return Promise.promise(true);
						})
						.catchError(function(err) {
							Log.error(err);
							returnError(err);
						});
				});
				busboy.on(BusboyEvent.PartsLimit, function() {
					Log.error('BusboyEvent ${BusboyEvent.PartsLimit}');
				});
				busboy.on(BusboyEvent.FilesLimit, function() {
					Log.error('BusboyEvent ${BusboyEvent.FilesLimit}');
				});
				busboy.on(BusboyEvent.FieldsLimit, function() {
					Log.error('BusboyEvent ${BusboyEvent.FieldsLimit}');
				});
				req.pipe(busboy);
			});
	}
}